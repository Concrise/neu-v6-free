//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"
)

func ensureAdmin([]string) {
	if os.Geteuid() != 0 {
		die("请用 sudo 运行（只有安装、卸载要管理员）")
	}
}

func pauseAtEnd(bool)       {}
func preflightWarnings()    {}
func createShortcuts(Paths) {}
func runFromTemp([]string)  {}

func plistPath(label string) string { return "/Library/LaunchDaemons/" + label + ".plist" }

// 停掉已经装着的：本地助手（新版一个服务；旧版是 sing-box、助手、更早的流量统计三个服务）和 sing-box
func stopInstalled(p Paths) {
	if port := helperPort(p); health(port) != nil {
		pauseHelper(port, readSecret(p), "安装 / 卸载时暂停")
	}
	for _, l := range []string{p.Label, p.Label + ".helper", p.Label + ".traffic"} {
		exec.Command("/bin/launchctl", "bootout", "system/"+l).Run()
	}
	stopStray(p.SingBox())
}

func unregisterService(p Paths) {
	for _, l := range []string{p.Label, p.Label + ".helper", p.Label + ".traffic"} {
		exec.Command("/bin/launchctl", "bootout", "system/"+l).Run()
		os.Remove(plistPath(l))
	}
	os.Remove(filepath.Join(p.Bin, "helper.py")) // 旧版的助手
	os.Remove(filepath.Join(p.Bin, "traffic.py"))
}

// 一个 LaunchDaemon：开机启动本地助手，助手再启动并看着 sing-box；退出了 launchd 自动拉起
func registerService(p Paths, port int) error {
	for _, l := range []string{p.Label + ".helper", p.Label + ".traffic"} { // 旧版另外两个服务
		os.Remove(plistPath(l))
	}
	os.Remove(filepath.Join(p.Bin, "helper.py"))
	os.Remove(filepath.Join(p.Bin, "helper-service.sh"))
	name := filepath.Base(p.Bin)
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string><string>run</string>
    <string>--name</string><string>%s</string>
    <string>--label</string><string>%s</string>
    <string>--port</string><string>%d</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, p.Label, p.Self(), name, p.Label, port, p.HelperLog(), p.HelperLog())
	if err := os.WriteFile(plistPath(p.Label), []byte(plist), 0o644); err != nil {
		return err
	}
	os.Chown(plistPath(p.Label), 0, 0)
	exec.Command("/bin/launchctl", "bootout", "system/"+p.Label).Run()
	if out, err := exec.Command("/bin/launchctl", "bootstrap", "system", plistPath(p.Label)).CombinedOutput(); err != nil {
		return fmt.Errorf("%v：%s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func hardenPermissions(p Paths) {
	os.Chmod(p.Var, 0o700) // 流量统计、日志
	for _, f := range []string{p.Config(), p.Config() + ".prev", p.Config() + ".new", p.Profile()} {
		protect(f)
	}
}

// sing-box：指定的 → 安装包里的（通用二进制）→ 已经装着的 → PATH / Homebrew / v2rayN 自带的 → 从 GitHub 下载固定版本
func installSingBox(src string, p Paths, override string) error {
	cands := []string{override, filepath.Join(src, "sing-box")}
	if override == "" && !exists(filepath.Join(src, "sing-box")) && exists(p.SingBox()) {
		say("sing-box：沿用已安装的")
		return nil
	}
	if lp, err := exec.LookPath("sing-box"); err == nil {
		cands = append(cands, lp)
	}
	home := "/Users/" + consoleUserName("")
	cands = append(cands, "/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box",
		home+"/Library/Application Support/v2rayN/bin/sing_box/sing-box", "/Applications/v2rayN.app/Contents/MacOS/bin/sing_box/sing-box")
	for _, c := range cands {
		if c != "" && exists(c) {
			if c != p.SingBox() {
				if err := copyFile(c, p.SingBox(), 0o755); err != nil {
					return err
				}
			}
			say("sing-box：用 %s（%s）", c, singBoxVersion(p.SingBox()))
			return nil
		}
	}
	arch := "arm64"
	if out, _ := exec.Command("/usr/bin/uname", "-m").Output(); strings.TrimSpace(string(out)) == "x86_64" {
		arch = "amd64"
	}
	return downloadSingBox("darwin-"+arch, p.SingBox())
}

// 装完替谁打开 App：指定的 → sudo 的用户 → 登录到桌面的用户
func consoleUserName(given string) string {
	if given != "" {
		return given
	}
	if u := os.Getenv("SUDO_USER"); u != "" && u != "root" {
		return u
	}
	if st, err := os.Stat("/dev/console"); err == nil {
		if s, ok := st.Sys().(*syscall.Stat_t); ok {
			if u, err := user.LookupId(fmt.Sprint(s.Uid)); err == nil && u.Username != "root" {
				return u.Username
			}
		}
	}
	return ""
}

// 在登录用户的桌面会话里打开（安装器 .pkg 里是 root 运行的，直接 open 打不开）
func asUser(name string, args ...string) {
	u, err := user.Lookup(name)
	if err != nil {
		return
	}
	exec.Command("/bin/launchctl", append([]string{"asuser", u.Uid, "/usr/bin/sudo", "-u", name}, args...)...).Run()
}

func openApp(p Paths, secret, given string) {
	name := consoleUserName(given)
	if name == "" {
		return
	}
	app := filepath.Join("/Applications", appName)
	if exists(app) {
		asUser(name, "/usr/bin/open", app)
		say("以后从「应用程序」或菜单栏的 v6 图标打开；关掉窗口、退出 App 都不影响免流。")
	} else if secret != "" {
		// 没有 App（命令行安装）：密钥放在网址的 # 后面（不会发给任何服务器），面板读到后自动登录
		asUser(name, "/usr/bin/open", "http://127.0.0.1:9090/ui/#secret="+secret)
	}
}

func removeApp(Paths) {
	app := filepath.Join("/Applications", appName)
	exec.Command("/usr/bin/pkill", "-f", app+"/Contents/MacOS/").Run()
	os.RemoveAll(app)
	exec.Command("/usr/sbin/pkgutil", "--forget", "io.github.concrise.neu-v6-free").Run() // 安装器（.pkg）的安装记录
}

func uninstallHint(p Paths) string { return "sudo " + p.Self() + " uninstall" }

// 谁在听这个端口
func portOwner(port int) string {
	out, _ := exec.Command("/usr/sbin/lsof", "-nP", fmt.Sprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-Fc").Output()
	for _, l := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(l, "c") {
			return l[1:]
		}
	}
	return ""
}
