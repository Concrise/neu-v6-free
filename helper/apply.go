package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// ---------- 客户端：订阅、节点、设置都在面板里管 ----------
// 面板保存的全部设置（订阅链接与内容、手动节点、模式、服务器……）存在 profile.json，只有管理员能读。
// 面板在浏览器里用 lib/build.js 生成配置，再交给 /apply 安装；助手只负责存取设置、代为下载订阅（浏览器有跨域限制）。
// 设置按原文存取，不重新排版。

const (
	maxBody     = 32 << 20
	maxDownload = 20 << 20
)

var safeName = regexp.MustCompile(`^[\w.!+-]+$`)

// 和这次安装绑定、面板不该改的设置：从正在用的配置里读。面板生成配置时用它们覆盖 profile 里的同名项
func (h *Helper) installDefaults() obj {
	c := h.conf()
	clash := getObj(getObj(c.Raw, "experimental"), "clash_api")
	var main obj
	for _, in := range getList(c.Raw, "inbounds") {
		if m, ok := in.(map[string]any); ok && getStr(m, "tag") == "main" {
			main = m
		}
	}
	rulesDir := h.p.Rules()
	for _, rs := range getList(getObj(c.Raw, "route"), "rule_set") {
		m, _ := rs.(map[string]any)
		if getStr(m, "type") == "local" && getStr(m, "format") == "binary" {
			rulesDir = parentOf(getStr(m, "path"))
			break
		}
	}
	panelDir := c.UI
	if panelDir == "" {
		panelDir = h.p.Panel()
	}
	listen, mainPort := getStr(main, "listen"), int(getNum(main, "listen_port"))
	if listen == "" {
		listen = "127.0.0.1"
	}
	if mainPort == 0 {
		mainPort = 10808
	}
	d := obj{"platform": platformName, "clash_api": getStr(clash, "external_controller"), "clash_api_secret": c.Secret,
		"listen": listen, "main_port": mainPort, "traffic_port": h.port}
	if platformName == "windows" {
		d["windows_panel_dir"], d["windows_rules_dir"] = slash(panelDir), slash(rulesDir)
	} else {
		d["panel_dir"], d["rules_dir"] = panelDir, rulesDir
	}
	return d
}

