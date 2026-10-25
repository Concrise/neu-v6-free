package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Helper：本地助手的全部状态
type Helper struct {
	p    Paths
	port int
	cur  atomic.Pointer[Conf] // 正在用的配置；/apply 装了新配置后换掉

	ctl     sync.Mutex // 改动 sing-box 状态的操作（更新配置、暂停、重新启用、看护、自动更新）一次只做一件
	rulesMu sync.Mutex
	sb      *SingBox
	traffic *Traffic

	// 看护（只在持有 ctl 时读写）
	restarts     []time.Time
	fails        int
	offline      int
	firstCheck   bool
	lastWatch    time.Time
	lastStopTest time.Time

	// 服务器检查（只在持有 ctl 时读写）
	guardFails, guardOks int
	guardRetry           time.Time
	serverChecked        atomic.Bool

	upd updateState

	quit chan int // 退出：0 正常停止，1 升级后重启
	noSB bool     // 开发调试：不碰 sing-box
}

func (h *Helper) conf() *Conf { return h.cur.Load() }

func (h *Helper) reload() error {
	c, err := loadConf(h.p.Config())
	if err != nil {
		return err
	}
	h.cur.Store(c)
	publishSecret(h.p, c.Secret)
	return nil
}

// 面板 groups.json 里的 traffic_port，没有就是 9091
func helperPort(p Paths) int {
	var g struct {
		TrafficPort int `json:"traffic_port"`
	}
	if readJSON(p.Panel()+string(os.PathSeparator)+"groups.json", &g) == nil && g.TrafficPort > 0 {
		return g.TrafficPort
	}
	return 9091
}

func cmdRun(args []string) {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	var c common
	c.register(fs)
	etc := fs.String("etc", "", "配置目录（开发调试用）")
	vardir := fs.String("var", "", "状态目录（开发调试用）")
	noSB := fs.Bool("no-singbox", false, "不启动、不看护 sing-box（开发调试：用已经在运行的 sing-box）")
	parseFlags(fs, args)
	p := c.paths()
	if *etc != "" {
		p.Etc = *etc
	}
	if *vardir != "" {
		p.Var, p.Data = *vardir, *vardir
	}
	port := c.port
	if port == 0 {
		port = helperPort(p)
	}
	runService(p.Label, func(stop <-chan struct{}) int {
		return runHelper(p, port, *noSB, stop)
	})
}

// 运行本地助手，直到 stop 关闭（服务被停止）或者升级后要重启。返回退出代码
func runHelper(p Paths, port int, noSB bool, stop <-chan struct{}) int {
	os.MkdirAll(p.Var, 0o755)
	openLog(p)
	h := &Helper{p: p, port: port, sb: &SingBox{p: p}, quit: make(chan int, 1), firstCheck: true, noSB: noSB}
	if err := h.reload(); err != nil {
		logf("读取配置 %s 失败：%v", p.Config(), err)
		return 1
	}
	// 旧版留下的备份没收紧权限；上次更新换下来的 App 文件
	protect(p.Config() + ".prev")
	protect(p.Config() + ".new")
	cleanOldFiles(p)
	removeMigrateStages(p)
	go func() { time.Sleep(5 * time.Minute); removeMigrateStages(p) }() // 安装程序可能还在里面运行（windows 上删不掉正在运行的程序）
	h.traffic = newTraffic(h)
	c := h.conf()
	if len(c.Targets) > 0 {
		if err := h.applyRules(c, h.loadRules(c)); err != nil { // 启动时按 user-rules.json 重写一遍规则文件
			logf("写「我的规则」失败：%v", err)
		}
	}
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		logf("监听 127.0.0.1:%d 失败（端口被占用？）：%v", port, err)
		return 1
	}
	if !noSB {
		if s := h.safeMode(); s != nil {
			h.sb.stop()
			restoreWeakHost(p)
			logf("安全模式（%s）：保持 sing-box 停止，在 http://127.0.0.1:%d/ 重新启用", s.Reason, port)
		} else if err := h.sb.start(); err != nil {
			logf("启动 sing-box 失败：%v", err)
		}
	}
	logf("本地助手 %s 已启动：127.0.0.1:%d，配置 %s", version, port, p.Config())
	go h.serve(ln)
	go h.traffic.run()
	go h.updateChecker()
	go grantSecretLoop(p)
	if !noSB {
		go h.supervise()
	}
	code := 0
	select {
	case <-stop:
	case code = <-h.quit:
	}
	ln.Close()
	if !noSB {
		h.ctl.Lock() // 等正在做的操作做完，再停 sing-box
		h.sb.stop()
		restoreWeakHost(p)
	}
	h.traffic.save()
	logf("本地助手退出（%d）", code)
	return code
}

// 升级了助手自己：先回完话，再退出；系统服务（launchd / Windows 服务）会拉起新版
func (h *Helper) restartSoon() {
	go func() {
		time.Sleep(time.Second)
		select {
		case h.quit <- 1:
		default:
		}
	}()
}

func trimErr(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

// 1.1.x 自动升级时，迁移脚本（安装包里的 helper.py / helper.ps1）把新版安装包解压在 .migrate-* 里运行安装程序
func removeMigrateStages(p Paths) {
	for _, d := range uniq(p.Etc, p.Bin) {
		dirs, _ := filepath.Glob(filepath.Join(d, ".migrate-*"))
		for _, x := range dirs {
			os.RemoveAll(x)
		}
	}
}
