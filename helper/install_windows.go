//go:build windows

package main

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	oldTask     = "neu-v6-free helper" // 1.1.x 以前用计划任务运行 PowerShell 版助手
	displayName = "校园网 v6 免流"
)

// 不是管理员时：请求管理员权限重新运行自己（弹 UAC），本进程结束
func ensureAdmin(args []string) {
	if windows.GetCurrentProcessToken().IsElevated() {
		return
	}
	say("需要管理员权限，正在请求……")
	self, _ := os.Executable()
	var q []string
	for _, a := range args {
		q = append(q, syscall.EscapeArg(a))
	}
	cmd := os.Args[1]
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(self)
	params, _ := windows.UTF16PtrFromString(strings.TrimSpace(cmd + " " + strings.Join(q, " ")))
	if err := windows.ShellExecute(0, verb, file, params, nil, windows.SW_SHOWNORMAL); err != nil {
		die("没有拿到管理员权限：%v", err)
	}
	os.Exit(0)
}

func pauseAtEnd(noPause bool) {
	if noPause || toANSI { // 输出被别的程序读着（安装程序）：没人按回车
		return
	}
	say("按回车关闭")
	bufio.NewReader(os.Stdin).ReadString('\n')
}

// 别的代理软件退出后常留下系统代理：指向的端口已经没有程序在听，浏览器就「没网」。这种失效的系统代理直接关掉。
// 代理环境变量不替你改，只提醒：它指向的软件关掉后，用这个变量的程序（命令行工具、Claude Code 等）会连不上
func preflightWarnings() {
	if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.QUERY_VALUE|registry.SET_VALUE); err == nil {
		on, _, _ := k.GetIntegerValue("ProxyEnable")
		server, _, _ := k.GetStringValue("ProxyServer")
		if on == 1 && server != "" {
			parts := regexp.MustCompile(`[:;=]`).Split(server, -1)
			port, _ := strconv.Atoi(parts[len(parts)-1])
			if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 500*time.Millisecond); err != nil {
				k.SetDWordValue("ProxyEnable", 0)
				say("系统代理 %s 已经没有程序在用（多半是退出的代理软件留下的），已关闭。", server)
			} else {
				c.Close()
				say("注意：系统代理设成了 %s，那个程序还在运行。本工具用 TUN 接管全部流量，不需要系统代理。", server)
			}
		}
		k.Close()
	}
	envKeys := map[string]struct {
		root registry.Key
		path string
	}{
		"User":    {registry.CURRENT_USER, `Environment`},
		"Machine": {registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`},
	}
	mask := regexp.MustCompile(`//[^/@]+@`)
	for scope, e := range envKeys {
		k, err := registry.OpenKey(e.root, e.path, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		for _, n := range []string{"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"} {
			if v, _, err := k.GetStringValue(n); err == nil && v != "" {
				say("注意：环境变量 %s（%s）= %s。如果它指向的代理软件已经关掉，请删掉这个变量，否则用它的程序会连不上。", n, scope, mask.ReplaceAllString(v, "//***@"))
			}
		}
		k.Close()
	}
}

// 停掉已经装着的：本地助手（新版是 Windows 服务，旧版是计划任务里的 PowerShell）、sing-box、App
func stopInstalled(p Paths) {
	if port := helperPort(p); health(port) != nil {
		// 请助手先暂停：它和 sing-box 都在 SYSTEM 的会话里，能让 sing-box 正常退出（撤掉 TUN 网卡）并恢复 WeakHostSend
		pauseHelper(port, readSecret(p), "安装 / 卸载时暂停")
	}
	if m, err := mgr.Connect(); err == nil {
		if s, err := m.OpenService(p.Label); err == nil {
			stopService(s)
			s.Close()
		}
		m.Disconnect()
	}
	hidden(exec.Command("schtasks", "/end", "/tn", oldTask)).Run()
	killApp(p)
	time.Sleep(time.Second)
	stopStray(p.SingBox())
	restoreWeakHost(p)
}

func stopService(s *mgr.Service) {
	st, err := s.Query()
	if err != nil || st.State == svc.Stopped {
		return
	}
	s.Control(svc.Stop)
	for i := 0; i < 40; i++ {
		if st, err = s.Query(); err != nil || st.State == svc.Stopped {
			return
		}
		time.Sleep(time.Second)
	}
}

// Windows 服务：开机自动启动（SYSTEM），退出代码不为 0（升级后重启、出错）就在几秒后重新拉起
func registerService(p Paths, port int) error {
	hidden(exec.Command("schtasks", "/delete", "/tn", oldTask, "/f")).Run()
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	args := []string{"run", "--name", filepath.Base(p.Bin), "--port", strconv.Itoa(port)}
	if p.Label != filepath.Base(p.Bin) {
		args = append(args, "--label", p.Label)
	}
	cfg := mgr.Config{DisplayName: displayName, Description: "运行 sing-box 并看护网络；面板 http://127.0.0.1:9090/ui",
		StartType: mgr.StartAutomatic, ServiceStartName: "LocalSystem"}
	s, err := m.OpenService(p.Label)
	if err == nil {
		stopService(s)
		cfg.BinaryPathName = syscall.EscapeArg(p.Self()) + " " + strings.Join(args, " ")
		if err := s.UpdateConfig(cfg); err != nil {
			s.Close()
			return err
		}
	} else if s, err = m.CreateService(p.Label, p.Self(), cfg, args...); err != nil {
		return err
	}
	defer s.Close()
	s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 3 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
	}, 3600)
	s.SetRecoveryActionsOnNonCrashFailures(true)
	return s.Start()
}

