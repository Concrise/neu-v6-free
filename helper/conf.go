package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// 与 lib/groups.js 一致
const (
	entryName = "免流服务器"
	entryOff  = "不用服务器（离校时选）"
)

var groupTypes = map[string]bool{"selector": true, "urltest": true}

// Target：「我的规则」的一个目标（规则集 user-<id> 和引用它的路由规则的出口）
type Target struct {
	ID   string
	Path string
	Name string // 出口名；拒绝时是「拒绝」
}

// Conf：从正在用的 sing-box 配置里读出助手要用的东西
type Conf struct {
	Raw          obj
	API          string // http://127.0.0.1:9090
	Secret       string
	Origins      map[string]bool // 面板页面的来源：只认它发来的网页请求
	Out          map[string]obj  // 出站 tag → 出站
	EntryMembers map[string]bool // 「免流服务器」里的服务器入口
	Targets      []Target
	RulesDir     string
	TunName      string
	UI           string // 面板目录（external_ui）
}

func loadConf(path string) (*Conf, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw obj
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	c := &Conf{Raw: raw, Out: map[string]obj{}, EntryMembers: map[string]bool{}}
	clash := getObj(getObj(raw, "experimental"), "clash_api")
	c.API = "http://" + getStr(clash, "external_controller")
	c.Secret = getStr(clash, "secret")
	c.UI = getStr(clash, "external_ui")
	c.Origins = map[string]bool{c.API: true, strings.Replace(c.API, "127.0.0.1", "localhost", 1): true}
	for _, o := range getList(raw, "outbounds") {
		if m, ok := o.(map[string]any); ok {
			c.Out[getStr(m, "tag")] = m
		}
	}
	if e := c.Out[entryName]; e != nil {
		for _, t := range getList(e, "outbounds") {
			tag, _ := t.(string)
			o := c.Out[tag]
			if o != nil && !groupTypes[getStr(o, "type")] && getStr(o, "type") != "direct" {
				c.EntryMembers[tag] = true
			}
		}
	}
	route := getObj(raw, "route")
	byID := map[string]int{}
	for _, rs := range getList(route, "rule_set") {
		m, _ := rs.(map[string]any)
		tag := getStr(m, "tag")
		if strings.HasPrefix(tag, "user-") && getStr(m, "type") == "local" {
			byID[tag[5:]] = len(c.Targets)
			c.Targets = append(c.Targets, Target{ID: tag[5:], Path: getStr(m, "path")})
		}
	}
	for _, r := range getList(route, "rules") {
		m, _ := r.(map[string]any)
		sets := getList(m, "rule_set")
		if len(sets) != 1 {
			continue
		}
		s, _ := sets[0].(string)
		if i, ok := byID[strings.TrimPrefix(s, "user-")]; ok && strings.HasPrefix(s, "user-") {
			if out := getStr(m, "outbound"); out != "" {
				c.Targets[i].Name = out
			} else if getStr(m, "action") == "reject" {
				c.Targets[i].Name = "拒绝"
			}
		}
	}
	if len(c.Targets) > 0 {
		c.RulesDir = filepath.Dir(c.Targets[0].Path)
	}
	for _, in := range getList(raw, "inbounds") {
		m, _ := in.(map[string]any)
		if getStr(m, "type") == "tun" {
			c.TunName = getStr(m, "interface_name")
			if c.TunName == "" {
				c.TunName = "neu-v6" // lib/build.js 里 windows 固定用这个名字
			}
		}
	}
	return c, nil
}

func (c *Conf) target(id string) *Target {
	for i := range c.Targets {
		if c.Targets[i].ID == id {
			return &c.Targets[i]
		}
	}
	return nil
}

// 配置里监听的端口（安装前检查有没有被别的代理软件占着）
func listenPorts(raw obj) []int {
	var ports []int
	for _, in := range getList(raw, "inbounds") {
		m, _ := in.(map[string]any)
		if p := int(getNum(m, "listen_port")); p > 0 {
			ports = append(ports, p)
		}
	}
	ctl := getStr(getObj(getObj(raw, "experimental"), "clash_api"), "external_controller")
	if i := strings.LastIndex(ctl, ":"); i >= 0 {
		if p, err := strconv.Atoi(ctl[i+1:]); err == nil && p > 0 {
			ports = append(ports, p)
		}
	}
	return ports
}

// ---------- 配置里的文件路径 ----------
// sing-box 以 root / SYSTEM 运行：配置里指向本机文件的字段必须在安装目录内，否则一份配置就能让它往系统任意位置写文件

var fileKey = regexp.MustCompile(`_path$`) // certificate_path、key_path 等；process_path 是匹配条件，不是文件

func filePaths(raw obj) [][2]string {
	var found [][2]string
	add := func(k, v string) {
		if v != "" {
			found = append(found, [2]string{k, v})
		}
	}
	exp := getObj(raw, "experimental")
	add("log.output", getStr(getObj(raw, "log"), "output"))
	add("cache_file.path", getStr(getObj(exp, "cache_file"), "path"))
	add("clash_api.external_ui", getStr(getObj(exp, "clash_api"), "external_ui"))
	for _, rs := range getList(getObj(raw, "route"), "rule_set") {
		m, _ := rs.(map[string]any)
		add("rule_set.path", getStr(m, "path"))
	}
	var walk func(any)
	walk = func(n any) {
		switch v := n.(type) {
		case map[string]any:
			for k, x := range v {
				if s, ok := x.(string); ok && fileKey.MatchString(k) && !strings.HasPrefix(k, "process_path") {
					add(k, s)
				} else {
					walk(x)
				}
			}
		case []any:
			for _, x := range v {
				walk(x)
			}
		}
	}
	walk(raw)
	return found
}

// 绝对路径必须在 base（安装目录）内，相对路径（相对 sing-box 的工作目录）不能有 ..
func checkPaths(raw obj, base string) error {
	base = filepath.Clean(base)
	for _, kv := range filePaths(raw) {
		k, v := kv[0], kv[1]
		if isAbs(v) {
			full := cleanAbs(v)
			if !pathEqual(full, base) && !pathHasPrefix(full, base+string(filepath.Separator)) {
				return bad("配置里的 %s 指向安装目录（%s）以外：%s", k, base, v)
			}
		} else {
			for _, part := range strings.Split(strings.ReplaceAll(v, `\`, "/"), "/") {
				if part == ".." {
					return bad("配置里的 %s 不能包含 ..：%s", k, v)
				}
			}
		}
	}
	return nil
}
