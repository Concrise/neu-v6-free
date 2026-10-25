package main

import (
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"golang.org/x/net/idna"
)

// 我的规则（/rules）：面板里加的规则写进 <规则目录>/user-<目标>.json，sing-box 发现文件变了会自动重新加载，
// 不用重新生成配置、不用重启。全部规则另存一份在 <规则目录>/user-rules.json（面板显示顺序、备注都在这里）。

var ruleTypes = []string{"domain_suffix", "domain", "domain_keyword", "ip_cidr", "process_name"}

type Rule struct {
	Type   string `json:"type"`
	Value  string `json:"value"`
	Target string `json:"target"`
	Note   string `json:"note"`
	Added  string `json:"added,omitempty"`
}

var (
	reScheme  = regexp.MustCompile(`^[a-z][a-z0-9+.-]*://`)
	rePort    = regexp.MustCompile(`:\d+$`)
	reKeyword = regexp.MustCompile(`^[a-z0-9._-]+$`)
	reDomain  = regexp.MustCompile(`^[a-z0-9-]+(\.[a-z0-9-]+)*$`)
)

// 把面板里粘贴的东西整理成 sing-box 能用的值；不合法就报错（消息直接显示给用户）
func normalizeRule(kind, value string) (string, error) {
	v := strings.TrimSpace(value)
	known := false
	for _, t := range ruleTypes {
		known = known || t == kind
	}
	if !known {
		return "", bad("不支持的类型：%s", kind)
	}
	if v == "" {
		return "", bad("内容是空的")
	}
	switch kind {
	case "ip_cidr":
		// 和以前一样：单个地址补成 /32、/128，网段把主机位清零
		if strings.Contains(v, "/") {
			p, err := netip.ParsePrefix(v)
			if err != nil {
				return "", bad("不是 IP 或网段：%s", v)
			}
			return p.Masked().String(), nil
		}
		a, err := netip.ParseAddr(v)
		if err != nil || a.Zone() != "" {
			return "", bad("不是 IP 或网段：%s", v)
		}
		return netip.PrefixFrom(a, a.BitLen()).String(), nil
	case "process_name":
		if strings.ContainsAny(v, `/\`) || len([]rune(v)) > 128 {
			return "", bad("进程名只写名字，不要带路径，例如 chrome.exe 或 WeChat")
		}
		return v, nil
	}
	v = strings.ToLower(v)
	v = reScheme.ReplaceAllString(v, "") // 粘贴了整个网址：去掉协议、路径、端口
	if i := strings.IndexAny(v, "/?#"); i >= 0 {
		v = v[:i]
	}
	v = strings.TrimRight(strings.TrimLeft(rePort.ReplaceAllString(v, ""), "*."), ".")
	if kind == "domain_keyword" {
		if !reKeyword.MatchString(v) {
			return "", bad("关键词只能有字母、数字和 . _ -：%s", v)
		}
		return v, nil
	}
	a, err := idna.ToASCII(v) // 中文域名转成 xn-- 形式
	if err != nil || !reDomain.MatchString(a) {
		return "", bad("不是域名：%s", v)
	}
	return a, nil
}

func (h *Helper) rulesFile(c *Conf) string { return filepath.Join(c.RulesDir, "user-rules.json") }

func (h *Helper) loadRules(c *Conf) []Rule {
	var f struct {
		Rules []Rule `json:"rules"`
	}
	if readJSON(h.rulesFile(c), &f) == nil {
		return f.Rules
	}
	// 第一次运行：把规则文件里已有的内容（手动写的）收进来
	var rules []Rule
	for _, t := range c.Targets {
		var rs struct {
			Rules []map[string]any `json:"rules"`
		}
		if readJSON(t.Path, &rs) != nil {
			continue
		}
		for _, r := range rs.Rules {
			for _, k := range ruleTypes {
				vals, _ := r[k].([]any)
				for _, v := range vals {
					if s, ok := v.(string); ok {
						rules = append(rules, Rule{Type: k, Value: s, Target: t.ID})
					}
				}
			}
		}
	}
	return rules
}

// 全部规则 → user-rules.json + 每个目标一个 sing-box 规则集；内容没变的文件不动，免得白白重新加载
func (h *Helper) applyRules(c *Conf, rules []Rule) error {
	if len(c.Targets) == 0 {
		return nil
	}
	if rules == nil {
		rules = []Rule{}
	}
	if err := writeAtomic(h.rulesFile(c), append(marshalIndent(obj{"version": 1, "rules": rules}), '\n'), 0o644); err != nil {
		return err
	}
	for _, t := range c.Targets {
		dest := map[string][]string{}
		var procs []string
		for _, r := range rules {
			if r.Target != t.ID {
				continue
			}
			if r.Type == "process_name" {
				procs = append(procs, r.Value)
			} else {
				dest[r.Type] = append(dest[r.Type], r.Value)
			}
		}
		// 同一条规则里的域名与 IP 是「或」，进程名和它们是「且」，所以进程名单独一条
		list := []any{}
		if len(dest) > 0 {
			list = append(list, dest)
		}
		if len(procs) > 0 {
			list = append(list, obj{"process_name": procs})
		}
		body := marshal(obj{"version": 2, "rules": list})
		if old, err := os.ReadFile(t.Path); err == nil && sameJSON(old, body) {
			continue
		}
		if err := writeAtomic(t.Path, append(body, '\n'), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func sameJSON(a, b []byte) bool {
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	return string(marshal(x)) == string(marshal(y))
}

func marshalIndent(v any) []byte {
	var x any
	_ = json.Unmarshal(marshal(v), &x)
	b, _ := json.MarshalIndent(x, "", " ")
	return b
}

func rulesView(c *Conf, rules []Rule) obj {
	targets := []obj{}
	for _, t := range c.Targets {
		var name any
		if t.Name != "" {
			name = t.Name
		}
		targets = append(targets, obj{"id": t.ID, "name": name})
	}
	list := []obj{}
	for _, r := range rules {
		o := obj{"type": r.Type, "value": r.Value, "target": r.Target, "note": r.Note, "orphan": c.target(r.Target) == nil}
		if r.Added != "" {
			o["added"] = r.Added
		}
		list = append(list, o)
	}
	return obj{"targets": targets, "rules": list, "dir": c.RulesDir}
}

func cut200(s string) string {
	r := []rune(s)
	if len(r) > 200 {
		return string(r[:200])
	}
	return s
}

func (h *Helper) rulesChange(op string, body obj) (obj, error) {
	h.rulesMu.Lock()
	defer h.rulesMu.Unlock()
	c := h.conf()
	rules := h.loadRules(c)
	without := func(list []Rule, kind, value string) []Rule {
		out := list[:0:0]
		for _, r := range list {
			if !(r.Type == kind && r.Value == value) {
				out = append(out, r)
			}
		}
		return out
	}
	switch op {
	case "add":
		kind := getStr(body, "type")
		value, err := normalizeRule(kind, getStr(body, "value"))
		if err != nil {
			return nil, err
		}
		target := getStr(body, "target")
		if c.target(target) == nil {
			return nil, bad("没有这个目标：%s", target)
		}
		// 同一个值只能有一个去处：先删掉旧的
		rules = append(without(rules, kind, value), Rule{Type: kind, Value: value, Target: target, Note: cut200(getStr(body, "note")), Added: stamp()})
	case "delete":
		rules = without(rules, getStr(body, "type"), getStr(body, "value"))
	case "replace":
		var list []Rule
		for i, x := range getList(body, "rules") {
			r, _ := x.(map[string]any)
			value, err := normalizeRule(getStr(r, "type"), getStr(r, "value"))
			if err != nil {
				return nil, bad("第 %d 条：%s", i+1, err.Error())
			}
			if c.target(getStr(r, "target")) == nil {
				return nil, bad("第 %d 条：没有这个目标：%s", i+1, getStr(r, "target"))
			}
			added := getStr(r, "added")
			if added == "" {
				added = stamp()
			}
			list = append(without(list, getStr(r, "type"), value),
				Rule{Type: getStr(r, "type"), Value: value, Target: getStr(r, "target"), Note: cut200(getStr(r, "note")), Added: added})
		}
		rules = list
	}
	if err := h.applyRules(c, rules); err != nil {
		return nil, err
	}
	return rulesView(c, rules), nil
}
