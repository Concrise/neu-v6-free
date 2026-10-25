package main

import (
	"encoding/json"
	"net/http"
	"net/netip"
	"sort"
	"strings"
	"sync"
	"time"
)

// 流量统计（/traffic）：每秒读一次 Clash API 的 /connections，按每条连接的实际出口记账：
//
//	v6     校园网 IPv6 直连（免费）
//	server 经免流服务器出去（免费；上下行之和 ≈ 该服务器的出站流量），按服务器分开
//	v4     校园网 IPv4 直连（计费）
//	lan    局域网 / 校园网内（不计费）
//	other  直连但看不出走 v4 还是 v6
//
// 连接在两次采样之间关闭时丢掉的尾巴，用 sing-box 的总流量补齐，按本次各类占比分摊。
// 结果每 30 秒存一次 traffic.json（格式和以前的助手相同，升级后接着记）。

type bucket struct {
	V6     float64            `json:"v6"`
	Server map[string]float64 `json:"server"`
	V4     float64            `json:"v4"`
	Lan    float64            `json:"lan"`
	Other  float64            `json:"other"`
}

func newBucket() *bucket { return &bucket{Server: map[string]float64{}} }

func (b *bucket) add(k kindKey, n float64) {
	switch k.kind {
	case "server":
		b.Server[k.srv] += n
	case "v6":
		b.V6 += n
	case "v4":
		b.V4 += n
	case "lan":
		b.Lan += n
	default:
		b.Other += n
	}
}

type kindKey struct{ kind, srv string }

type trafficState struct {
	Since  string             `json:"since"`
	Months map[string]*bucket `json:"months"`
	Days   map[string]*bucket `json:"days"`
}

type Traffic struct {
	h     *Helper
	mu    sync.Mutex
	state trafficState
	live  obj
}

func newTraffic(h *Helper) *Traffic {
	t := &Traffic{h: h, live: obj{"rate": newBucket(), "updated": nil, "ok": false}}
	_ = readJSON(h.p.Traffic(), &t.state)
	if t.state.Since == "" {
		t.state.Since = stamp()
	}
	if t.state.Months == nil {
		t.state.Months = map[string]*bucket{}
	}
	if t.state.Days == nil {
		t.state.Days = map[string]*bucket{}
	}
	for _, m := range []map[string]*bucket{t.state.Months, t.state.Days} {
		for k, b := range m {
			if b == nil {
				m[k] = newBucket()
			} else if b.Server == nil {
				b.Server = map[string]float64{}
			}
		}
	}
	return t
}

// /traffic 的内容：since、months、days，加上 live（当前速率）
func (t *Traffic) view() []byte {
	t.mu.Lock()
	defer t.mu.Unlock()
	return marshal(obj{"since": t.state.Since, "months": t.state.Months, "days": t.state.Days, "live": t.live})
}

func (t *Traffic) save() {
	t.mu.Lock()
	data := marshal(t.state)
	t.mu.Unlock()
	if err := writeAtomic(t.h.p.Traffic(), data, 0o644); err != nil {
		logf("保存流量统计失败：%v", err)
	}
}

// 出口 tag → kindKey{"server", 服务器名} / {"v6"} / {"v4"} / {"direct", 解析策略} / {"other"}
func resolveOut(c *Conf, tag string, now map[string]string, depth int) kindKey {
	o := c.Out[tag]
	if o == nil || depth > 8 {
		return kindKey{kind: "other"}
	}
	t := getStr(o, "type")
	if groupTypes[t] {
		sel := now[tag]
		if sel == "" {
			sel = getStr(o, "default")
		}
		if sel == "" {
			if l := getList(o, "outbounds"); len(l) > 0 {
				sel, _ = l[0].(string)
			}
		}
		return resolveOut(c, sel, now, depth+1)
	}
	if t == "direct" {
		return kindKey{kind: "direct", srv: getStr(getObj(o, "domain_resolver"), "strategy")}
	}
	if c.EntryMembers[tag] {
		name := tag
		if i := strings.LastIndex(tag, " "); i > 0 {
			name = tag[:i] // 入口名「<服务器名> <协议>」→ 服务器名
		}
		return kindKey{kind: "server", srv: name}
	}
	if d := getStr(o, "detour"); d != "" {
		if r := resolveOut(c, d, now, depth+1); r.kind == "server" {
			return r
		}
	}
	if a, err := netip.ParseAddr(getStr(o, "server")); err == nil && a.Is6() && !a.Is4In6() {
		return kindKey{kind: "v6"}
	}
	return kindKey{kind: "v4"}
}

func classify(c *Conf, conn obj, now map[string]string) kindKey {
	chains := getList(conn, "chains")
	r := kindKey{kind: "other"}
	if len(chains) > 0 {
		if s, _ := chains[0].(string); s != "" {
			r = resolveOut(c, s, now, 0)
		}
	}
	if r.kind != "direct" {
		return r
	}
	switch r.srv {
	case "ipv6_only", "prefer_ipv6":
		return kindKey{kind: "v6"}
	case "ipv4_only":
		return kindKey{kind: "v4"}
	}
	m := getObj(conn, "metadata")
	host := strings.ToLower(getStr(m, "host"))
	if host == "neu.edu.cn" || strings.HasSuffix(host, ".neu.edu.cn") {
		return kindKey{kind: "lan"}
	}
	ip, err := netip.ParseAddr(getStr(m, "destinationIP"))
	if err != nil {
		return kindKey{kind: "other"}
	}
	ip = ip.Unmap()
	if ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsMulticast() || ip.IsUnspecified() || inLan(ip) {
		return kindKey{kind: "lan"}
	}
	if ip.Is6() {
		return kindKey{kind: "v6"}
	}
	return kindKey{kind: "v4"}
}

