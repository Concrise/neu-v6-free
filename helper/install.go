package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ---------- 安装 / 升级 ----------
// 发布包（安装程序、zip）里的配置是「起步配置」：面板密钥是占位符 __NEU_SECRET__，第一次安装时随机生成；
// 已经装过时只升级程序和面板，保留现有配置和面板里的订阅、设置。命令行生成的目录（node cli.js）就照装。
// 装完自检能不能上网，不通就让本地助手进安全模式（停掉 sing-box，电脑回到普通网络），状态页能看原因、重新启用。
// 退出代码：0 装好了；1 没装上（什么都没改，或停在出错的那一步）；2 装好了但自检没通过，sing-box 暂停着。

type installOpts struct {
	common
	from, singbox, user string
	noPause, noOpen     bool
}

func cmdInstall(args []string) {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	var o installOpts
	o.register(fs)
	fs.StringVar(&o.from, "from", "", "安装包目录（默认：本程序所在目录）")
	fs.StringVar(&o.singbox, "singbox", "", "用这个 sing-box 可执行文件（默认用安装包里的）")
	fs.StringVar(&o.user, "user", "", "mac：装完替哪个用户打开 App（默认：sudo 的用户 / 登录到桌面的用户）")
	fs.BoolVar(&o.noPause, "no-pause", false, "windows：结束时不等回车（安装程序调用）")
	fs.BoolVar(&o.noOpen, "no-open", false, "装完不打开 App / 面板")
	parseFlags(fs, args)
	ensureAdmin(args)
	code := install(o)
	pauseAtEnd(o.noPause)
	os.Exit(code)
}

