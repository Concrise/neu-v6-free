package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestNormalizeRule(t *testing.T) {
	ok := []struct{ kind, in, want string }{
		{"domain_suffix", "https://WWW.Example.COM:443/path?q=1", "www.example.com"},
		{"domain_suffix", "*.example.com.", "example.com"},
		{"domain", "中文.com", "xn--fiq228c.com"},
		{"domain_keyword", "Google", "google"},
		{"ip_cidr", "1.2.3.4", "1.2.3.4/32"},
		{"ip_cidr", "1.2.3.4/24", "1.2.3.0/24"},
		{"ip_cidr", "2400:3200::1", "2400:3200::1/128"},
		{"process_name", "WeChat", "WeChat"},
	}
	for _, c := range ok {
		got, err := normalizeRule(c.kind, c.in)
		if err != nil || got != c.want {
			t.Errorf("normalizeRule(%s, %q) = %q, %v；应该是 %q", c.kind, c.in, got, err, c.want)
		}
	}
	bad := []struct{ kind, in string }{
		{"domain_suffix", "bad domain!"}, {"domain_keyword", "a b"}, {"ip_cidr", "1.2.3"}, {"ip_cidr", "fe80::1%en0"},
		{"process_name", `C:\x\chrome.exe`}, {"domain", ""}, {"nope", "x"},
	}
	for _, c := range bad {
		if got, err := normalizeRule(c.kind, c.in); err == nil {
			t.Errorf("normalizeRule(%s, %q) = %q，应该报错", c.kind, c.in, got)
		}
	}
}

func TestCheckPaths(t *testing.T) {
	base := "/usr/local/etc/neu"
	in := "/usr/local/etc/neu/rules/a.srs"
	out := "/etc/passwd"
	if runtime.GOOS == "windows" {
		base, in, out = `C:\neu-v6-free`, "C:/neu-v6-free/rules/a.srs", `C:\Windows\x.srs`
	}
	conf := func(p string) obj {
		return obj{"route": obj{"rule_set": []any{map[string]any{"tag": "a", "type": "local", "path": p}}}}
	}
	if err := checkPaths(conf(in), base); err != nil {
		t.Errorf("安装目录里的路径被拒：%v", err)
	}
	for _, p := range []string{out, "../x.srs", `rules\..\..\x`} {
		if checkPaths(conf(p), base) == nil {
			t.Errorf("%s 应该被拒", p)
		}
	}
	deep := obj{"outbounds": []any{map[string]any{"tls": map[string]any{"certificate_path": out, "process_path": out}}}}
	if checkPaths(deep, base) == nil {
		t.Error("深处的 certificate_path 应该被检查到")
	}
	if err := checkPaths(obj{"route": obj{"rules": []any{map[string]any{"process_path": []any{out}}}}}, base); err != nil {
		t.Errorf("process_path 是匹配条件，不该当文件：%v", err)
	}
}

func TestVNewer(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{{"1.2.0", "1.1.9", true}, {"1.10.0", "1.9.0", true}, {"1.1.0", "1.1.0", false}, {"1.1", "1.1.0", false}, {"1.1.0", "0", true}} {
		if vnewer(c.a, c.b) != c.want {
			t.Errorf("vnewer(%s, %s) 应该是 %v", c.a, c.b, c.want)
		}
	}
}

func TestClassify(t *testing.T) {
	c := &Conf{Out: map[string]obj{
		"免流服务器":    {"type": "selector", "outbounds": []any{"港机 Hy2"}},
		"港机 Hy2":   {"type": "hysteria2", "server": "2001:db8::1"},
		"落地（经服务器）": {"type": "vless", "server": "1.2.3.4", "detour": "免流服务器"},
		"直连 v4":    {"type": "direct", "domain_resolver": obj{"strategy": "ipv4_only"}},
		"直连":       {"type": "direct"},
		"v6 节点":    {"type": "vless", "server": "240e::1"},
	}, EntryMembers: map[string]bool{"港机 Hy2": true}}
	conn := func(chain, dest string) obj {
		return obj{"chains": []any{chain}, "metadata": map[string]any{"destinationIP": dest}}
	}
	for _, x := range []struct {
		conn obj
		want kindKey
	}{
		{conn("落地（经服务器）", ""), kindKey{"server", "港机"}},
		{conn("免流服务器", ""), kindKey{"server", "港机"}},
		{conn("直连 v4", "1.1.1.1"), kindKey{kind: "v4"}},
		{conn("直连", "240e::1"), kindKey{kind: "v6"}},
		{conn("直连", "192.168.1.1"), kindKey{kind: "lan"}},
		{conn("直连", "198.18.0.5"), kindKey{kind: "lan"}},
		{conn("v6 节点", ""), kindKey{kind: "v6"}},
		{obj{"chains": []any{"直连"}, "metadata": map[string]any{"host": "ipgw.neu.edu.cn"}}, kindKey{kind: "lan"}},
	} {
		if got := classify(c, x.conn, nil); got != x.want {
			t.Errorf("classify(%v) = %v，应该是 %v", x.conn, got, x.want)
		}
	}
}

