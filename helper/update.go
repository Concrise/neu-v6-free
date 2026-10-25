package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------- 自动更新：从 GitHub Releases 升级程序本身 ----------
// 只从本仓库的正式发布下载本平台的安装包，按同一发布里的 SHA256SUMS 校验；换的是面板、生成器、规则集、
// 本地助手自己和 App，配置、订阅与设置、我的规则都不动（新生成器要在面板里点一次「应用」才用上）。
// 每天自动查一次，装要用户在面板里点。

const updateRepo = "Concrise/neu-v6-free"

var (
	updateAPI    = "https://api.github.com/repos/" + updateRepo + "/releases/latest"
	updatePrefix = "https://github.com/" + updateRepo + "/releases/download/"
)

func init() {
	if v := os.Getenv("NEU_UPDATE_API"); v != "" { // 只给测试用
		updateAPI, updatePrefix = v, ""
	}
}

type updateState struct {
	mu      sync.Mutex
	latest  string
	notes   string
	url     string
	asset   *[2]string // 名字、下载地址
	sums    string
	checked string
	err     string
}

func (h *Helper) currentVersion() string {
	b, err := os.ReadFile(h.p.Version())
	if v := strings.TrimSpace(string(b)); err == nil && v != "" {
		return v
	}
	return "0" // 1.0.0 及更早的安装没有版本文件
}

var reNum = regexp.MustCompile(`\d+`)

func vnewer(a, b string) bool {
	x, y := reNum.FindAllString(a, 3), reNum.FindAllString(b, 3)
	for i := 0; i < 3; i++ {
		var p, q int
		if i < len(x) {
			p, _ = strconv.Atoi(x[i])
		}
		if i < len(y) {
			q, _ = strconv.Atoi(y[i])
		}
		if p != q {
			return p > q
		}
	}
	return false
}

func (h *Helper) updateView() obj {
	u := &h.upd
	u.mu.Lock()
	defer u.mu.Unlock()
	cur := h.currentVersion()
	newer := u.latest != "" && vnewer(u.latest, cur)
	var e any
	if u.err != "" {
		e = u.err
	} else if newer && u.asset == nil {
		e = "新版本还没有" + platformTitle + "安装包"
	}
	nilIfEmpty := func(s string) any {
		if s == "" {
			return nil
		}
		return s
	}
	return obj{"current": cur, "latest": nilIfEmpty(u.latest), "available": newer && u.asset != nil, "notes": u.notes,
		"url": nilIfEmpty(u.url), "checked": nilIfEmpty(u.checked), "error": e}
}

func (h *Helper) checkUpdate() obj {
	d, err := fetchURL(updateAPI, 1<<20, "neu-v6-free")
	u := &h.upd
	u.mu.Lock()
	if err == nil {
		var rel struct {
			Tag    string `json:"tag_name"`
			Body   string `json:"body"`
			URL    string `json:"html_url"`
			Assets []struct {
				Name string `json:"name"`
				URL  string `json:"browser_download_url"`
			} `json:"assets"`
		}
		if err = json.Unmarshal(d.body, &rel); err == nil {
			u.latest, u.notes, u.url, u.asset, u.sums, u.err = strings.TrimPrefix(rel.Tag, "v"), rel.Body, rel.URL, nil, "", ""
			for _, a := range rel.Assets {
				if strings.HasSuffix(a.Name, updateAssetSuffix) {
					u.asset = &[2]string{a.Name, a.URL}
				}
				if a.Name == "SHA256SUMS" {
					u.sums = a.URL
				}
			}
		}
	}
	if err != nil {
		u.err = "检查更新失败：" + err.Error()
	}
	u.checked = stamp()
	u.mu.Unlock()
	return h.updateView()
}

func (h *Helper) updateChecker() {
	time.Sleep(90 * time.Second)
	for {
		h.checkUpdate()
		time.Sleep(24 * time.Hour)
	}
}

