package main

import (
	"archive/zip"
	"bytes"
	"path/filepath"
	"runtime"
	"testing"
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