func TestTrafficSite(t *testing.T) {
	for _, c := range []struct{ host, ip, want string }{
		{"WWW.Example.COM.", "", "example.com"},
		{"video.example.co.uk", "", "example.co.uk"},
		{"a.foo.github.io", "", "foo.github.io"},
		{"www.中文.com", "", "xn--fiq228c.com"},
		{"", "192.0.2.10", "192.0.2.10"},
		{"[2001:db8::1]", "", "2001:db8::1"},
		{"::ffff:192.0.2.10", "", "192.0.2.10"},
		{"localhost", "192.0.2.11", "192.0.2.11"},
		{"https://example.com/private", "192.0.2.12", "192.0.2.12"},
		{"bad domain!", "", ""},
		{"", "", ""},
	} {
		if got := trafficSite(obj{"host": c.host, "destinationIP": c.ip}); got != c.want {
			t.Errorf("trafficSite(%q, %q) = %q，应该是 %q", c.host, c.ip, got, c.want)
		}
	}
}

func TestTrafficSitesUpgrade(t *testing.T) {
	h := &Helper{p: Paths{Var: t.TempDir()}}
	month := time.Now().Format("2006-01")
	old := trafficState{Since: "2025-01-01T00:00:00", Months: map[string]*bucket{month: {V6: 1000, Server: map[string]float64{"演示": 300}}}}
	if err := writeAtomic(h.p.Traffic(), marshal(old), 0o644); err != nil {
		t.Fatal(err)
	}
	tr := newTraffic(h)
	tr.addSites(month, map[string]map[string]float64{"v6": {"example.com": 100}})
	data, err := tr.sitesView("v6", month)
	if err != nil {
		t.Fatal(err)
	}
	var view struct {
		Total float64
		Items []siteItem
		Since string
	}
	if err := json.Unmarshal(data, &view); err != nil {
		t.Fatal(err)
	}
	if view.Total != 1000 || len(view.Items) != 1 || view.Items[0].Bytes != 100 || view.Since == "" {
		t.Fatalf("升级前总量和新增网站明细应分开保留：%s", data)
	}
	if bytes.Contains(tr.view(), []byte("example.com")) || bytes.Contains(tr.view(), []byte("sites")) {
		t.Fatal("公开的 /traffic 泄露了网站明细")
	}
	tr.save()
	if runtime.GOOS != "windows" {
		info, err := os.Stat(h.p.Traffic())
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("网站明细应为 600：%v", err)
		}
	}
	reloaded := newTraffic(h)
	if reloaded.state.SitesSince != tr.state.SitesSince || reloaded.state.Sites[month]["v6"]["example.com"] != 100 || reloaded.state.Since != old.Since {
		t.Fatal("重启后应保留原统计及网站明细")
	}
}

func TestTrafficSitesLimits(t *testing.T) {
	h := &Helper{p: Paths{Var: t.TempDir()}}
	tr := newTraffic(h)
	now := time.Now()
	month := now.Format("2006-01")
	sites := map[string]float64{}
	var total float64
	for i := 1; i <= 801; i++ {
		sites[fmt.Sprintf("s%d.example", i)] = float64(i)
		total += float64(i)
	}
	tr.addSites(month, map[string]map[string]float64{"server": sites})
	tr.state.Months[month] = &bucket{Server: map[string]float64{"演示一": total - 1, "演示二": 1}}
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
	old := first.AddDate(0, -3, 0).Format("2006-01")
	keep := first.AddDate(0, -2, 0).Format("2006-01")
	tr.addSites(old, map[string]map[string]float64{"v6": {"old.example": 1}})
	tr.addSites(keep, map[string]map[string]float64{"v6": {"keep.example": 1}})
	tr.trimSites(now)
	if len(tr.state.Sites[month]["server"]) != 401 || tr.state.Sites[old] != nil || tr.state.Sites[keep] == nil {
		t.Fatal("网站数量或保留月份不对")
	}
	var sum float64
	for _, n := range tr.state.Sites[month]["server"] {
		sum += n
	}
	if sum != total {
		t.Fatal("合并小网站丢失了流量")
	}
	data, err := tr.sitesView("server", month)
	if err != nil {
		t.Fatal(err)
	}
	var view struct {
		Items []siteItem
		Total float64
	}
	json.Unmarshal(data, &view)
	if len(view.Items) != 100 || view.Items[0].Bytes != 801 || view.Total != total {
		t.Fatalf("排名应为前 100，服务器合计应一致：%s", data)
	}
}

