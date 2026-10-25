package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"
)

// ---------- 服务器连不上时自动改走「不用服务器」 ----------
// 当前网络连不上免流服务器（离开校园网、换了热点、服务器挂了）而网络本身是通的，就把「免流服务器」自动切到
// 「不用服务器」，经服务器的流量改为直连；每两分钟试一次，连上了自动切回。

const delayURL = "https://www.gstatic.com/generate_204"

var clashClient = &http.Client{Timeout: 12 * time.Second, Transport: &http.Transport{Proxy: nil}}

func (h *Helper) clash(method, path string, body any) (obj, error) {
	c := h.conf()
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(marshal(body))
	}
	req, err := http.NewRequest(method, c.API+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Secret)
	req.Header.Set("Content-Type", "application/json")
	resp, err := clashClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, bad("Clash API %s %s 返回 %d", method, path, resp.StatusCode)
	}
	var o obj
	if len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &o); err != nil {
			return nil, err
		}
	}
	return o, nil
}

func esc(s string) string { return url.PathEscape(s) }

func (h *Helper) entryNow() string {
	o, err := h.clash("GET", "/proxies/"+esc(entryName), nil)
	if err != nil {
		return ""
	}
	return getStr(o, "now")
}

// 经某个出口（服务器入口、自动选最快、或「免流服务器」当前的选择）能不能打开网页：sing-box 自己测，不经 TUN
func (h *Helper) reachableVia(name string) bool {
	o, err := h.clash("GET", "/proxies/"+esc(name)+"/delay?timeout=6000&url="+url.QueryEscape(delayURL), nil)
	return err == nil && getNum(o, "delay") > 0
}

func (h *Helper) setEntry(name string) error {
	_, err := h.clash("PUT", "/proxies/"+esc(entryName), obj{"name": name})
	return err
}

type Fallback struct {
	Previous string `json:"previous"`
	Since    string `json:"since"`
	Reason   string `json:"reason"`
}

func (h *Helper) fallback() *Fallback {
	var f Fallback
	if readJSON(h.p.Fallback(), &f) != nil {
		return nil
	}
	return &f
}

// 模式二才有「免流服务器」。quick：刚启动 / 更新 / 重新启用后立刻判断（连续 2 次连不上就切），平时要连续 3 次
func (h *Helper) serverCheck(quick bool) {
	h.serverChecked.Store(true)
	if h.conf().Out[entryName] == nil {
		return
	}
	now := h.entryNow()
	if now == "" {
		return
	}
	if fb := h.fallback(); fb != nil {
		if now != entryOff { // 用户自己在面板里改了选择：交还给用户
			os.Remove(h.p.Fallback())
			logf("「免流服务器」已被手动改选，不再自动切换")
			return
		}
		if time.Since(h.guardRetry) < 2*time.Minute {
			return
		}
		h.guardRetry = time.Now()
		if h.reachableVia(fb.Previous) {
			if h.guardOks++; h.guardOks >= 2 {
				if h.setEntry(fb.Previous) == nil {
					os.Remove(h.p.Fallback())
					logf("免流服务器又能连上了，已切回「%s」", fb.Previous)
				}
				h.guardOks = 0
			}
		} else {
			h.guardOks = 0
		}
		return
	}
	if now == entryOff { // 用户自己选的「不用服务器」
		h.guardFails = 0
		return
	}
	tries := 1
	if quick {
		tries = 2
	}
	for i := 0; i < tries; i++ {
		if h.reachableVia(entryName) {
			h.guardFails = 0
			return
		}
		if i+1 < tries {
			time.Sleep(4 * time.Second)
		}
	}
	if !directOK() { // 网络本身不通，不是服务器的问题
		h.guardFails = 0
		return
	}
	h.guardFails++
	logf("连不上免流服务器「%s」（第 %d 次）", now, h.guardFails)
	if quick || h.guardFails >= 3 {
		h.guardFails = 0
		if err := h.setEntry(entryOff); err != nil {
			logf("切到「%s」失败：%v", entryOff, err)
			return
		}
		reason := "当前网络连不上免流服务器（离开了校园网、换了网络，或服务器挂了）"
		_ = writeAtomic(h.p.Fallback(), marshal(Fallback{Previous: now, Since: stamp(), Reason: reason}), 0o644)
		logf("免流服务器连不上，已自动改走「%s」（原来是「%s」）：%s", entryOff, now, reason)
	}
}
