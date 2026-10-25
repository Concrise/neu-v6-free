package main

import (
	"fmt"
	"os"
	"os/exec"
	"sync"
	"time"
)

// ---------- 运行 sing-box ----------
// 助手启动 sing-box 当子进程并看着它：退出了就重新拉起，反复崩溃就进安全模式。
// （以前 mac 上 sing-box 是单独一个 launchd 服务，windows 上由助手拉起；现在两边一样。）

type SingBox struct {
	p         Paths
	mu        sync.Mutex
	cmd       *exec.Cmd
	done      chan struct{}
	exitCode  int
	lastStart time.Time
}

func (s *SingBox) running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.runningLocked()
}

func (s *SingBox) runningLocked() bool {
	if s.cmd == nil {
		return false
	}
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

// 已经退出的上一个进程的退出代码；没启动过时 ok 为 false
func (s *SingBox) exited() (code int, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd == nil || s.runningLocked() {
		return 0, false
	}
	return s.exitCode, true
}

func (s *SingBox) start() error {
	s.stop()
	exe := s.p.SingBox()
	if !exists(exe) {
		return fmt.Errorf("找不到 %s，重新运行安装程序", exe)
	}
	fixWeakHost(s.p)
	if err := os.MkdirAll(s.p.Data, 0o755); err != nil {
		return err
	}
	// 上一次的日志留一份：sing-box 退出的原因在里面，重新启动会把 sing-box.log 清空
	log := s.p.SingBoxLog()
	if exists(log) {
		os.Rename(log, s.p.SingBoxLog()[:len(log)-len(".log")]+".prev.log")
	}
	f, err := os.OpenFile(log, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	cmd := exec.Command(exe, "run", "-c", s.p.Config(), "-D", s.p.Data, "--disable-color")
	cmd.Dir = s.p.Data
	cmd.Stdout, cmd.Stderr = f, f
	singBoxProcAttr(cmd)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastStart = time.Now()
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan struct{})
	s.cmd, s.done = cmd, done
	go func() {
		err := cmd.Wait()
		code := 0
		if e, ok := err.(*exec.ExitError); ok {
			code = e.ExitCode()
		}
		s.mu.Lock()
		if s.cmd == cmd {
			s.exitCode = code
		}
		s.mu.Unlock()
		close(done)
	}()
	logf("sing-box 已启动（pid %d）", cmd.Process.Pid)
	// 暂停期间系统缓存了真实 DNS 的结果（被污染的国外网站地址），不清掉要等缓存过期才走 sing-box；TUN 起来要一两秒，清两次
	go func() {
		for _, d := range []time.Duration{2 * time.Second, 4 * time.Second} {
			select {
			case <-done:
				return
			case <-time.After(d):
				flushDNS()
			}
		}
	}()
	return nil
}

// 先让它自己退出（撤掉 TUN 网卡和路由），10 秒没退再强杀。
// 强杀会留下没清理干净的 TUN 网卡：紧接着再启动时打不开 TUN（windows 实测十几秒后以代码 1 退出）
func (s *SingBox) stop() {
	s.mu.Lock()
	cmd, done := s.cmd, s.done
	s.mu.Unlock()
	if cmd != nil {
		select {
		case <-done:
		default:
			logf("停止 sing-box（pid %d）", cmd.Process.Pid)
			stopGracefully(cmd.Process.Pid)
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				logf("sing-box（pid %d）10 秒内没有正常退出，强制结束", cmd.Process.Pid)
				cmd.Process.Kill()
				select {
				case <-done:
				case <-time.After(5 * time.Second):
				}
			}
			// 系统缓存里还有 sing-box 给的假地址（198.18.x），不清掉这些网站要等缓存过期才能直连
			flushDNS()
		}
	}
	// 上一个助手留下的（助手升级、异常退出时），以及旧版单独运行的 sing-box
	stopStray(s.p.SingBox())
}

// ---------- 安全模式 ----------
// 停掉 sing-box（TUN 随之撤销，电脑回到普通网络），记下原因；重启电脑后也保持，直到手动重新启用或更新配置

type SafeMode struct {
	Since  string `json:"since"`
	Reason string `json:"reason"`
}

func (h *Helper) safeMode() *SafeMode {
	var s SafeMode
	if !exists(h.p.SafeFile()) {
		return nil
	}
	if readJSON(h.p.SafeFile(), &s) != nil {
		return &SafeMode{Reason: "未知"}
	}
	return &s
}

func (h *Helper) enterSafeMode(reason string) {
	h.sb.stop()
	restoreWeakHost(h.p)
	_ = writeAtomic(h.p.SafeFile(), marshal(SafeMode{Since: stamp(), Reason: reason}), 0o644)
	logf("进入安全模式：%s", reason)
}

func (h *Helper) leaveSafeMode() error {
	os.Remove(h.p.SafeFile())
	h.restarts = nil
	h.firstCheck = true
	return h.sb.start()
}

// sing-box 刚启动时给它一点时间；期间 TUN 起来并且能上网就返回 ok。到时间 TUN 还没起来算 broken（sing-box 没在工作）
func (h *Helper) waitNet(seconds int) string {
	end := time.Now().Add(time.Duration(seconds) * time.Second)
	st := "broken"
	for time.Now().Before(end) {
		time.Sleep(4 * time.Second)
		if !tunUp(h.conf().TunName) {
			continue
		}
		if st = netState(); st == "ok" {
			return st
		}
	}
	return st
}