func (t *Traffic) api(c *Conf, path string) (obj, error) {
	req, _ := http.NewRequest("GET", c.API+path, nil)
	req.Header.Set("Authorization", "Bearer "+c.Secret)
	resp, err := localClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var o obj
	dec := json.NewDecoder(resp.Body)
	dec.UseNumber()
	if err := dec.Decode(&o); err != nil {
		return nil, err
	}
	return o, nil
}

func (t *Traffic) run() {
	var last map[string]float64
	var lastTotal float64 = -1
	var lastT time.Time
	now := map[string]string{}
	mix := map[kindKey]float64{}
	tick, lastSave := 0, time.Now()
	var conf *Conf
	for {
		t0 := time.Now()
		func() {
			c := t.h.conf()
			if c != conf { // /apply 装了新配置：出口变了，重新取基线
				conf, last, lastTotal = c, nil, -1
			}
			fail := func(err error) {
				last, lastTotal, lastT = nil, -1, time.Time{}
				t.mu.Lock()
				t.live = obj{"rate": t.live["rate"], "updated": t.live["updated"], "ok": false, "error": cutErr(err)}
				t.mu.Unlock()
			}
			if tick%5 == 0 {
				p, err := t.api(c, "/proxies")
				if err != nil {
					fail(err)
					return
				}
				now = map[string]string{}
				for k, v := range getObj(p, "proxies") {
					if m, ok := v.(map[string]any); ok && getStr(m, "now") != "" {
						now[k] = getStr(m, "now")
					}
				}
			}
			d, err := t.api(c, "/connections")
			if err != nil {
				fail(err)
				return
			}
			total := getNum(d, "downloadTotal") + getNum(d, "uploadTotal")
			cur := map[string]float64{}
			deltas := map[kindKey]float64{}
			for _, x := range getList(d, "connections") {
				conn, _ := x.(map[string]any)
				n := getNum(conn, "upload") + getNum(conn, "download")
				id := getStr(conn, "id")
				cur[id] = n
				if last == nil {
					continue // 刚启动：已有连接只取基线，不重复记
				}
				delta := n - last[id]
				if delta < 0 {
					delta = n
				}
				if delta > 0 {
					deltas[classify(c, conn, now)] += delta
				}
			}
			if lastTotal >= 0 && total >= lastTotal {
				var sum float64
				for _, v := range deltas {
					sum += v
				}
				rest := (total - lastTotal) - sum
				base := deltas
				if len(base) == 0 {
					base = mix
				}
				if rest > 0 && len(base) > 0 {
					var s float64
					for _, v := range base {
						s += v
					}
					for k, v := range base {
						deltas[k] += float64(int64(rest * v / s))
					}
				}
			}
			if len(deltas) > 0 {
				mix = map[kindKey]float64{}
				for k, v := range deltas {
					mix[k] = v
				}
			}
			dt := 1.0
			if !lastT.IsZero() {
				dt = max(time.Since(lastT).Seconds(), 0.5)
			}
			rate := newBucket()
			st := time.Now()
			mk, dk := st.Format("2006-01"), st.Format("2006-01-02")
			t.mu.Lock()
			mb, db := t.state.Months[mk], t.state.Days[dk]
			if mb == nil {
				mb = newBucket()
				t.state.Months[mk] = mb
			}
			if db == nil {
				db = newBucket()
				t.state.Days[dk] = db
			}
			for k, n := range deltas {
				mb.add(k, n)
				db.add(k, n)
				rate.add(k, n/dt)
			}
			if len(t.state.Days) > 62 {
				keys := make([]string, 0, len(t.state.Days))
				for k := range t.state.Days {
					keys = append(keys, k)
				}
				sort.Strings(keys)
				for _, k := range keys[:len(keys)-62] {
					delete(t.state.Days, k)
				}
			}
			t.live = obj{"rate": rate, "updated": st.Format("2006-01-02T15:04:05"), "ok": true}
			t.mu.Unlock()
			lastT, last, lastTotal = time.Now(), cur, total
		}()
		tick++
		if time.Since(lastSave) > 30*time.Second {
			t.save()
			lastSave = time.Now()
		}
		time.Sleep(max(time.Second-time.Since(t0), 100*time.Millisecond))
	}
}

// 另外几段不出校园网的地址：0.0.0.0/8、198.18.0.0/15（sing-box 的 fakeip）、240.0.0.0/4、文档用的 2001:db8::/32
var lanPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("240.0.0.0/4"), netip.MustParsePrefix("2001:db8::/32"),
}

func inLan(ip netip.Addr) bool {
	for _, p := range lanPrefixes {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}

func cutErr(err error) string {
	s := err.Error()
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}
