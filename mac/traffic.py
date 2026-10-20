#!/usr/bin/python3
"""按月统计免流省下的流量（mac，随 sing-box 一起装成 LaunchDaemon）。

每秒读一次 Clash API 的 /connections，按每条连接的实际出口记账：
  v6     校园网 IPv6 直连（免费）
  server 经免流服务器出去（免费；上下行之和 ≈ 该服务器的出站流量），按服务器分开
  v4     校园网 IPv4 直连（计费）
  lan    局域网 / 校园网内（不计费）
  other  直连但看不出走 v4 还是 v6
连接在两次采样之间关闭时丢掉的尾巴，用 sing-box 的总流量补齐，按本次各类占比分摊。
结果写到 <状态目录>/traffic.json，并在 127.0.0.1:<端口>/traffic 提供给面板读取。
用法：traffic.py -c config.json -d 状态目录 [-p 9091]
"""
import argparse, ipaddress, json, os, signal, threading, time, urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENTRY = "免流服务器"  # 与 lib/groups.js 一致
GROUP_TYPES = {"selector", "urltest"}
KINDS = ("v6", "server", "v4", "lan", "other")

ap = argparse.ArgumentParser()
ap.add_argument("-c", "--config", required=True)
ap.add_argument("-d", "--dir", required=True)
ap.add_argument("-p", "--port", type=int, default=9091)
ap.add_argument("-i", "--interval", type=float, default=1.0)
args = ap.parse_args()
STATE = os.path.join(args.dir, "traffic.json")

cfg = json.load(open(args.config))
clash = cfg["experimental"]["clash_api"]
API = "http://" + clash["external_controller"]
SECRET = clash.get("secret", "")
PANEL_ORIGINS = {API, API.replace("127.0.0.1", "localhost")}
OUT = {o["tag"]: o for o in cfg["outbounds"]}
ENTRY_MEMBERS = {t for t in OUT.get(ENTRY, {}).get("outbounds", []) if OUT.get(t, {}).get("type") not in GROUP_TYPES | {"direct"}}


def get(path):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + SECRET})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)


def is_v6(addr):
    try:
        return ipaddress.ip_address(addr).version == 6
    except ValueError:
        return False


def resolve(tag, now, depth=0):
    """出口 tag → ("server", 服务器名) / ("v6",) / ("v4",) / ("direct", 解析策略)"""
    o = OUT.get(tag)
    if not o or depth > 8:
        return ("other",)
    t = o["type"]
    if t in GROUP_TYPES:
        sel = now.get(tag) or o.get("default") or (o.get("outbounds") or [None])[0]
        return resolve(sel, now, depth + 1)
    if t == "direct":
        return ("direct", (o.get("domain_resolver") or {}).get("strategy", ""))
    if tag in ENTRY_MEMBERS:
        return ("server", tag.rsplit(" ", 1)[0])  # 入口名「<服务器名> <协议>」→ 服务器名
    if o.get("detour"):
        r = resolve(o["detour"], now, depth + 1)
        if r[0] == "server":
            return r
    return ("v6",) if is_v6(o.get("server", "")) else ("v4",)


def classify(conn, now):
    chains = conn.get("chains") or []
    r = resolve(chains[0], now) if chains else ("other",)
    if r[0] != "direct":
        return r[0], (r[1] if r[0] == "server" else None)
    if r[1] in ("ipv6_only", "prefer_ipv6"):
        return "v6", None
    if r[1] == "ipv4_only":
        return "v4", None
    m = conn.get("metadata", {})
    host = (m.get("host") or "").lower()
    if host == "neu.edu.cn" or host.endswith(".neu.edu.cn"):
        return "lan", None
    try:
        ip = ipaddress.ip_address(m.get("destinationIP") or "")
    except ValueError:
        return "other", None
    if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast:
        return "lan", None
    return ("v6" if ip.version == 6 else "v4"), None


def empty():
    return {"v6": 0, "server": {}, "v4": 0, "lan": 0, "other": 0}


def add(b, kind, srv, n):
    if kind == "server":
        b["server"][srv] = b["server"].get(srv, 0) + n
    else:
        b[kind] += n


lock = threading.Lock()
try:
    state = json.load(open(STATE))
except (OSError, ValueError):
    state = {}
state.setdefault("since", datetime.now().isoformat(timespec="seconds"))
state.setdefault("months", {})
state.setdefault("days", {})
live = {"rate": empty(), "updated": None, "ok": False}


def save():
    with lock:
        data = json.dumps(state, ensure_ascii=False)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        f.write(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATE)


def collect():
    last, last_total, now_sel, mix = None, None, {}, {}
    tick, last_save = 0, time.time()
    while True:
        t0 = time.time()
        try:
            if tick % 5 == 0:
                now_sel = {k: v.get("now") for k, v in get("/proxies")["proxies"].items() if v.get("now")}
            d = get("/connections")
            conns = d.get("connections") or []
            total = d.get("downloadTotal", 0) + d.get("uploadTotal", 0)
            cur, deltas = {}, {}
            for c in conns:
                n = c.get("upload", 0) + c.get("download", 0)
                cur[c["id"]] = n
                if last is None:
                    continue  # 刚启动：已有连接只取基线，不重复记
                delta = n - last.get(c["id"], 0)
                if delta < 0:
                    delta = n
                if delta:
                    key = classify(c, now_sel)
                    deltas[key] = deltas.get(key, 0) + delta
            if last_total is not None and total >= last_total:
                rest = (total - last_total) - sum(deltas.values())
                base = deltas or mix
                if rest > 0 and base:
                    s = sum(base.values())
                    for k, v in base.items():
                        deltas[k] = deltas.get(k, 0) + rest * v // s
            if deltas:
                mix = dict(deltas)
            dt = max(time.time() - (live.get("_t") or t0), 0.5)
            rate = empty()
            stamp = datetime.now()
            mk, dk = stamp.strftime("%Y-%m"), stamp.strftime("%Y-%m-%d")
            with lock:
                mb = state["months"].setdefault(mk, empty())
                db = state["days"].setdefault(dk, empty())
                for (kind, srv), n in deltas.items():
                    add(mb, kind, srv, n)
                    add(db, kind, srv, n)
                    add(rate, kind, srv, n / dt)
                for k in sorted(state["days"])[:-62]:
                    del state["days"][k]
                live.update(rate=rate, updated=stamp.isoformat(timespec="seconds"), ok=True, _t=time.time())
            last, last_total = cur, total
        except Exception as e:  # sing-box 重启或未运行：重新取基线
            last, last_total = None, None
            live.update(ok=False, error=str(e)[:200], _t=None)
        tick += 1
        if time.time() - last_save > 30:
            save()
            last_save = time.time()
        time.sleep(max(args.interval - (time.time() - t0), 0.1))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/traffic":
            self.send_error(404)
            return
        with lock:
            body = json.dumps({**state, "live": {k: v for k, v in live.items() if not k.startswith("_")}}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        origin = self.headers.get("Origin", "")
        if origin in PANEL_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def stop(*_):
    save()
    os._exit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
os.makedirs(args.dir, exist_ok=True)
threading.Thread(target=collect, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