func install(o installOpts) int {
	p := o.paths()
	src := o.from
	if src == "" {
		self, _ := os.Executable()
		src = filepath.Dir(self)
	}
	src, _ = filepath.Abs(src)
	cfgPath := filepath.Join(src, "config.json")
	cfgText, err := os.ReadFile(cfgPath)
	if err != nil {
		say("安装失败：%s 里没有 config.json（先生成配置：node cli.js -p %s）", src, platformName)
		return 1
	}
	var cfg obj
	if err := json.Unmarshal(cfgText, &cfg); err != nil {
		say("安装失败：config.json 不是合法的 JSON：%v", err)
		return 1
	}
	if err := checkInstallDirs(cfg, p); err != nil {
		say("安装失败：%v", err)
		return 1
	}
	say("安装到 %s", p.Etc)
	// 起步配置：已经装过就保留现有配置；第一次装就生成随机的面板密钥（写进安装目录时替换）
	starter := bytes.Contains(cfgText, []byte("__NEU_SECRET__"))
	keep := starter && exists(p.Config())
	secret := ""
	if keep {
		say("已经装过：保留现有的配置和面板里的订阅、设置，只升级程序和面板。")
	} else if starter {
		b := make([]byte, 16)
		rand.Read(b)
		secret = hex.EncodeToString(b)
	}

	// 先停掉自己的旧版（本地助手、sing-box、App）；之后端口仍被占用，说明别的代理软件还在跑
	stopInstalled(p)
	time.Sleep(time.Second)
	if busy := busyPorts(listenPorts(cfg)); busy != "" {
		say("安装失败：端口被占用（%s）。先退出 v2rayN、Clash、FlClash 等其他代理软件（包括它们的 TUN 模式），再运行一次。", busy)
		return 1
	}
	preflightWarnings()

	for _, d := range []string{p.Bin, p.Etc, p.Var, p.Data, p.Panel(), filepath.Join(p.Panel(), "lib"), p.Rules()} {
		os.MkdirAll(d, 0o755)
	}
	os.Remove(p.SafeFile()) // 重新安装 = 重新启用（清掉之前的安全模式）
	if err := installSingBox(src, p, o.singbox); err != nil {
		say("安装失败：%v", err)
		return 1
	}
	if self, _ := os.Executable(); !pathEqual(cleanAbs(self), cleanAbs(p.Self())) {
		if err := replaceSelf(self, p.Self()); err != nil {
			say("安装失败：复制本地助手失败：%v", err)
			return 1
		}
	}
	if exists(filepath.Join(src, "VERSION")) {
		copyFile(filepath.Join(src, "VERSION"), p.Version(), 0o644)
	}
	// 配置
	switch {
	case keep:
	case starter:
		if err := writeAtomic(p.Config(), bytes.ReplaceAll(cfgText, []byte("__NEU_SECRET__"), []byte(secret)), 0o600); err != nil {
			say("安装失败：%v", err)
			return 1
		}
	case !pathEqual(cleanAbs(cfgPath), cleanAbs(p.Config())):
		copyFile(cfgPath, p.Config(), 0o600)
	}
	ownRoot(p.Config())
	// 面板、生成器、规则集；保留现有配置时不换 groups.json：它和配置是一对
	if err := installPanelAndRules(src, p, !keep); err != nil {
		say("安装失败：%v", err)
		return 1
	}
	// 面板里「订阅与节点」「设置」的数据（含密钥）：命令行生成的覆盖；发布包只在没有时放一份空的
	pf := filepath.Join(src, "profile.json")
	switch {
	case exists(pf) && (!starter || !exists(p.Profile())):
		copyFile(pf, p.Profile(), 0o600)
	case starter && secret != "" && exists(p.Profile()):
		// 卸载时保留了订阅和设置、这次是重新安装：配置是新的起步配置，提醒在面板里点「应用」
		markPending(p.Profile())
	}
	if err := installApp(src, p); err != nil {
		say("注意：装 App 失败：%v", err)
	}
	installExtras(src, p)
	hardenPermissions(p)
	// 「我的规则」的文件缺了补空的；配置检查要用到
	for _, x := range getList(getObj(cfg, "route"), "rule_set") {
		rs, _ := x.(map[string]any)
		if getStr(rs, "type") == "local" && strings.HasPrefix(getStr(rs, "tag"), "user-") && !exists(getStr(rs, "path")) {
			os.WriteFile(getStr(rs, "path"), []byte(`{"version":2,"rules":[]}`+"\n"), 0o644)
		}
	}
	if out, err := exec.Command(p.SingBox(), "check", "--disable-color", "-c", p.Config()).CombinedOutput(); err != nil {
		say("安装失败：sing-box 检查配置没通过：%s", cmdErr(out, err))
		return 1
	}

	port := o.port
	if port == 0 {
		port = helperPort(p)
	}
	if err := registerService(p, port); err != nil {
		say("安装失败：注册系统服务失败：%v", err)
		return 1
	}
	say("本地助手已启动，正在自检能不能上网（最多一分钟）……")
	// 等 sing-box 和 TUN 网卡真的起来（只看进程在不在不够：打开 TUN 卡住时进程还在，网络照常直连）
	var h obj
	for i := 0; i < 60 && !(h != nil && h["tun"] == true); i++ {
		time.Sleep(time.Second)
		h = health(port)
	}
	st := "broken"
	if h != nil && h["tun"] == true {
		for i := 0; i < 6; i++ {
			time.Sleep(4 * time.Second)
			if st = netState(); st == "ok" {
				break
			}
		}
	}
	installedSecret := readSecret(p)
	if st != "ok" {
		// 不通：让本地助手进安全模式（停掉 sing-box，电脑回到普通网络），再测一次判断原因
		reason := "装上后自检没通过：经 sing-box 上不了网"
		if h == nil || h["tun"] != true {
			reason = "装上后 sing-box 没起来（或者 TUN 网卡没打开）"
		}
		pauseHelper(port, installedSecret, reason)
		without := false
		for i := 0; i < 3 && !without; i++ {
			time.Sleep(3 * time.Second)
			without = tunOK()
		}
		switch {
		case h == nil:
			say("本地助手没有响应，已停止。")
		case h["tun"] != true:
			say("sing-box 没起来（或者 TUN 网卡没打开），已暂停（安全模式），网络恢复原样。")
		case without:
			say("装上后经 sing-box 上不了网，停掉它就能上：已暂停（安全模式），网络恢复原样。")
			say("常见原因：不在校园网（没有 IPv6，模式二连不上服务器），或别的代理软件还开着 TUN。")
		default:
			say("现在网络本身不通（停掉 sing-box 也上不了网），没法自检，已先暂停。联网以后在状态页 http://127.0.0.1:%d/ 点「重新启用」，或再运行一次安装。", port)
		}
		say("最后的日志：")
		say("%s", tail(p.SingBoxLog(), 20))
		say("%s", tail(p.HelperLog(), 10))
		// 程序已经装好（暂停着）：照样放入口、打开 App，状态页里能看原因、点「重新启用」
		createShortcuts(p)
		if !o.noOpen {
			openApp(p, secret, o.user)
		}
		return 2
	}
	say("安装完成：自检通过，经 sing-box 能正常上网；开机自动启动。")
	// 再等本地助手查一次免流服务器（模式二）：连不上时它会自动改走「不用服务器」
	for i := 0; i < 15; i++ {
		if h = health(port); h != nil && h["server_checked"] == true {
			break
		}
		time.Sleep(3 * time.Second)
	}
	if h != nil && h["server_fallback"] != nil {
		say("注意：当前网络连不上免流服务器，已自动改走「不用服务器」（经服务器的流量改为直连，IPv4 计费）。回到能连上服务器的网络后会自动切回。")
	}
	say("万一以后上不了网：本地助手会自动暂停 sing-box；也可以打开 http://127.0.0.1:%d/ 手动暂停或重新启用。", port)
	say("")
	say("面板：http://127.0.0.1:9090/ui")
	if secret != "" {
		say("面板密钥：%s（App 会自动登录；用浏览器打开面板时要用）", secret)
	}
	createShortcuts(p)
	if !o.noOpen {
		openApp(p, secret, o.user)
	}
	say("以后订阅、节点、设置都在面板里改（「订阅与节点」「设置」），新版本在面板「设置」里一键更新。")
	say("卸载：%s", uninstallHint(p))
	return 0
}

