package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
)

// 只监听 127.0.0.1。/rules、/profile、/fetch、/apply、/update 都要带和 Clash API 相同的密钥；
// 浏览器里别的网站也能向 127.0.0.1 发请求，所以网页发来的请求只认面板页面（暂停 / 重新启用还认助手自己的状态页）。

func (h *Helper) serve(ln net.Listener) {
	srv := &http.Server{Handler: http.HandlerFunc(h.handle)}
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		logf("本地助手的 HTTP 服务停了：%v", err)
	}
}

func (h *Helper) reply(w http.ResponseWriter, r *http.Request, code int, v any) {
	var body []byte
	if b, ok := v.([]byte); ok {
		body = b
	} else {
		body = marshal(v)
	}
	h.cors(w, r)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	w.Write(body)
}

func (h *Helper) cors(w http.ResponseWriter, r *http.Request) {
	if o := r.Header.Get("Origin"); h.conf().Origins[o] { // 状态页和助手同源，不需要跨域头
		w.Header().Set("Access-Control-Allow-Origin", o)
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT")
	}
}

// 网页发来的请求只认面板页面（ownPage：还认助手自己的状态页），并且要带密钥
func (h *Helper) authorized(r *http.Request, ownPage bool) bool {
	c := h.conf()
	if o := r.Header.Get("Origin"); o != "" && !c.Origins[o] {
		own := ownPage && (o == fmt.Sprintf("http://127.0.0.1:%d", h.port) || o == fmt.Sprintf("http://localhost:%d", h.port))
		if !own {
			return false
		}
	}
	return c.Secret == "" || r.Header.Get("Authorization") == "Bearer "+c.Secret
}

func readBody(r *http.Request, limit int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, bad("内容太大")
	}
	return b, nil
}

func readObj(r *http.Request, limit int64) (obj, error) {
	b, err := readBody(r, limit)
	if err != nil {
		return nil, err
	}
	var o obj
	if len(strings.TrimSpace(string(b))) == 0 {
		return obj{}, nil
	}
	if json.Unmarshal(b, &o) != nil || o == nil {
		return nil, bad("请求格式不对")
	}
	return o, nil
}

// 出错时：说给用户听的错误回 400，其他回 500
func (h *Helper) fail(w http.ResponseWriter, r *http.Request, err error, prefix string) {
	if isUserError(err) {
		h.reply(w, r, 400, obj{"error": err.Error()})
	} else {
		h.reply(w, r, 500, obj{"error": prefix + err.Error()})
	}
}

func (h *Helper) handle(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if e := recover(); e != nil {
			logf("处理 %s %s 出错：%v", r.Method, r.URL.Path, e)
			h.reply(w, r, 500, obj{"error": fmt.Sprintf("出错了：%v", e)})
		}
	}()
	path, m := r.URL.Path, r.Method
	if m == "OPTIONS" {
		h.cors(w, r)
		w.WriteHeader(204)
		return
	}
	c := h.conf()
	switch {
	case path == "/health" && m == "GET":
		running := h.sb.running()
		var safe, fb any
		if s := h.safeMode(); s != nil {
			safe = s
		}
		if f := h.fallback(); f != nil {
			fb = f
		}
		uv := h.updateView()
		h.reply(w, r, 200, obj{"ok": true, "rules": len(c.Targets) > 0, "traffic": true, "apply": true, "client": true,
			"singbox": running, "tun": running && tunUp(c.TunName), "safe_mode": safe, "server_fallback": fb,
			"server_checked": h.serverChecked.Load(), "version": h.currentVersion(), "helper": version,
			"update": obj{"latest": uv["latest"], "available": uv["available"]}})

	case path == "/" && m == "GET":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, statusPage)

	case path == "/traffic" && m == "GET":
		h.reply(w, r, 200, h.traffic.view())

	case (path == "/pause" || path == "/resume") && m == "POST":
		if !h.authorized(r, true) {
			h.reply(w, r, 401, obj{"error": "密钥不对"})
			return
		}
		if path == "/pause" {
			body, _ := readObj(r, 1<<16)
			reason := getStr(body, "reason")
			if reason == "" {
				reason = "手动暂停"
			}
			h.pause(reason)
			h.reply(w, r, 200, obj{"ok": true})
			return
		}
		res, err := h.resume()
		if err != nil {
			h.fail(w, r, err, "")
			return
		}
		h.reply(w, r, 200, res)

	case strings.HasPrefix(path, "/rules"):
		if !h.authorized(r, false) {
			h.reply(w, r, 401, obj{"error": "密钥不对"})
			return
		}
		if len(c.Targets) == 0 {
			h.reply(w, r, 404, obj{"error": "这份配置没有开「我的规则」（user_rules: false）"})
			return
		}
		if path == "/rules" && m == "GET" {
			h.rulesMu.Lock()
			v := rulesView(c, h.loadRules(c))
			h.rulesMu.Unlock()
			h.reply(w, r, 200, v)
			return
		}
		op := map[string]string{"POST /rules": "add", "POST /rules/delete": "delete", "PUT /rules": "replace"}[m+" "+path]
		if op == "" {
			h.reply(w, r, 404, obj{"error": "not found"})
			return
		}
		body, err := readObj(r, 1<<20)
		if err != nil {
			h.fail(w, r, err, "")
			return
		}
		v, err := h.rulesChange(op, body)
		if err != nil {
			h.fail(w, r, err, "保存失败：")
			return
		}
		h.reply(w, r, 200, v)

	case path == "/apply" && m == "POST" && r.Header.Get("Origin") == "":
		// 本机命令（neu-v6-free apply）：交来生成目录的路径；必须有密钥
		if c.Secret == "" || r.Header.Get("Authorization") != "Bearer "+c.Secret {
			h.reply(w, r, 401, obj{"error": "密钥不对"})
			return
		}
		body, err := readObj(r, 1<<16)
		if err == nil {
			var res obj
			if res, err = h.applyDir(getStr(body, "src")); err == nil {
				h.reply(w, r, 200, res)
				return
			}
		}
		h.fail(w, r, err, "更新失败：")

	case path == "/profile" || path == "/fetch" || path == "/apply" || strings.HasPrefix(path, "/update"):
		// 面板的客户端功能（设置、订阅、安装面板生成的配置、更新）：只认面板页面 + 密钥
		if c.Secret == "" || !h.authorized(r, false) {
			h.reply(w, r, 401, obj{"error": "密钥不对"})
			return
		}
		h.client(w, r)

	default:
		h.reply(w, r, 404, obj{"error": "not found"})
	}
}

