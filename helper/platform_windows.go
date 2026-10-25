//go:build windows

package main

import (
	"fmt"
	"math/rand"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
)

const (
	singBoxName       = "sing-box.exe"
	selfName          = "neu-v6-free.exe"
	platformName      = "windows"
	platformTitle     = " Windows "
	updateAssetSuffix = "-windows.zip"
	uninstallKey      = `Software\Microsoft\Windows\CurrentVersion\Uninstall\neu-v6-free`
)

var (
	kernel32                  = windows.NewLazySystemDLL("kernel32.dll")
	procFreeConsole           = kernel32.NewProc("FreeConsole")
	procAttachConsole         = kernel32.NewProc("AttachConsole")
	procSetConsoleCtrlHandler = kernel32.NewProc("SetConsoleCtrlHandler")
	procWideCharToMultiByte   = kernel32.NewProc("WideCharToMultiByte")
	iphlpapi                  = windows.NewLazySystemDLL("iphlpapi.dll")
	procSetIpInterfaceEntry   = iphlpapi.NewProc("SetIpInterfaceEntry")
	dnsapi                    = windows.NewLazySystemDLL("dnsapi.dll")
	procDnsFlushResolverCache = dnsapi.NewProc("DnsFlushResolverCache")
)

// 都在 C:\neu-v6-free 里（和以前的 Windows 版一样，升级后流量统计、订阅、我的规则接着用）
func defaultPaths(name string) Paths {
	dir := `C:\` + name
	label := name
	return Paths{Bin: dir, Etc: dir, Var: dir, Data: filepath.Join(dir, "data"), Label: label}
}

func isAbs(p string) bool        { return filepath.IsAbs(p) }
func cleanAbs(p string) string   { return filepath.Clean(p) }
func pathEqual(a, b string) bool { return strings.EqualFold(a, b) }
func pathHasPrefix(a, b string) bool {
	return strings.HasPrefix(strings.ToLower(a), strings.ToLower(b))
}
func ownRoot(string) {}

// ---------- 控制台输出 ----------
// 在命令行窗口里 Go 自己按 UTF-16 输出，中文没问题；输出被别的程序读（安装程序的 nsExec）时，
// 对方按系统的 ANSI 代码页（简体中文是 GBK）解码，所以那时转成 ANSI 再写
var toANSI bool

func setupConsole() {
	var mode uint32
	toANSI = windows.GetConsoleMode(windows.Handle(os.Stdout.Fd()), &mode) != nil
}

// 给用户看的输出都经过它
func say(format string, a ...any) { writeOut(os.Stdout, fmt.Sprintf(format, a...)+"\n") }

func writeOut(f *os.File, s string) {
	if !toANSI {
		f.WriteString(s)
		return
	}
	u, err := windows.UTF16FromString(s)
	if err != nil || len(u) <= 1 {
		f.WriteString(s)
		return
	}
	n, _, _ := procWideCharToMultiByte.Call(0 /* CP_ACP */, 0, uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), 0, 0, 0, 0)
	if n == 0 {
		f.WriteString(s)
		return
	}
	buf := make([]byte, n)
	procWideCharToMultiByte.Call(0, 0, uintptr(unsafe.Pointer(&u[0])), uintptr(len(u)-1), uintptr(unsafe.Pointer(&buf[0])), n, 0, 0)
	f.Write(buf)
}

// ---------- 日志 ----------
// 服务没有标准输出：写 C:\neu-v6-free\helper.log，超过 5MB 时留一份 helper.prev.log 重新开始
func openLog(p Paths) {
	f := p.HelperLog()
	if st, err := os.Stat(f); err == nil && st.Size() > 5<<20 {
		os.Rename(f, filepath.Join(p.Var, "helper.prev.log"))
	}
	if w, err := os.OpenFile(f, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
		logOut = crlf{w}
	}
}

type crlf struct{ f *os.File }

func (c crlf) Write(b []byte) (int, error) {
	_, err := c.f.Write([]byte(strings.ReplaceAll(string(b), "\n", "\r\n")))
	return len(b), err
}

// ---------- 内部命令 ----------
func platformCommand(cmd string, args []string) bool {
	if cmd != "ctrl-break" || len(args) != 1 {
		return false
	}
	// 给 sing-box 发 Ctrl+Break：它会自己撤掉 TUN 网卡和路由再退出（实测 1 秒左右）。sing-box 有自己的（隐藏）控制台，
	// 要先连到它的控制台上；本进程也会收到，所以由助手另起一个进程做这件事
	pid, _ := strconv.Atoi(args[0])
	procFreeConsole.Call()
	if r, _, _ := procAttachConsole.Call(uintptr(pid)); r == 0 {
		os.Exit(2)
	}
	procSetConsoleCtrlHandler.Call(0, 1) // 自己忽略
	if err := windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, 0); err != nil {
		os.Exit(3)
	}
	time.Sleep(300 * time.Millisecond)
	os.Exit(0)
	return true
}

func hidden(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	return cmd
}

// sing-box 要有自己的（隐藏）控制台，才能用 Ctrl+Break 让它正常退出
func singBoxProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NEW_CONSOLE}
}

func stopGracefully(pid int) {
	self, err := os.Executable()
	if err != nil {
		return
	}
	hidden(exec.Command(self, "ctrl-break", strconv.Itoa(pid))).Run()
}

// 同一个 sing-box.exe 的其他进程（上一个助手留下的）：先 Ctrl+Break，10 秒没退再强杀
func stopStray(exe string) {
	for _, pid := range processesOf(exe) {
		if pid == uint32(os.Getpid()) {
			continue
		}
		logf("停止残留的 sing-box（pid %d）", pid)
		h, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_TERMINATE, false, pid)
		if err != nil {
			continue
		}
		stopGracefully(int(pid))
		if ev, _ := windows.WaitForSingleObject(h, 10000); ev != windows.WAIT_OBJECT_0 {
			windows.TerminateProcess(h, 1)
			windows.WaitForSingleObject(h, 5000)
		}
		windows.CloseHandle(h)
	}
}

// 某个程序文件正在运行的进程
func processesOf(exe string) []uint32 {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	base := strings.ToLower(filepath.Base(exe))
	var pids []uint32
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if strings.ToLower(windows.UTF16ToString(e.ExeFile[:])) != base {
			continue
		}
		h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, e.ProcessID)
		if err != nil {
			continue
		}
		buf := make([]uint16, windows.MAX_LONG_PATH)
		n := uint32(len(buf))
		if windows.QueryFullProcessImageName(h, 0, &buf[0], &n) == nil && strings.EqualFold(windows.UTF16ToString(buf[:n]), exe) {
			pids = append(pids, e.ProcessID)
		}
		windows.CloseHandle(h)
	}
	return pids
}

// ---------- 权限 ----------
// 安装目录普通用户只能读和运行（安装时设的，新建的文件默认继承）；有密钥的文件
// （config.json 及其备份、profile.json）要单独收紧成只给管理员和 SYSTEM
func protect(path string) {
	if exists(path) {
		hidden(exec.Command("icacls", path, "/inheritance:r", "/grant:r", "*S-1-5-32-544:F", "*S-1-5-18:F")).Run()
	}
}

// App（app\neu-v6-free.exe）读 panel-secret 自动登录面板、在托盘菜单里暂停 / 重新启用。它以普通权限运行，
// 读不了只给管理员组的文件，所以除了管理员和 SYSTEM，再允许登录到这台电脑桌面的用户读（每分钟看一次换没换人）
var (
	secretMu    sync.Mutex
	secretUsers = map[string]bool{}
)

func publishSecret(p Paths, secret string) {
	f := p.Secret()
	if secret == "" {
		os.Remove(f)
		return
	}
	secretMu.Lock()
	if !exists(f) {
		os.WriteFile(f, nil, 0o644) // 先建空文件收紧权限，再写内容
		protect(f)
		secretUsers = map[string]bool{}
	}
	os.WriteFile(f, []byte(secret+"\n"), 0o644) // 覆盖已有文件不改它的权限
	secretMu.Unlock()
	grantSecret(p)
}

func grantSecret(p Paths) {
	secretMu.Lock()
	defer secretMu.Unlock()
	f := p.Secret()
	if !exists(f) {
		return
	}
	sid, name := consoleUser()
	if sid == "" || secretUsers[sid] {
		return
	}
	if hidden(exec.Command("icacls", f, "/grant", "*"+sid+":R")).Run() == nil {
		secretUsers[sid] = true
		logf("允许 %s 读面板密钥（App 自动登录用）", name)
	}
}

func grantSecretLoop(p Paths) {
	for {
		time.Sleep(time.Minute)
		grantSecret(p)
	}
}

// 登录到这台电脑桌面的用户（没有人登录时为空）
func consoleUser() (sid, name string) {
	sess := windows.WTSGetActiveConsoleSessionId()
	if sess == 0xFFFFFFFF {
		return "", ""
	}
	var tok windows.Token
	if windows.WTSQueryUserToken(sess, &tok) != nil {
		return "", ""
	}
	defer tok.Close()
	u, err := tok.GetTokenUser()
	if err != nil {
		return "", ""
	}
	account, domain, _, _ := u.User.Sid.LookupAccount("")
	return u.User.Sid.String(), domain + `\` + account
}

// ---------- 网卡 ----------

type adapter struct {
	luid        uint64
	alias, desc string
	up, gateway bool
	addrs       []netip.Addr
}

func adapters() []adapter {
	size := uint32(16 << 10)
	var buf []byte
	for i := 0; i < 5; i++ {
		buf = make([]byte, size)
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, windows.GAA_FLAG_INCLUDE_GATEWAYS|windows.GAA_FLAG_SKIP_ANYCAST|windows.GAA_FLAG_SKIP_MULTICAST|windows.GAA_FLAG_SKIP_DNS_SERVER,
			0, (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])), &size)
		if err == nil {
			break
		}
		if err != windows.ERROR_BUFFER_OVERFLOW {
			return nil
		}
		buf = nil
	}
	if buf == nil {
		return nil
	}
	var list []adapter
	for a := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])); a != nil; a = a.Next {
		ad := adapter{luid: a.Luid, alias: windows.UTF16PtrToString(a.FriendlyName), desc: windows.UTF16PtrToString(a.Description),
			up: a.OperStatus == windows.IfOperStatusUp, gateway: a.FirstGatewayAddress != nil}
		for u := a.FirstUnicastAddress; u != nil; u = u.Next {
			if ip, ok := netip.AddrFromSlice(u.Address.IP()); ok {
				ad.addrs = append(ad.addrs, ip.Unmap())
			}
		}
		list = append(list, ad)
	}
	return list
}

var reVirtual = regexp.MustCompile(`(?i)Wintun|TAP-Windows|Tailscale|WireGuard|Clash|Meta|Radmin|Hyper-V|VMware|VirtualBox|ZeroTier`)
var reVirtualAlias = regexp.MustCompile(`(?i)vEthernet|Radmin|Teredo`)

// 绕过 sing-box 的探测：绑定物理网卡的地址（排除 sing-box 的 neu-v6 网卡和其他虚拟网卡）
func physicalDialers() (v6, v4 []*net.Dialer) {
	for _, a := range adapters() {
		if !a.up || !a.gateway || strings.EqualFold(a.alias, "neu-v6") || reVirtualAlias.MatchString(a.alias) || reVirtual.MatchString(a.desc) {
			continue
		}
		for _, ip := range a.addrs {
			d := &net.Dialer{LocalAddr: &net.TCPAddr{IP: ip.AsSlice()}}
			switch {
			case ip.Is4() && !ip.IsLinkLocalUnicast():
				v4 = append(v4, d)
			case ip.Is6() && ip.IsGlobalUnicast() && ip.As16()[0]&0xE0 == 0x20: // 2000::/3，排除临时的本地地址
				v6 = append(v6, d)
			}
		}
	}
	return v6, v4
}

// sing-box 的 TUN 网卡起来了没有。打开 TUN 卡住时（例如上一次被强杀）sing-box 进程还在，网络照常直连，
// 只看「能不能上网」会误以为它在正常工作
// 清掉系统的 DNS 缓存（和 ipconfig /flushdns 相同）
func flushDNS() {
	if procDnsFlushResolverCache.Find() == nil {
		procDnsFlushResolverCache.Call()
	}
}

func tunUp(name string) bool {
	if name == "" {
		return true
	}
	ifc, err := net.InterfaceByName(name)
	return err == nil && ifc.Flags&net.FlagUp != 0
}

// ---------- 物理网卡的 WeakHostSend ----------
// 网卡打开了「弱主机发送」时，绑定在它上面的连接也按整张路由表走：TUN 的默认路由优先级最高，
// sing-box 自己连服务器、查 DNS 的包就绕回自己的 TUN，全部超时，整台电脑断网（实测：IPv6 打开、IPv4 关着时，只有 IPv6 全断）。
// Windows 默认是关的，有的软件会把它打开。sing-box 运行期间把物理网卡的这一项关掉，暂停、安全模式、卸载时恢复原值。
// 改过哪些记在 weakhost.json（键是「网卡 GUID|IPv4」，和以前的版本相同）：助手重启、电脑重启后也能恢复

func weakHostFile(p Paths) string { return filepath.Join(p.Var, "weakhost.json") }

type physIf struct {
	luid  uint64
	guid  string
	alias string
}

// 物理网卡（有接口的真实网卡，和 Get-NetAdapter -Physical 一样）
func physicalInterfaces() []physIf {
	var list []physIf
	for _, a := range adapters() {
		row := windows.MibIfRow2{InterfaceLuid: a.luid}
		if windows.GetIfEntry2Ex(windows.MibIfEntryNormalWithoutStatistics, &row) != nil {
			continue
		}
		const filter, connector = 0x02, 0x04
		if row.InterfaceAndOperStatusFlags&connector == 0 || row.InterfaceAndOperStatusFlags&filter != 0 {
			continue
		}
		list = append(list, physIf{luid: a.luid, guid: row.InterfaceGuid.String(), alias: a.alias})
	}
	return list
}

var families = map[string]uint16{"IPv4": windows.AF_INET, "IPv6": windows.AF_INET6}

func ipInterface(luid uint64, family uint16) (*windows.MibIpInterfaceRow, bool) {
	row := &windows.MibIpInterfaceRow{Family: family, InterfaceLuid: luid}
	return row, windows.GetIpInterfaceEntry(row) == nil
}

func setWeakHost(row *windows.MibIpInterfaceRow, on bool) error {
	row.WeakHostSend = 0
	if on {
		row.WeakHostSend = 1
	}
	if row.Family == windows.AF_INET {
		row.SitePrefixLength = 0 // SetIpInterfaceEntry 要求 IPv4 时为 0
	}
	if r, _, _ := procSetIpInterfaceEntry.Call(uintptr(unsafe.Pointer(row))); r != 0 {
		return syscall.Errno(r)
	}
	return nil
}

func fixWeakHost(p Paths) {
	saved := map[string]string{}
	readJSON(weakHostFile(p), &saved)
	changed := false
	for _, ifc := range physicalInterfaces() {
		for fam, af := range families {
			row, ok := ipInterface(ifc.luid, af)
			if !ok || row.WeakHostSend == 0 {
				continue
			}
			if err := setWeakHost(row, false); err != nil {
				logf("关闭网卡「%s」%s 的 WeakHostSend 失败：%v", ifc.alias, fam, err)
				continue
			}
			saved[ifc.guid+"|"+fam] = "Enabled"
			changed = true
			logf("网卡「%s」的 %s 打开了 WeakHostSend（会让 sing-box 自己的连接绕回 TUN），已暂时关掉，停止时恢复", ifc.alias, fam)
		}
	}
	if changed {
		writeAtomic(weakHostFile(p), marshal(saved), 0o644)
	}
}

func restoreWeakHost(p Paths) {
	saved := map[string]string{}
	if readJSON(weakHostFile(p), &saved) != nil {
		return
	}
	ifs := physicalInterfaces()
	for k, v := range saved {
		guid, fam, _ := strings.Cut(k, "|")
		for _, ifc := range ifs {
			if strings.EqualFold(ifc.guid, guid) {
				if row, ok := ipInterface(ifc.luid, families[fam]); ok {
					setWeakHost(row, v == "Enabled")
				}
			}
		}
	}
	os.Remove(weakHostFile(p))
	logf("已把物理网卡的 WeakHostSend 恢复成原来的设置")
}

// ---------- 换文件 ----------
// 正在运行的程序文件不能覆盖、但能改名：旧文件先改名成 *.old 再放新的，*.old 下次助手启动时删掉

func moveAside(path string) error {
	if !exists(path) {
		return nil
	}
	return os.Rename(path, fmt.Sprintf("%s.%08x.old", path, rand.Uint32()))
}

func replaceSelf(src, dst string) error {
	if err := moveAside(dst); err != nil {
		return err
	}
	return copyFile(src, dst, 0o755)
}

func cleanOldFiles(p Paths) {
	filepath.WalkDir(p.Bin, func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(path, ".old") {
			os.Remove(path)
		}
		if err == nil && d.IsDir() && path != p.Bin && filepath.Dir(path) == p.Bin && d.Name() != "app" {
			return filepath.SkipDir // 只看程序目录和 app
		}
		return nil
	})
}

// Windows 外壳（app\neu-v6-free.exe 和 WebView2 的几个 dll）：开着的 App 文件改名后放新的，exe 最后放；
// 开着的 App 发现自己的版本变了会自己重开
func installApp(pkg string, p Paths) error {
	src := filepath.Join(pkg, "app")
	if !exists(filepath.Join(src, "neu-v6-free.exe")) {
		return nil
	}
	var files []string
	filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			files = append(files, path)
		}
		return nil
	})
	exe := filepath.Join(src, "neu-v6-free.exe")
	for _, f := range append(without(files, exe), exe) {
		rel, _ := filepath.Rel(src, f)
		t := filepath.Join(p.Bin, "app", rel)
		if err := moveAside(t); err != nil {
			return err
		}
		if err := copyFile(f, t, 0o755); err != nil {
			return err
		}
	}
	return nil
}

func without(list []string, x string) []string {
	var out []string
	for _, s := range list {
		if s != x {
			out = append(out, s)
		}
	}
	return out
}

// 安装包根目录的 .bat（卸载.bat 等）一起换
func installExtras(pkg string, p Paths) {
	bats, _ := filepath.Glob(filepath.Join(pkg, "*.bat"))
	for _, f := range bats {
		copyFile(f, filepath.Join(p.Bin, filepath.Base(f)), 0o644)
	}
}

// 安装程序在「设置 → 应用」里登记的版本号也跟着改
func setRegisteredVersion(v string) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, uninstallKey, registry.SET_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return
	}
	defer k.Close()
	k.SetStringValue("DisplayVersion", v)
}

// ---------- 服务 ----------

type service struct {
	fn func(stop <-chan struct{}) int
}

func (s service) Execute(_ []string, req <-chan svc.ChangeRequest, st chan<- svc.Status) (bool, uint32) {
	st <- svc.Status{State: svc.StartPending}
	stop, done := make(chan struct{}), make(chan int, 1)
	go func() { done <- s.fn(stop) }()
	st <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case c := <-req:
			switch c.Cmd {
			case svc.Interrogate:
				st <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				st <- svc.Status{State: svc.StopPending, WaitHint: 30000}
				close(stop)
				return false, uint32(<-done)
			}
		case code := <-done:
			// 退出代码不为 0（升级后重启、出错）：服务的「失败后重新启动」会在几秒后拉起它
			return false, uint32(code)
		}
	}
}

func runService(name string, fn func(stop <-chan struct{}) int) {
	if ok, _ := svc.IsWindowsService(); ok {
		if err := svc.Run(name, service{fn}); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	// 命令行里直接运行（调试）：Ctrl+C 停止
	stop := make(chan struct{})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	go func() {
		<-sig
		close(stop)
	}()
	os.Exit(fn(stop))
}