// 配置里的面板目录、规则目录要和安装目录一致（生成时的 panel_dir / rules_dir、windows_panel_dir / windows_rules_dir）
func checkInstallDirs(cfg obj, p Paths) error {
	ui := getStr(getObj(getObj(cfg, "experimental"), "clash_api"), "external_ui")
	if ui != "" && !pathEqual(cleanAbs(ui), cleanAbs(p.Panel())) {
		return bad("配置里的面板目录（%s）不是 %s：生成时把 panel_dir（windows：windows_panel_dir）设成安装目录下的 panel，或者安装时用 --name 指定安装目录", ui, p.Panel())
	}
	for _, x := range getList(getObj(cfg, "route"), "rule_set") {
		rs, _ := x.(map[string]any)
		if path := getStr(rs, "path"); path != "" && !pathEqual(cleanAbs(parentOf(path)), cleanAbs(p.Rules())) {
			return bad("配置里的规则目录（%s）不是 %s：生成时把 rules_dir（windows：windows_rules_dir）设成安装目录下的 rules", parentOf(path), p.Rules())
		}
	}
	return checkPaths(cfg, p.Etc)
}

func markPending(profile string) {
	var o obj
	if readJSON(profile, &o) != nil || o["pending"] == true {
		return
	}
	o["pending"] = true
	writeAtomic(profile, marshal(o), 0o600)
	protect(profile)
}

// 哪些端口已经有程序在听（连得上就是有）
func busyPorts(ports []int) string {
	var busy []string
	for _, port := range ports {
		c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 500*time.Millisecond)
		if err != nil {
			continue
		}
		c.Close()
		if who := portOwner(port); who != "" {
			busy = append(busy, fmt.Sprintf("%d（%s）", port, who))
		} else {
			busy = append(busy, fmt.Sprint(port))
		}
	}
	return strings.Join(busy, "、")
}

func readSecret(p Paths) string {
	c, err := loadConf(p.Config())
	if err != nil {
		return ""
	}
	return c.Secret
}

// 让正在运行的本地助手进安全模式（停掉 sing-box、恢复网卡设置）
func pauseHelper(port int, secret, reason string) bool {
	req, _ := http.NewRequest("POST", fmt.Sprintf("http://127.0.0.1:%d/pause", port), bytes.NewReader(marshal(obj{"reason": reason})))
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 40 * time.Second, Transport: &http.Transport{Proxy: nil}}).Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == 200
}

func tail(path string, n int) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(b), "\r\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// ---------- 卸载 ----------
// 默认保留「我的规则」、订阅和设置（profile.json）、流量统计，重新安装后接着用；--purge 全部删除