// 路径的上一级（配置里 windows 的路径可能用 /）
func parentOf(p string) string {
	if i := strings.LastIndexAny(p, `/\`); i > 0 {
		return p[:i]
	}
	return p
}

func slash(p string) string { return strings.ReplaceAll(p, `\`, "/") }

// GET /profile 的内容：{"profile": 原文或 null, "defaults": {...}}
func (h *Helper) profileView() []byte {
	p, err := os.ReadFile(h.p.Profile())
	if err != nil || !json.Valid(p) {
		p = []byte("null")
	}
	return []byte(`{"profile":` + string(p) + `,"defaults":` + string(marshal(h.installDefaults())) + `}`)
}

func (h *Helper) saveProfile(text []byte) error {
	var o map[string]any
	if json.Unmarshal(text, &o) != nil || o == nil {
		return bad("设置的格式不对")
	}
	if err := writeAtomic(h.p.Profile(), text, 0o600); err != nil {
		return err
	}
	protect(h.p.Profile())
	return nil
}

type download struct {
	status                int
	userinfo, disposition string
	body                  []byte
}

var downloadClient = &http.Client{Timeout: 30 * time.Second}

func fetchURL(u string, limit int64, ua string) (*download, error) {
	pu, err := url.Parse(u)
	if err != nil || (pu.Scheme != "http" && pu.Scheme != "https") || pu.Host == "" {
		return nil, bad("只支持 http / https 链接")
	}
	req, _ := http.NewRequest("GET", u, nil)
	req.Header.Set("User-Agent", ua)
	resp, err := downloadClient.Do(req)
	if err != nil {
		return nil, bad("下载失败：%v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, bad("服务器返回 %d（链接失效或过期？）", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, bad("下载失败：%v", err)
	}
	if int64(len(b)) > limit {
		return nil, bad("内容太大（超过 %dMB）", limit>>20)
	}
	return &download{resp.StatusCode, resp.Header.Get("subscription-userinfo"), resp.Header.Get("content-disposition"), b}, nil
}

func fetchSubscription(u string) (obj, error) {
	// 带 clash.meta 的 User-Agent：多数机场据此返回完整的 mihomo 配置（不然给的是 base64 链接，信息更少）
	d, err := fetchURL(u, maxDownload, "clash.meta (neu-v6-free)")
	if err != nil {
		return nil, err
	}
	ui := any(nil)
	if d.userinfo != "" {
		ui = d.userinfo
	}
	disp := any(nil)
	if d.disposition != "" {
		disp = d.disposition
	}
	return obj{"status": d.status, "text": strings.ToValidUTF8(string(d.body), "�"), "userinfo": ui, "disposition": disp}, nil
}

// 面板生成的配置：放进临时生成目录（和 cli.js 的输出一样的结构），缺的规则集按面板给的地址下载，再走 applyDir
func (h *Helper) applyInline(body obj) (obj, error) {
	text := func(k string) ([]byte, error) {
		switch v := body[k].(type) {
		case string: // 面板发来的是 JSON 文本
			return []byte(v), nil
		case map[string]any:
			return marshal(v), nil
		}
		return nil, bad("缺少 config 或 panel")
	}
	confText, err := text("config")
	if err != nil {
		return nil, err
	}
	panelText, err := text("panel")
	if err != nil {
		return nil, err
	}
	var conf obj
	if json.Unmarshal(confText, &conf) != nil {
		return nil, bad("配置不是合法的 JSON")
	}
	if err := checkPaths(conf, h.p.Etc); err != nil {
		return nil, err
	}
	urls := getObj(body, "rule_sets")
	stage, err := os.MkdirTemp(h.p.Etc, ".stage-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(stage)
	os.MkdirAll(filepath.Join(stage, "rules"), 0o755)
	os.MkdirAll(filepath.Join(stage, "panel"), 0o755)
	if err := os.WriteFile(filepath.Join(stage, "config.json"), confText, 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(stage, "panel", "groups.json"), panelText, 0o644); err != nil {
		return nil, err
	}
	for _, x := range getList(getObj(conf, "route"), "rule_set") {
		rs, _ := x.(map[string]any)
		if getStr(rs, "type") != "local" {
			continue
		}
		name := filepath.Base(slash(getStr(rs, "path")))
		if i := strings.LastIndex(name, "/"); i >= 0 {
			name = name[i+1:]
		}
		if !safeName.MatchString(name) {
			return nil, bad("规则集文件名不对：%s", name)
		}
		if getStr(rs, "format") == "source" { // 「我的规则」的文件：applyDir 只补缺的
			os.WriteFile(filepath.Join(stage, "rules", name), []byte(`{"version":2,"rules":[]}`+"\n"), 0o644)
			continue
		}
		if exists(getStr(rs, "path")) {
			continue
		}
		u := getStr(urls, getStr(rs, "tag"))
		if !strings.HasPrefix(u, "https://") {
			return nil, bad("本机没有规则集 %s，也没有给下载地址", getStr(rs, "tag"))
		}
		d, err := fetchURL(u, maxDownload, "neu-v6-free")
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(filepath.Join(stage, "rules", name), d.body, 0o644); err != nil {
			return nil, err
		}
	}
	return h.applyDir(stage)
}

// 把生成目录（cli.js 的 out/<平台>，或 applyInline 的临时目录）里的新配置装好并重启 sing-box
func (h *Helper) applyDir(src string) (obj, error) {
	src, _ = filepath.Abs(src)
	cfgFile := filepath.Join(src, "config.json")
	b, err := os.ReadFile(cfgFile)
	if err != nil {
		return nil, bad("%s 里没有 config.json", src)
	}
	var conf obj
	if err := json.Unmarshal(b, &conf); err != nil {
		return nil, bad("config.json 不是合法的 JSON：%v", err)
	}
	if err := checkPaths(conf, h.p.Etc); err != nil {
		return nil, err
	}
	h.ctl.Lock()
	defer h.ctl.Unlock()
	if err := installPanelAndRules(src, h.p, true); err != nil {
		return nil, err
	}
	if exists(filepath.Join(src, "VERSION")) {
		copyFile(filepath.Join(src, "VERSION"), h.p.Version(), 0o644)
	}
	if pf := filepath.Join(src, "profile.json"); exists(pf) { // 命令行的设置覆盖面板里的
		if err := copyFile(pf, h.p.Profile(), 0o600); err != nil {
			return nil, err
		}
		protect(h.p.Profile())
	}
	for _, x := range getList(getObj(conf, "route"), "rule_set") { // 「我的规则」的文件缺了就补一个空的
		rs, _ := x.(map[string]any)
		if getStr(rs, "type") == "local" && strings.HasPrefix(getStr(rs, "tag"), "user-") && !exists(getStr(rs, "path")) {
			os.WriteFile(getStr(rs, "path"), []byte(`{"version":2,"rules":[]}`+"\n"), 0o644)
		}
	}
	staged := h.p.Config() + ".new"
	if err := copyFile(cfgFile, staged, 0o600); err != nil {
		return nil, err
	}
	protect(staged)
	if out, err := exec.Command(h.p.SingBox(), "check", "--disable-color", "-c", staged).CombinedOutput(); err != nil {
		os.Remove(staged)
		return nil, bad("sing-box 检查没通过，旧配置没动：%s", trimErr(string(out), 800))
	}
	backup := h.p.Config() + ".prev"
	if err := copyFile(h.p.Config(), backup, 0o600); err != nil { // 有密钥和节点密码，和 config.json 一样只给管理员
		return nil, err
	}
	protect(backup)
	if err := os.Rename(staged, h.p.Config()); err != nil {
		return nil, err
	}
	if err := h.reload(); err != nil {
		return nil, err
	}
	c := h.conf()
	if len(c.Targets) > 0 {
		h.rulesMu.Lock()
		h.applyRules(c, h.loadRules(c))
		h.rulesMu.Unlock()
	}
	if h.noSB { // 开发调试：配置换好就行
		return obj{"ok": true, "restarted": false, "helper_updated": false, "server_fallback": h.fallback()}, nil
	}
	// 更新配置 = 重新启用
	if h.safeMode() != nil {
		err = h.leaveSafeMode()
	} else {
		err = h.sb.start()
		h.firstCheck = true
	}
	if err != nil {
		logf("启动 sing-box 失败：%v", err)
	}
	if h.checkAfterStart() == "broken" {
		os.Rename(backup, h.p.Config())
		h.reload()
		h.sb.start()
		st := h.checkAfterStart()
		extra := ""
		if st == "broken" {
			h.enterSafeMode("新配置和旧配置经 sing-box 都上不了网")
			extra = "；旧配置也不通，已暂停 sing-box（安全模式）"
		}
		logf("新配置装上后经 sing-box 上不了网，已换回旧配置")
		return nil, bad("新配置装上后经 sing-box 上不了网，已自动换回旧配置%s。看 sing-box.log；离开校园网时先在面板里选「不用服务器」", extra)
	}
	// 命令行生成的目录里带着新版助手：换上，回完话后重启
	updated := false
	if nb := filepath.Join(src, selfName); exists(nb) && !sameFile(nb, h.p.Self()) {
		if err := replaceSelf(nb, h.p.Self()); err != nil {
			logf("换新版助手失败：%v", err)
		} else {
			updated = true
			h.restartSoon()
		}
	}
	h.serverCheck(true)
	h.firstCheck = false
	return obj{"ok": true, "restarted": true, "helper_updated": updated, "server_fallback": h.fallback()}, nil
}

// 面板、生成器、规则集从生成目录或安装包装进安装目录。withMeta：连 groups.json 一起换（它和配置是一对）
func installPanelAndRules(src string, p Paths, withMeta bool) error {
	names := []string{"index.html"}
	if withMeta {
		names = append(names, "groups.json")
	}
	for _, n := range names {
		if f := filepath.Join(src, "panel", n); exists(f) {
			if err := copyFile(f, filepath.Join(p.Panel(), n), 0o644); err != nil {
				return err
			}
		}
	}
	libs, _ := filepath.Glob(filepath.Join(src, "panel", "lib", "*")) // 面板在浏览器里生成配置用的模块
	for _, f := range libs {
		if err := copyFile(f, filepath.Join(p.Panel(), "lib", filepath.Base(f)), 0o644); err != nil {
			return err
		}
	}
	srs, _ := filepath.Glob(filepath.Join(src, "rules", "*.srs"))
	for _, f := range srs {
		if err := copyFile(f, filepath.Join(p.Rules(), filepath.Base(f)), 0o644); err != nil {
			return err
		}
	}
	users, _ := filepath.Glob(filepath.Join(src, "rules", "user-*.json")) // 「我的规则」只补缺的
	for _, f := range users {
		if t := filepath.Join(p.Rules(), filepath.Base(f)); !exists(t) {
			copyFile(f, t, 0o644)
		}
	}
	return nil
}