func (h *Helper) installUpdate() (obj, error) {
	v := h.checkUpdate()
	if v["available"] != true {
		if e, _ := v["error"].(string); e != "" {
			return nil, bad("%s", e)
		}
		return nil, bad("已经是最新版本")
	}
	h.upd.mu.Lock()
	asset, sumsURL := *h.upd.asset, h.upd.sums
	h.upd.mu.Unlock()
	if sumsURL == "" {
		return nil, bad("发布里没有 SHA256SUMS，没法校验，不安装")
	}
	for _, u := range []string{asset[1], sumsURL} {
		if !strings.HasPrefix(u, updatePrefix) {
			return nil, bad("下载地址不是本项目的发布：%s", u)
		}
	}
	z, err := fetchURL(asset[1], 80<<20, "neu-v6-free")
	if err != nil {
		return nil, err
	}
	sums, err := fetchURL(sumsURL, 1<<16, "neu-v6-free")
	if err != nil {
		return nil, err
	}
	want := ""
	for _, l := range strings.Split(string(sums.body), "\n") {
		if f := strings.Fields(l); len(f) == 2 && f[1] == asset[0] {
			want = strings.ToLower(f[0])
		}
	}
	got := sha256.Sum256(z.body)
	if want == "" || hex.EncodeToString(got[:]) != want {
		return nil, bad("安装包校验不通过（SHA256 不符），没有安装")
	}
	old := h.currentVersion()
	stage, err := os.MkdirTemp(h.p.Etc, ".update-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(stage)
	if err := unzip(z.body, stage); err != nil {
		return nil, err
	}
	pkgs, _ := filepath.Glob(filepath.Join(stage, "*", "VERSION"))
	if len(pkgs) == 0 || !exists(filepath.Join(filepath.Dir(pkgs[0]), selfName)) {
		return nil, bad("安装包的结构不对")
	}
	pkg := filepath.Dir(pkgs[0])
	h.ctl.Lock()
	defer h.ctl.Unlock()
	if err := installPanelAndRules(pkg, h.p, false); err != nil {
		return nil, err
	}
	installExtras(pkg, h.p) // windows：卸载、更新的小脚本
	if err := installApp(pkg, h.p); err != nil {
		logf("换 App 失败：%v", err)
	}
	restart := !sameFile(filepath.Join(pkg, selfName), h.p.Self())
	if restart {
		if err := replaceSelf(filepath.Join(pkg, selfName), h.p.Self()); err != nil {
			return nil, err
		}
	}
	copyFile(filepath.Join(pkg, "VERSION"), h.p.Version(), 0o644)
	setRegisteredVersion(h.currentVersion()) // windows：「设置 → 应用」里登记的版本号
	logf("已从 %s 更新到 %s", old, h.currentVersion())
	if restart {
		h.restartSoon()
	}
	return obj{"ok": true, "from": old, "to": h.currentVersion(), "helper_restart": restart}, nil
}

// 解压：有越出目录的路径就整个不装；保留可执行权限（mac 的 App、助手）
func unzip(data []byte, dest string) error {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return bad("安装包不是有效的 zip：%v", err)
	}
	for _, f := range zr.File {
		n := strings.ReplaceAll(f.Name, `\`, "/")
		if strings.HasPrefix(n, "/") || filepath.IsAbs(n) || strings.Contains("/"+n+"/", "/../") {
			return bad("安装包里有不安全的路径：%s", f.Name)
		}
	}
	for _, f := range zr.File {
		t := filepath.Join(dest, filepath.FromSlash(strings.ReplaceAll(f.Name, `\`, "/")))
		if f.FileInfo().IsDir() {
			os.MkdirAll(t, 0o755)
			continue
		}
		if f.Mode()&os.ModeSymlink != 0 {
			continue
		}
		os.MkdirAll(filepath.Dir(t), 0o755)
		rc, err := f.Open()
		if err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if f.Mode()&0o111 != 0 {
			mode = 0o755
		}
		w, err := os.OpenFile(t, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(w, rc)
		rc.Close()
		w.Close()
		if err != nil {
			return err
		}
	}
	return nil
}