func cmdUninstall(args []string) {
	fs := flag.NewFlagSet("uninstall", flag.ExitOnError)
	var c common
	c.register(fs)
	purge := fs.Bool("purge", false, "连「我的规则」、订阅和设置、流量统计一起删")
	noPause := fs.Bool("no-pause", false, "windows：结束时不等回车（卸载程序调用）")
	parseFlags(fs, args)
	ensureAdmin(args)
	runFromTemp(args) // windows：程序自己也要删，先复制到临时目录再运行
	p := c.paths()
	stopInstalled(p)
	unregisterService(p)
	stopStray(p.SingBox())
	restoreWeakHost(p)
	removeApp(p)
	keep := map[string]bool{"profile.json": true, "traffic.json": true, "rules": true, "uninstall-neu-v6-free.exe": true}
	for _, d := range uniq(p.Bin, p.Etc, p.Var) {
		entries, _ := os.ReadDir(d)
		for _, e := range entries {
			if !*purge && keep[e.Name()] {
				continue
			}
			os.RemoveAll(filepath.Join(d, e.Name()))
		}
	}
	if !*purge {
		srs, _ := filepath.Glob(filepath.Join(p.Rules(), "*.srs"))
		for _, f := range srs {
			os.Remove(f)
		}
	}
	for _, d := range uniq(p.Bin, p.Etc, p.Var) {
		os.Remove(d) // 空了才删得掉
	}
	if *purge {
		say("已卸载，「我的规则」、订阅和设置、流量统计也都已删除。可以重新打开其他代理软件。")
	} else {
		say("已卸载。可以重新打开其他代理软件。")
		say("「我的规则」（%s）、订阅和设置（profile.json）、流量统计（traffic.json）保留，重新安装后接着用；要一起删除：卸载时加 --purge", p.Rules())
	}
	pauseAtEnd(*noPause)
}

func uniq(list ...string) []string {
	var out []string
	seen := map[string]bool{}
	for _, s := range list {
		if !seen[strings.ToLower(s)] {
			seen[strings.ToLower(s)] = true
			out = append(out, s)
		}
	}
	return out
}

// ---------- sing-box ----------

// 安装程序里自带的、找不到时下载的 sing-box：固定用测试过的版本（新的大版本常常改配置格式）。和 cli.js 的 SINGBOX_VERSION 一起改
const singBoxVersionPinned = "1.13.21"

func singBoxVersion(exe string) string {
	out, err := exec.Command(exe, "version").Output()
	if err != nil {
		return "版本未知"
	}
	return strings.SplitN(strings.TrimSpace(string(out)), "\n", 2)[0]
}

// 从 GitHub 下载固定版本的 sing-box，取出可执行文件装到 dest
func downloadSingBox(target, dest string) error {
	v := singBoxVersionPinned
	ext := ".tar.gz"
	if strings.HasPrefix(target, "windows") {
		ext = ".zip"
	}
	u := fmt.Sprintf("https://github.com/SagerNet/sing-box/releases/download/v%s/sing-box-%s-%s%s", v, v, target, ext)
	say("正在从 GitHub 下载 sing-box %s……", v)
	d, err := (&http.Client{Timeout: 5 * time.Minute}).Get(u)
	if err != nil {
		return fmt.Errorf("下载 sing-box 失败（%v）：用安装程序安装（自带 sing-box），或用 --singbox 指定", err)
	}
	defer d.Body.Close()
	if d.StatusCode != 200 {
		return fmt.Errorf("下载 sing-box 失败（HTTP %d）：用安装程序安装（自带 sing-box），或用 --singbox 指定", d.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(d.Body, 200<<20))
	if err != nil {
		return err
	}
	var bin []byte
	if ext == ".zip" {
		zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
		if err != nil {
			return err
		}
		for _, f := range zr.File {
			if filepath.Base(f.Name) == singBoxName {
				rc, _ := f.Open()
				bin, err = io.ReadAll(rc)
				rc.Close()
				if err != nil {
					return err
				}
			}
		}
	} else {
		gz, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return err
		}
		tr := tar.NewReader(gz)
		for {
			h, err := tr.Next()
			if err != nil {
				break
			}
			if filepath.Base(h.Name) == singBoxName && h.Typeflag == tar.TypeReg {
				if bin, err = io.ReadAll(tr); err != nil {
					return err
				}
			}
		}
	}
	if len(bin) == 0 {
		return fmt.Errorf("下载的压缩包里没有 %s", singBoxName)
	}
	if err := writeAtomic(dest, bin, 0o755); err != nil {
		return err
	}
	ownRoot(dest)
	say("sing-box：已下载 %s", v)
	return nil
}
