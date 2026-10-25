//go:build darwin

package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
)

const (
	singBoxName       = "sing-box"
	selfName          = "neu-v6-free"
	platformName      = "mac"
	platformTitle     = " macOS "
	updateAssetSuffix = "-macos.zip"
	appName           = "校园网 v6 免流.app"
)

func defaultPaths(name string) Paths {
	v := "/usr/local/var/" + name
	return Paths{Bin: "/usr/local/libexec/" + name, Etc: "/usr/local/etc/" + name, Var: v, Data: v, Label: "local." + name}
}

func setupConsole()                                  {}
func say(format string, a ...any)                    { fmt.Printf(format+"\n", a...) }
func writeOut(f *os.File, s string)                  { f.WriteString(s) }
func platformCommand(cmd string, args []string) bool { return false }
func openLog(p Paths)                                {} // launchd 把标准输出写进 helper.log
func setRegisteredVersion(string)                    {}
func fixWeakHost(Paths)                              {}
func restoreWeakHost(Paths)                          {}
func tunUp(string) bool                              { return true }
func grantSecretLoop(Paths)                          {}
func cleanOldFiles(Paths)                            {}
func installExtras(string, Paths)                    {}

func isAbs(p string) bool            { return filepath.IsAbs(p) }
func cleanAbs(p string) string       { return filepath.Clean(p) }
func pathEqual(a, b string) bool     { return a == b }
func pathHasPrefix(a, b string) bool { return strings.HasPrefix(a, b) }

// 以 root 运行时新装的文件归 root（开发调试时不是 root，保持当前用户）
func ownRoot(path string) {
	if os.Geteuid() == 0 {
		os.Lchown(path, 0, 0)
	}
}

// 有密钥的文件只给 root
func protect(path string) {
	if exists(path) {
		os.Chmod(path, 0o600)
		ownRoot(path)
	}
}

// 面板密钥另存一份给 App 读（root:admin 640：管理员账户能读，和它们能 sudo 看配置一样）。
// App 用它自动登录面板、在菜单栏暂停 / 重新启用。config.json 本身仍然只有 root 能读
func publishSecret(p Paths, secret string) {
	if os.Geteuid() != 0 {
		return
	}
	f := p.Secret()
	if secret == "" {
		os.Remove(f)
		return
	}
	tmp := f + ".tmp"
	if err := os.WriteFile(tmp, []byte(secret+"\n"), 0o600); err != nil {
		return
	}
	os.Chown(tmp, 0, 80) // 80 = admin 组
	os.Chmod(tmp, 0o640)
	os.Rename(tmp, f)
}

// 绕过 sing-box 的探测：绑定默认路由所在的物理网卡（sing-box 只加 0/1、128/1 两条路由，默认路由还在物理网卡上）。
// 用 IP_BOUND_IF 绑网卡，连接不看路由表，真的绕过 TUN
var reIface = regexp.MustCompile(`interface: (\S+)`)

func physicalDialers() (v6, v4 []*net.Dialer) {
	out, err := exec.Command("/sbin/route", "-n", "get", "default").Output()
	if err != nil {
		return nil, nil
	}
	m := reIface.FindSubmatch(out)
	if m == nil || strings.HasPrefix(string(m[1]), "utun") {
		return nil, nil
	}
	ifc, err := net.InterfaceByName(string(m[1]))
	if err != nil {
		return nil, nil
	}
	d := &net.Dialer{Control: func(network, _ string, c syscall.RawConn) error {
		var serr error
		err := c.Control(func(fd uintptr) {
			if strings.HasSuffix(network, "6") {
				serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF, ifc.Index)
			} else {
				serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF, ifc.Index)
			}
		})
		if err != nil {
			return err
		}
		return serr
	}}
	return []*net.Dialer{d}, []*net.Dialer{d}
}

// sing-box 和助手在同一个进程组：助手异常退出时 launchd 把它一起结束，重新拉起助手时不会有两个 sing-box
func singBoxProcAttr(*exec.Cmd) {}

func stopGracefully(pid int) { syscall.Kill(pid, syscall.SIGTERM) }

// 清掉系统的 DNS 缓存（要 root；开发调试时不是 root，清不掉也没关系）
func flushDNS() {
	exec.Command("/usr/bin/dscacheutil", "-flushcache").Run()
	exec.Command("/usr/bin/killall", "-HUP", "mDNSResponder").Run()
}

// 同一个 sing-box 程序的其他进程（上一个助手留下的、旧版单独的 sing-box 服务）
func stopStray(exe string) {
	out, _ := exec.Command("/usr/bin/pgrep", "-f", "^"+regexp.QuoteMeta(exe)+" run").Output()
	for _, f := range strings.Fields(string(out)) {
		if pid, err := strconv.Atoi(f); err == nil && pid != os.Getpid() {
			logf("停止残留的 sing-box（pid %d）", pid)
			syscall.Kill(pid, syscall.SIGTERM)
		}
	}
}

// 换掉正在运行的助手：mac 上改名替换就行，运行中的进程不受影响
func replaceSelf(src, dst string) error { return copyFile(src, dst, 0o755) }

// 安装包里带了 App 就换掉 /Applications 里的（开着的 App 发现自己的版本变了会重新打开）
func installApp(pkg string, _ Paths) error {
	src := filepath.Join(pkg, appName)
	if !exists(src) {
		return nil
	}
	dest := filepath.Join("/Applications", appName)
	tmp := filepath.Join("/Applications", ".neu-v6-free-app.new")
	os.RemoveAll(tmp)
	if out, err := exec.Command("/usr/bin/ditto", src, tmp).CombinedOutput(); err != nil {
		return bad("复制 App 失败：%s", strings.TrimSpace(string(out)))
	}
	exec.Command("/usr/sbin/chown", "-R", "root:wheel", tmp).Run()
	bins, _ := filepath.Glob(filepath.Join(tmp, "Contents", "MacOS", "*"))
	for _, f := range bins {
		os.Chmod(f, 0o755)
	}
	old := filepath.Join("/Applications", ".neu-v6-free-app.old")
	os.RemoveAll(old)
	if exists(dest) {
		if err := os.Rename(dest, old); err != nil {
			return err
		}
	}
	if err := os.Rename(tmp, dest); err != nil {
		return err
	}
	os.RemoveAll(old)
	return nil
}

// 运行服务：launchd 停止服务时发 SIGTERM
func runService(_ string, fn func(stop <-chan struct{}) int) {
	stop := make(chan struct{})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sig
		close(stop)
	}()
	os.Exit(fn(stop))
}