func (h *Helper) client(w http.ResponseWriter, r *http.Request) {
	path, m := r.URL.Path, r.Method
	var res any
	var err error
	switch m + " " + path {
	case "GET /profile":
		res = h.profileView()
	case "PUT /profile":
		var b []byte
		if b, err = readBody(r, maxBody); err == nil {
			if err = h.saveProfile(b); err == nil {
				res = obj{"ok": true}
			}
		}
	case "GET /update":
		h.upd.mu.Lock()
		checked := h.upd.checked != ""
		h.upd.mu.Unlock()
		if checked {
			res = h.updateView()
		} else {
			res = h.checkUpdate()
		}
	case "POST /update/check":
		res = h.checkUpdate()
	case "POST /update/install":
		res, err = h.installUpdate()
	case "POST /fetch":
		var body obj
		if body, err = readObj(r, maxBody); err == nil {
			res, err = fetchSubscription(getStr(body, "url"))
		}
	case "POST /apply":
		var body obj
		if body, err = readObj(r, maxBody); err == nil {
			res, err = h.applyInline(body)
		}
	default:
		h.reply(w, r, 404, obj{"error": "not found"})
		return
	}
	if err != nil {
		h.fail(w, r, err, "出错了：")
		return
	}
	h.reply(w, r, 200, res)
}

// sing-box 停掉时面板（由 sing-box 提供）打不开，助手自己给一个最简单的状态页
const statusPage = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>校园网 v6 免流 · 状态</title><style>:root{color-scheme:light dark;--bg:#f5f6f8;--text:#1c2027;--line:#e1e4ea;--ok:#157f3b;--warn:#b45309;--accent:#2457d6;--muted:#646b78}
@media (prefers-color-scheme:dark){:root{--bg:#14161b;--text:#e7e9ee;--line:#2c303a;--ok:#5fd38a;--warn:#f2b35c;--accent:#7aa2ff;--muted:#a0a6b2}}
body{font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;max-width:620px;margin:40px auto;padding:0 16px;color:var(--text);background:var(--bg)}a{color:var(--accent)}
.card{border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:12px 0}.ok{color:var(--ok)}.warn{color:var(--warn)}button{padding:6px 14px;border-radius:8px;border:1px solid #2457d6;background:#2457d6;color:#fff;cursor:pointer}
input{padding:6px 10px;border:1px solid var(--line);border-radius:8px}.muted{color:var(--muted);font-size:13px}</style></head><body>
<h2>校园网 v6 免流 · 状态</h2><div class="card" id="st">读取中……</div>
<div class="card"><input type="password" id="sec" placeholder="面板密钥"> <button id="go"></button><p class="muted" id="msg"></p></div>
<p class="muted">面板：<a href="http://127.0.0.1:9090/ui">http://127.0.0.1:9090/ui</a>（sing-box 运行时才能打开）</p>
<script>
const $=(i)=>document.getElementById(i);let h=null;try{$("sec").value=localStorage.getItem("neu-secret")||""}catch{}
async function load(){h=await (await fetch("/health",{cache:"no-store"})).json();
$("st").innerHTML=h.safe_mode?` + "`" + `<b class="warn">已暂停（安全模式）</b>：电脑现在走普通网络。<br>原因：${h.safe_mode.reason}<br><span class="muted">${h.safe_mode.since.replace("T"," ")} 起</span>` + "`" + `
:(h.singbox?'<b class="ok">运行中</b>：sing-box 正常接管网络。'+(h.server_fallback?` + "`" + `<br><span class="warn">连不上免流服务器，已自动改走「不用服务器」（原来是「${h.server_fallback.previous}」，${String(h.server_fallback.since).replace("T"," ")} 起）；能连上后自动切回。</span>` + "`" + `:''):'<b class="warn">sing-box 没有运行</b>');
$("go").textContent=h.safe_mode||!h.singbox?"重新启用":"暂停（回到普通网络）";}
$("go").onclick=async()=>{const s=$("sec").value.trim();try{localStorage.setItem("neu-secret",s)}catch{}
$("msg").textContent="处理中……（重新启用要等十几秒确认能上网）";
const r=await fetch(h.safe_mode||!h.singbox?"/resume":"/pause",{method:"POST",headers:{Authorization:"Bearer "+s}});
const d=await r.json().catch(()=>({}));$("msg").textContent=r.ok?"完成":(d.error||("失败 "+r.status));load();};
load();</script></body></html>`
