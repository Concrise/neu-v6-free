package main

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"time"
)

// ---------- 断网保护的探测 ----------
// 经 sing-box 的探测：访问域名（走 TUN、sing-box 的 DNS 与分流）。
// 绕过 sing-box 的探测：绑定物理网卡访问 IP（不经 DNS）。校园网 IPv4 拦了公共 DNS 的地址，所以绕过探测
// 同时用 IPv6 和几个 IPv4 网站地址，任意一个有响应就算「网络本身是通的」。
// 几个地址同时探测，有一个通就算通（以前是一个一个试，最慢要十几秒）。

var (
	tunProbes     = []string{"https://www.taobao.com", "https://www.baidu.com", "https://www.qq.com"}
	directProbes6 = []string{"http://[2400:3200::1]/", "http://[2402:4e00::]/"}
	directProbes4 = []string{"http://220.181.111.1/", "http://110.242.68.66/"}
)

// 本机服务（Clash API、本地助手）：不走任何代理
var localClient = &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}}

// 有任何 HTTP 响应就算通（不管状态码、不跟随跳转、不验证证书：只看网络通不通）
func responds(ctx context.Context, url string, d *net.Dialer) bool {
	if d == nil {
		d = &net.Dialer{}
	}
	c := &http.Client{
		Timeout: 6 * time.Second,
		Transport: &http.Transport{
			Proxy: nil, DialContext: d.DialContext, DisableKeepAlives: true,
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	req, err := http.NewRequestWithContext(ctx, "HEAD", url, nil)
	if err != nil {
		return false
	}
	resp, err := c.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

type probe struct {
	url string
	d   *net.Dialer
}

// 同时探测，有一个通就返回 true
func anyResponds(probes []probe) bool {
	if len(probes) == 0 {
		return false
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ok := make(chan bool, len(probes))
	for _, p := range probes {
		go func() { ok <- responds(ctx, p.url, p.d) }()
	}
	for range probes {
		if <-ok {
			return true
		}
	}
	return false
}

func tunOK() bool {
	var ps []probe
	for _, u := range tunProbes {
		ps = append(ps, probe{url: u})
	}
	return anyResponds(ps)
}

// 绕过 sing-box，网络本身通不通
func directOK() bool {
	v6, v4 := physicalDialers()
	var ps []probe
	for _, d := range v6 {
		for _, u := range directProbes6 {
			ps = append(ps, probe{u, d})
		}
	}
	for _, d := range v4 {
		for _, u := range directProbes4 {
			ps = append(ps, probe{u, d})
		}
	}
	return anyResponds(ps)
}

// ok：经 sing-box 能上网；broken：经 sing-box 不通、绕过它能通（sing-box 的问题）；offline：网络本身不通
func netState() string {
	if tunOK() {
		return "ok"
	}
	if directOK() {
		return "broken"
	}
	return "offline"
}