func unregisterService(p Paths) {
	if m, err := mgr.Connect(); err == nil {
		if s, err := m.OpenService(p.Label); err == nil {
			stopService(s)
			s.Delete()
			s.Close()
			say("本地助手已停止并删除")
		}
		m.Disconnect()
	}
	hidden(exec.Command("schtasks", "/delete", "/tn", oldTask, "/f")).Run()
}

// 安装目录：普通用户只能读和运行（App 在 app 里）。1.1.0 及以前没设，目录继承了 C:\ 的「已验证的用户：修改」，
// 普通账户就能改以 SYSTEM 运行的程序。先收紧目录，再让里面的文件都改回继承它；有密钥的文件只给管理员和 SYSTEM
func hardenPermissions(p Paths) {
	hidden(exec.Command("icacls", p.Bin, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F", "*S-1-5-32-545:(OI)(CI)RX")).Run()
	hidden(exec.Command("icacls", p.Bin+`\*`, "/reset", "/T", "/C", "/Q")).Run()
	for _, f := range []string{p.Config(), p.Config() + ".prev", p.Config() + ".new", p.Profile(), p.Secret()} {
		protect(f) // App 读的 panel-secret 由本地助手再允许登录的用户读
	}
}

// 本机是不是 ARM64（x64 程序在 ARM64 上模拟运行时，环境变量会说是 AMD64）
func nativeARM64() bool {
	var proc, native uint16
	if windows.IsWow64Process2(windows.CurrentProcess(), &proc, &native) == nil {
		return native == 0xAA64 // IMAGE_FILE_MACHINE_ARM64
	}
	return os.Getenv("PROCESSOR_ARCHITECTURE") == "ARM64" || os.Getenv("PROCESSOR_ARCHITEW6432") == "ARM64"
}

// sing-box：指定的 → 安装包里的（x64 和 ARM64 两个，按本机选）→ 已经装着的 → 从 GitHub 下载固定版本
func installSingBox(src string, p Paths, override string) error {
	arch := "amd64"
	if nativeARM64() {
		arch = "arm64"
	}
	cands := []string{override}
	if arch == "arm64" {
		cands = append(cands, filepath.Join(src, "sing-box-arm64.exe"))
	}
	cands = append(cands, filepath.Join(src, "sing-box.exe"))
	for _, c := range cands {
		if c != "" && exists(c) {
			if !pathEqual(cleanAbs(c), cleanAbs(p.SingBox())) {
				if err := copyFile(c, p.SingBox(), 0o755); err != nil {
					return err
				}
			}
			say("sing-box：用 %s（%s）", filepath.Base(c), singBoxVersion(p.SingBox()))
			return nil
		}
	}
	if exists(p.SingBox()) {
		say("sing-box：沿用已安装的")
		return nil
	}
	return downloadSingBox("windows-"+arch, p.SingBox())
}

func appExe(p Paths) string { return filepath.Join(p.Bin, "app", "neu-v6-free.exe") }

func killApp(p Paths) {
	for _, pid := range processesOf(appExe(p)) {
		if h, err := windows.OpenProcess(windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, pid); err == nil {
			windows.TerminateProcess(h, 0)
			windows.WaitForSingleObject(h, 5000)
			windows.CloseHandle(h)
		}
	}
}

var shortcuts = []string{
	filepath.Join(os.Getenv("ProgramData"), `Microsoft\Windows\Start Menu\Programs`, displayName+".lnk"),
	filepath.Join(os.Getenv("PUBLIC"), "Desktop", displayName+".lnk"),
}

var oldShortcut = filepath.Join(os.Getenv("ProgramData"), `Microsoft\Windows\Start Menu\Programs`, displayName+".url")

// 开始菜单和桌面的入口（所有用户）。.lnk 只能用 COM 建，交给系统自带的 PowerShell（命令用 UTF-16 编码传，不怕中文路径）
func createShortcuts(p Paths) {
	app := appExe(p)
	if !exists(app) {
		return
	}
	var b strings.Builder
	b.WriteString("$s = New-Object -ComObject WScript.Shell\n")
	for _, l := range shortcuts {
		fmt.Fprintf(&b, "$k = $s.CreateShortcut('%s'); $k.TargetPath = '%s'; $k.WorkingDirectory = '%s'; $k.Description = '%s'; $k.Save()\n",
			psq(l), psq(app), psq(filepath.Dir(app)), "校园网 v6 免流：面板和运行状态")
	}
	u := utf16.Encode([]rune(b.String()))
	raw := unsafe.Slice((*byte)(unsafe.Pointer(&u[0])), len(u)*2)
	ps := filepath.Join(os.Getenv("SystemRoot"), `System32\WindowsPowerShell\v1.0\powershell.exe`)
	hidden(exec.Command(ps, "-NoProfile", "-NonInteractive", "-EncodedCommand", base64.StdEncoding.EncodeToString(raw))).Run()
	os.Remove(oldShortcut)
}

func psq(s string) string { return strings.ReplaceAll(s, "'", "''") }

// 经 explorer 打开：App / 浏览器不会以管理员身份运行
func openApp(p Paths, secret, _ string) {
	if app := appExe(p); exists(app) {
		exec.Command("explorer.exe", app).Start()
		say("以后从开始菜单、桌面的「%s」或右下角托盘的 v6 图标打开；关掉窗口、退出 App 都不影响免流。", displayName)
	} else if secret != "" {
		// 没有 App（命令行安装）：密钥放在网址的 # 后面（不会发给任何服务器），面板读到后自动登录
		exec.Command("explorer.exe", "http://127.0.0.1:9090/ui/#secret="+secret).Start()
	}
}

// App：关掉，删开始菜单和桌面的入口、当前用户的开机自动打开
func removeApp(p Paths) {
	killApp(p)
	for _, l := range append(shortcuts, oldShortcut) {
		os.Remove(l)
	}
	if k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE); err == nil {
		k.DeleteValue("neu-v6-free")
		k.Close()
	}
	registry.DeleteKey(registry.CURRENT_USER, `Software\neu-v6-free`)
}

func uninstallHint(p Paths) string {
	return "设置 → 应用 →「" + displayName + "」，或运行 " + filepath.Join(p.Bin, "uninstall.bat")
}

// 卸载要删掉程序自己：从安装目录运行时，先复制到临时目录，再从那里运行
func runFromTemp(args []string) {
	self, _ := os.Executable()
	tmp := os.TempDir()
	if pathHasPrefix(cleanAbs(self), cleanAbs(tmp)) {
		return
	}
	cp := filepath.Join(tmp, fmt.Sprintf("neu-v6-free-uninstall-%d.exe", os.Getpid()))
	if copyFile(self, cp, 0o755) != nil {
		return // 复制不了就照常运行（程序自己删不掉，其余照删）
	}
	cmd := exec.Command(cp, append([]string{"uninstall"}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err := cmd.Run()
	// 临时副本等它退出后删掉
	hidden(exec.Command("cmd", "/c", "ping -n 3 127.0.0.1 >nul & del /f /q "+syscall.EscapeArg(cp))).Start()
	if e, ok := err.(*exec.ExitError); ok {
		os.Exit(e.ExitCode())
	}
	os.Exit(0)
}

// 谁在听这个端口（netstat 找进程号，再找程序名）
func portOwner(port int) string {
	out, err := hidden(exec.Command("netstat", "-ano", "-p", "TCP")).Output()
	if err != nil {
		return ""
	}
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) == 5 && strings.HasSuffix(f[1], fmt.Sprintf(":%d", port)) && f[3] == "LISTENING" {
			pid, _ := strconv.Atoi(f[4])
			return processName(uint32(pid))
		}
	}
	return ""
}

func processName(pid uint32) string {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if e.ProcessID == pid {
			return windows.UTF16ToString(e.ExeFile[:])
		}
	}
	return ""
}