func TestTrafficSitesAuthorization(t *testing.T) {
	h := &Helper{p: Paths{Var: t.TempDir()}}
	c := &Conf{Secret: "test-only", Origins: map[string]bool{"http://127.0.0.1:29090": true}}
	h.cur.Store(c)
	h.traffic = newTraffic(h)
	for _, tc := range []struct {
		auth, origin, query string
		code                int
	}{
		{"", "", "kind=v6", 401},
		{"Bearer wrong", "", "kind=v6", 401},
		{"Bearer test-only", "https://example.com", "kind=v6", 401},
		{"Bearer test-only", "http://127.0.0.1:29090", "kind=v6", 200},
		{"Bearer test-only", "", "kind=other", 400},
		{"Bearer test-only", "", "kind=v4&month=2026-13", 400},
		{"Bearer test-only", "", "kind=server&month=2026-01", 200},
	} {
		r := httptest.NewRequest("GET", "/traffic/sites?"+tc.query, nil)
		r.Header.Set("Authorization", tc.auth)
		r.Header.Set("Origin", tc.origin)
		w := httptest.NewRecorder()
		h.handle(w, r)
		if w.Code != tc.code || w.Header().Get("Cache-Control") != "no-store" {
			t.Errorf("%+v：返回 %d", tc, w.Code)
		}
	}
	c.Secret = ""
	w := httptest.NewRecorder()
	h.handle(w, httptest.NewRequest("GET", "/traffic/sites?kind=v6", nil))
	if w.Code != 401 {
		t.Fatal("没有设置密钥时也不能公开网站明细")
	}
}

func TestIPv6Owner(t *testing.T) {
	ip := netip.MustParseAddr("2606:4700:4700::1111")
	query, err := ownerQuery(ip)
	if err != nil {
		t.Fatal(err)
	}
	other, _ := ownerQuery(netip.MustParseAddr("2606:4700:4700::abcd"))
	if query != other {
		t.Fatal("同一 /64 不应发送不同主机地址")
	}
	got, err := lookupOwner(context.Background(), ip, func(_ context.Context, name string) ([]string, error) {
		switch name {
		case query:
			return []string{"13335 | 2606:4700::/32 | US | arin | 2011-11-01"}, nil
		case "AS13335.asn.cymru.com":
			return []string{"13335 | US | arin | 2010-07-14 | CLOUDFLARENET - Cloudflare, Inc."}, nil
		default:
			t.Fatalf("意外查询：%s", name)
			return nil, nil
		}
	})
	if err != nil || got.ASN != "AS13335" || got.Provider != "CLOUDFLARENET - Cloudflare, Inc." {
		t.Fatalf("网络归属解析不对：%+v，%v", got, err)
	}
	for _, s := range []string{"::1", "fc00::1", "fe80::1", "2001:db8::1", "192.0.2.1", "::ffff:192.0.2.1"} {
		if _, err := ownerQuery(netip.MustParseAddr(s)); err == nil {
			t.Errorf("不应向外查询 %s", s)
		}
	}
	h := &Helper{}
	h.cur.Store(&Conf{Secret: "test-only", Origins: map[string]bool{"http://127.0.0.1:29090": true}})
	for _, tc := range []struct {
		token, origin, ip string
		code              int
	}{
		{"", "", ip.String(), 401},
		{"Bearer test-only", "https://example.com", ip.String(), 401},
		{"Bearer test-only", "", "::1", 400},
		{"Bearer test-only", "", "not-an-ip", 400},
	} {
		r := httptest.NewRequest("GET", "/ip/owner?ip="+tc.ip, nil)
		r.Header.Set("Authorization", tc.token)
		r.Header.Set("Origin", tc.origin)
		w := httptest.NewRecorder()
		h.handle(w, r)
		if w.Code != tc.code {
			t.Errorf("%+v：返回 %d", tc, w.Code)
		}
	}
}

func TestUnzipRejectsTraversal(t *testing.T) {
	var b bytes.Buffer
	w := zip.NewWriter(&b)
	f, _ := w.Create("pkg/../../evil")
	f.Write([]byte("x"))
	w.Close()
	if unzip(b.Bytes(), t.TempDir()) == nil {
		t.Error("带 .. 的路径应该被拒")
	}
	b.Reset()
	w = zip.NewWriter(&b)
	f, _ = w.Create("pkg/VERSION")
	f.Write([]byte("1.2.0\n"))
	w.Close()
	dir := t.TempDir()
	if err := unzip(b.Bytes(), dir); err != nil || !exists(filepath.Join(dir, "pkg", "VERSION")) {
		t.Errorf("正常的包解压失败：%v", err)
	}
}