// 「绕过 sing-box」的探测并不总是真的绕过（例如 windows 网卡打开了 WeakHostSend 时，绑定物理网卡地址的包照样进 TUN），
// 所以「经 sing-box 不通、绕过也不通」时，停掉 sing-box 再试一次才算数：停掉就通 = 是 sing-box 的问题（返回 true，
// sing-box 保持停止）；停掉也不通 = 网络本身不通，重新启动 sing-box
func (h *Helper) okWithoutSingBox() bool {
	h.lastStopTest = time.Now()
	h.sb.stop()
	restoreWeakHost(h.p)
	for i := 0; i < 3; i++ {
		time.Sleep(3 * time.Second)
		if tunOK() {
			logf("停掉 sing-box 后能上网：是 sing-box 的问题")
			return true
		}
	}
	if err := h.sb.start(); err != nil {
		logf("启动 sing-box 失败：%v", err)
	}
	return false
}

// 启动（安装、更新、重新启用）后的判断：ok / broken（sing-box 的问题）/ offline（网络本身不通，sing-box 在运行）
func (h *Helper) checkAfterStart() string {
	st := h.waitNet(25)
	if st != "offline" {
		return st
	}
	if h.okWithoutSingBox() {
		return "broken"
	}
	return "offline"
}

// 重新启用：启动 sing-box 并确认能上网，不行就退回安全模式
func (h *Helper) resume() (obj, error) {
	if h.noSB {
		return nil, bad("开发调试模式（--no-singbox）不能重新启用")
	}
	h.ctl.Lock()
	defer h.ctl.Unlock()
	if err := h.leaveSafeMode(); err != nil {
		h.enterSafeMode("sing-box 启动失败：" + err.Error())
		return nil, bad("sing-box 启动失败：%v", err)
	}
	st := h.checkAfterStart()
	if st == "broken" {
		h.enterSafeMode("重新启用后经 sing-box 仍然上不了网")
		return nil, bad("重新启用后经 sing-box 仍然上不了网，已再次暂停。看 sing-box.log；离开校园网时先在面板里选「不用服务器」")
	}
	logf("已重新启用")
	if st == "ok" {
		h.serverCheck(true)
		h.firstCheck = false
	}
	return obj{"ok": true, "net": st, "server_fallback": h.fallback()}, nil
}

func (h *Helper) pause(reason string) {
	if h.noSB {
		return
	}
	h.ctl.Lock()
	defer h.ctl.Unlock()
	h.enterSafeMode(reason)
}

// ---------- 看护 ----------
// 每秒看一眼：退出了就重新拉起（两次之间至少隔 10 秒）；3 分钟内退出 5 次就不再拉起（安全模式）。
// 每 30 秒检查一次网络，连续 3 次「经 sing-box 不通、绕过它能通」也进安全模式；
// 连续 3 次「都不通」时停掉 sing-box 试一次（最多 10 分钟一次），停掉就通也进安全模式

func (h *Helper) supervise() {
	for {
		time.Sleep(time.Second)
		h.ctl.Lock()
		func() {
			defer func() {
				if r := recover(); r != nil { // 看护自己不能挂
					logf("看护出错：%v", r)
				}
			}()
			h.superviseTick()
		}()
		h.ctl.Unlock()
	}
}

func (h *Helper) superviseTick() {
	if h.safeMode() != nil {
		return
	}
	if !h.sb.running() {
		if time.Since(h.sb.lastStart) < 10*time.Second {
			return
		}
		if code, ok := h.sb.exited(); ok {
			logf("sing-box 退出了（代码 %d），原因见 sing-box.prev.log", code)
			now := time.Now()
			keep := h.restarts[:0]
			for _, t := range h.restarts {
				if now.Sub(t) <= 3*time.Minute {
					keep = append(keep, t)
				}
			}
			h.restarts = append(keep, now)
			if len(h.restarts) >= 5 {
				h.enterSafeMode("sing-box 3 分钟内退出了 5 次（看 sing-box.log 和 sing-box.prev.log）")
				return
			}
		}
		if err := h.sb.start(); err != nil {
			logf("启动 sing-box 失败：%v", err)
		}
		h.firstCheck = true
		return
	}
	if time.Since(h.lastWatch) < 30*time.Second {
		return
	}
	h.lastWatch = time.Now()
	if time.Since(h.sb.lastStart) < 20*time.Second {
		return // 刚启动，等它准备好
	}
	fixWeakHost(h.p) // 新插上的网卡（网线、USB 网卡）
	st := netState()
	if st == "broken" {
		h.fails++
		logf("经 sing-box 上不了网，绕过它能上（第 %d 次）", h.fails)
	} else {
		h.fails = 0
	}
	if st == "offline" {
		h.offline++
	} else {
		h.offline = 0
	}
	if st == "ok" {
		h.serverCheck(h.firstCheck) // 刚启动时立刻判断一次服务器，免得连不上时干等一分多钟
		h.firstCheck = false
	}
	switch {
	case h.fails >= 3:
		h.fails = 0
		h.enterSafeMode("连续 3 次检查经 sing-box 上不了网、绕过它能上（配置或 sing-box 本身有问题）")
	case h.offline >= 3 && time.Since(h.lastStopTest) >= 10*time.Minute:
		h.offline = 0
		logf("连续 3 次检查都上不了网，停掉 sing-box 试一下")
		if h.okWithoutSingBox() {
			h.enterSafeMode("经 sing-box 上不了网，停掉它就能上（配置或 sing-box 本身有问题）")
		}
	}
}
