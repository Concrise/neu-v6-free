#!/usr/bin/python3
"""本地助手（mac，随 sing-box 一起装成 LaunchDaemon），给面板提供两样 sing-box 自己做不到的事：

一、我的规则（/rules）：面板里加的规则写进 <规则目录>/user-<目标>.json，sing-box 发现文件变了会自动重新加载，
   不用重新生成配置、不用重启。全部规则另存一份在 <规则目录>/user-rules.json（面板显示顺序、备注都在这里）。

二、流量统计（/traffic）：每秒读一次 Clash API 的 /connections，按每条连接的实际出口记账：
  v6     校园网 IPv6 直连（免费）
  server 经免流服务器出去（免费；上下行之和 ≈ 该服务器的出站流量），按服务器分开
  v4     校园网 IPv4 直连（计费）
  lan    局域网 / 校园网内（不计费）
  other  直连但看不出走 v4 还是 v6
连接在两次采样之间关闭时丢掉的尾巴，用 sing-box 的总流量补齐，按本次各类占比分摊。
结果写到 <状态目录>/traffic.json。

三、更新配置（/apply）：mac/update.sh 生成新配置后交给助手安装并重启 sing-box。助手本来就以 root 运行，
   所以只有第一次安装要 sudo，之后更新都不用。装之前先检查配置里的文件路径都在安装目录内，并用 sing-box check 验证。

只监听 127.0.0.1。/rules 和 /apply 要带和 Clash API 相同的密钥；/rules 只接受面板页面的跨域请求，/apply 不接受任何网页的请求。
用法：helper.py -c config.json -d 状态目录 [-p 9091] [-l 服务名]
"""
import argparse, filecmp, glob, ipaddress, json, os, re, shutil, signal, subprocess, tempfile, threading, time, urllib.request
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
ap.add_argument("-l", "--label", default="", help="sing-box 服务的 launchd 名字（/apply 重启用）")
args = ap.parse_args()
STATE = os.path.join(args.dir, "traffic.json")
CONFIG = os.path.abspath(args.config)
ETC_DIR = os.path.dirname(CONFIG)
BIN_DIR = os.path.dirname(os.path.abspath(__file__))
RULE_TYPES = ("domain_suffix", "domain", "domain_keyword", "ip_cidr", "process_name")
rules_lock = threading.Lock()
apply_lock = threading.Lock()


def reload():
    """读配置：Clash API 地址与密钥、出口（流量统计用）、「我的规则」的目标。/apply 装了新配置后再调一次。"""
    global cfg, API, SECRET, PANEL_ORIGINS, OUT, ENTRY_MEMBERS, TARGETS, RULES_DIR, RULES_FILE
    cfg = json.load(open(CONFIG))
    clash = cfg["experimental"]["clash_api"]
    API = "http://" + clash["external_controller"]
    SECRET = clash.get("secret", "")
    PANEL_ORIGINS = {API, API.replace("127.0.0.1", "localhost")}
    OUT = {o["tag"]: o for o in cfg["outbounds"]}
    ENTRY_MEMBERS = {t for t in OUT.get(ENTRY, {}).get("outbounds", []) if OUT.get(t, {}).get("type") not in GROUP_TYPES | {"direct"}}
    # 目标 id → 规则文件路径、出口名（规则集 user-<id> 和引用它的路由规则）
    targets = {}
    for rs in cfg["route"].get("rule_set", []):
        if rs.get("tag", "").startswith("user-") and rs.get("type") == "local":
            targets[rs["tag"][5:]] = {"path": rs["path"], "name": None}
    for r in cfg["route"].get("rules", []):
        sets = r.get("rule_set") or []
        if len(sets) == 1 and sets[0].startswith("user-") and sets[0][5:] in targets:
            targets[sets[0][5:]]["name"] = r.get("outbound") or ("拒绝" if r.get("action") == "reject" else None)
    TARGETS = targets
    RULES_DIR = os.path.dirname(next(iter(TARGETS.values()))["path"]) if TARGETS else None
    RULES_FILE = os.path.join(RULES_DIR, "user-rules.json") if RULES_DIR else None


reload()


class BadRule(ValueError):
    pass


def normalize(kind, value):
    """把面板里粘贴的东西整理成 sing-box 能用的值；不合法就抛 BadRule（消息直接显示给用户）。"""
    v = str(value or "").strip()
    if kind not in RULE_TYPES:
        raise BadRule(f"不支持的类型：{kind}")
    if not v:
        raise BadRule("内容是空的")
    if kind == "ip_cidr":
        try:
            return str(ipaddress.ip_network(v, strict=False))
        except ValueError:
            raise BadRule(f"不是 IP 或网段：{v}")
    if kind == "process_name":
        if re.search(r"[/\\]", v) or len(v) > 128:
            raise BadRule("进程名只写名字，不要带路径，例如 chrome.exe 或 WeChat")
        return v
    v = v.lower()
    v = re.sub(r"^[a-z][a-z0-9+.-]*://", "", v)  # 粘贴了整个网址：去掉协议、路径、端口
    v = re.split(r"[/?#]", v, maxsplit=1)[0]
    v = re.sub(r":\d+$", "", v).lstrip("*.").rstrip(".")
    if kind != "domain_keyword":
        try:
            v = v.encode("idna").decode()  # 中文域名转成 xn-- 形式
        except UnicodeError:
            raise BadRule(f"不是域名：{v}")
    if kind == "domain_keyword":
        if not re.fullmatch(r"[a-z0-9._-]+", v):
            raise BadRule(f"关键词只能有字母、数字和 . _ -：{v}")
        return v
    if not re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)*", v):
        raise BadRule(f"不是域名：{v}")
    return v


def load_rules():
    try:
        with open(RULES_FILE) as f:
            return json.load(f).get("rules", [])
    except (OSError, ValueError):
        pass
    # 第一次运行：把规则文件里已有的内容（手动写的）收进来
    rules = []
    for tid, t in TARGETS.items():
        try:
            with open(t["path"]) as f:
                for r in json.load(f).get("rules", []):
                    for kind in RULE_TYPES:
                        for v in r.get(kind, []):
                            rules.append({"type": kind, "value": v, "target": tid, "note": ""})
        except (OSError, ValueError):
            continue
    return rules


def write_json(path, data):
    """先写临时文件再替换：sing-box 不会读到写了一半的文件。"""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def apply_rules(rules):
    """全部规则 → user-rules.json + 每个目标一个 sing-box 规则集；内容没变的文件不动，免得白白重新加载。"""
    write_json(RULES_FILE, {"version": 1, "rules": rules})
    for tid, t in TARGETS.items():
        mine = [r for r in rules if r["target"] == tid]
        dest = {}
        for r in mine:
            if r["type"] != "process_name":
                dest.setdefault(r["type"], []).append(r["value"])
        procs = [r["value"] for r in mine if r["type"] == "process_name"]
        # 同一条规则里的域名与 IP 是「或」，进程名和它们是「且」，所以进程名单独一条
        body = {"version": 2, "rules": ([dest] if dest else []) + ([{"process_name": procs}] if procs else [])}
        try:
            with open(t["path"]) as f:
                if json.load(f) == body:
                    continue
        except (OSError, ValueError):
            pass
        write_json(t["path"], body)


def rules_view(rules):
    return {
        "targets": [{"id": k, "name": v["name"]} for k, v in TARGETS.items()],
        "rules": [{**r, "orphan": r["target"] not in TARGETS} for r in rules],
        "dir": RULES_DIR,
    }


def rules_change(op, body):
    with rules_lock:
        rules = load_rules()
        if op == "add":
            kind = body.get("type")
            value = normalize(kind, body.get("value"))
            if body.get("target") not in TARGETS:
                raise BadRule(f"没有这个目标：{body.get('target')}")
            # 同一个值只能有一个去处：先删掉旧的
            rules = [r for r in rules if not (r["type"] == kind and r["value"] == value)]
            rules.append({"type": kind, "value": value, "target": body["target"], "note": str(body.get("note") or "")[:200],
                          "added": datetime.now().isoformat(timespec="seconds")})
        elif op == "delete":
            rules = [r for r in rules if not (r["type"] == body.get("type") and r["value"] == body.get("value"))]
        elif op == "replace":
            new = []
            for i, r in enumerate(body.get("rules") or []):
                try:
                    value = normalize(r.get("type"), r.get("value"))
                except BadRule as e:
                    raise BadRule(f"第 {i + 1} 条：{e}")
                if r.get("target") not in TARGETS:
                    raise BadRule(f"第 {i + 1} 条：没有这个目标：{r.get('target')}")
                new = [x for x in new if not (x["type"] == r["type"] and x["value"] == value)]
                new.append({"type": r["type"], "value": value, "target": r["target"], "note": str(r.get("note") or "")[:200],
                            "added": r.get("added") or datetime.now().isoformat(timespec="seconds")})
            rules = new
        apply_rules(rules)
        return rules_view(rules)


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


# ---------- 更新配置（/apply）----------
class BadConfig(ValueError):
    pass


FILE_KEY = re.compile(r"_path$")  # certificate_path、key_path 等；process_path 是匹配条件，不是文件
NOT_FILE = {"process_path", "process_path_regex"}


def file_paths(cfg):
    """sing-box 配置里所有指向本机文件的字段（传输层的 path 是网址路径，不算）。"""
    found = []
    exp = cfg.get("experimental") or {}
    found.append(("log.output", (cfg.get("log") or {}).get("output")))
    found.append(("cache_file.path", (exp.get("cache_file") or {}).get("path")))
    found.append(("clash_api.external_ui", (exp.get("clash_api") or {}).get("external_ui")))
    for rs in (cfg.get("route") or {}).get("rule_set") or []:
        found.append(("rule_set.path", rs.get("path")))

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(v, str) and FILE_KEY.search(k) and k not in NOT_FILE:
                    found.append((k, v))
                else:
                    walk(v)
        elif isinstance(node, list):
            for x in node:
                walk(x)
    walk(cfg)
    return [(k, v) for k, v in found if isinstance(v, str) and v]


def check_paths(cfg):
    """绝对路径必须在安装目录内，相对路径（相对 sing-box 工作目录）不能有 ..。
    sing-box 以 root 运行，不检查的话，一份配置就能让它往系统任意位置写文件。"""
    for k, v in file_paths(cfg):
        if os.path.isabs(v):
            real = os.path.realpath(v)
            if real != ETC_DIR and not real.startswith(ETC_DIR + os.sep):
                raise BadConfig(f"配置里的 {k} 指向安装目录（{ETC_DIR}）以外：{v}")
        elif ".." in v.replace("\\", "/").split("/"):
            raise BadConfig(f"配置里的 {k} 不能包含 ..：{v}")


def install_file(src, dest, mode=0o644):
    tmp = dest + ".tmp"
    shutil.copyfile(src, tmp)
    if os.geteuid() == 0:  # 正常以 root 运行；不是 root 时（开发测试）保持当前用户
        os.chown(tmp, 0, 0)
    os.chmod(tmp, mode)
    os.replace(tmp, dest)


def apply_update(src):
    """把生成目录（cli.js 的 out/mac）里的新配置装好并重启 sing-box。返回给 update.sh 显示的结果。"""
    src = os.path.realpath(str(src or ""))
    cfg_file = os.path.join(src, "config.json")
    if not os.path.isfile(cfg_file):
        raise BadConfig(f"{src} 里没有 config.json")
    try:
        with open(cfg_file) as f:
            new = json.load(f)
    except ValueError as e:
        raise BadConfig(f"config.json 不是合法的 JSON：{e}")
    check_paths(new)
    with apply_lock:
        rules_dir, panel_dir = os.path.join(ETC_DIR, "rules"), os.path.join(ETC_DIR, "panel")
        os.makedirs(rules_dir, exist_ok=True)
        os.makedirs(panel_dir, exist_ok=True)
        # 先装规则集再检查：配置引用的是安装目录里的规则集
        for f in glob.glob(os.path.join(src, "rules", "*.srs")):
            install_file(f, os.path.join(rules_dir, os.path.basename(f)))
        for f in glob.glob(os.path.join(src, "rules", "user-*.json")):  # 「我的规则」只补缺的
            if not os.path.exists(os.path.join(rules_dir, os.path.basename(f))):
                install_file(f, os.path.join(rules_dir, os.path.basename(f)))
        for name in ("index.html", "groups.json"):
            if os.path.isfile(os.path.join(src, "panel", name)):
                install_file(os.path.join(src, "panel", name), os.path.join(panel_dir, name))
        staged = CONFIG + ".new"
        install_file(cfg_file, staged, 0o600)
        r = subprocess.run([os.path.join(BIN_DIR, "sing-box"), "check", "--disable-color", "-c", staged], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            os.unlink(staged)
            raise BadConfig("sing-box 检查没通过，旧配置没动：" + (r.stderr or r.stdout).strip()[-800:])
        os.replace(staged, CONFIG)
        restarted = bool(args.label)
        if restarted:
            subprocess.run(["launchctl", "kickstart", "-k", f"system/{args.label}"], timeout=60, check=False)
        reload()
        if TARGETS:
            with rules_lock:
                apply_rules(load_rules())
        new_helper = os.path.join(src, "helper.py")
        helper_updated = os.path.isfile(new_helper) and not filecmp.cmp(new_helper, os.path.abspath(__file__), shallow=False)
        if helper_updated:
            install_file(new_helper, os.path.join(BIN_DIR, "helper.py"), 0o755)
            threading.Timer(1.0, stop).start()  # 退出后 launchd 会拉起新版助手
    return {"ok": True, "restarted": restarted, "helper_updated": helper_updated}


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.cors()
        self.end_headers()
        self.wfile.write(body)

    def cors(self):
        origin = self.headers.get("Origin", "")
        if origin in PANEL_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT")

    def authorized(self):
        # 浏览器里别的网站也能向 127.0.0.1 发请求：要求密钥，并且只认面板页面
        origin = self.headers.get("Origin")
        if origin and origin not in PANEL_ORIGINS:
            return False
        return not SECRET or self.headers.get("Authorization") == "Bearer " + SECRET

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/traffic":
            with lock:
                data = {**state, "live": {k: v for k, v in live.items() if not k.startswith("_")}}
            self.reply(200, data)
        elif path == "/rules":
            if not self.authorized():
                return self.reply(401, {"error": "密钥不对"})
            if not TARGETS:
                return self.reply(404, {"error": "这份配置没有开「我的规则」（user_rules: false）"})
            with rules_lock:
                self.reply(200, rules_view(load_rules()))
        elif path == "/health":
            self.reply(200, {"ok": True, "rules": bool(TARGETS), "traffic": True, "apply": True})
        else:
            self.send_error(404)

    def change(self, op):
        if not self.authorized():
            return self.reply(401, {"error": "密钥不对"})
        if not TARGETS:
            return self.reply(404, {"error": "这份配置没有开「我的规则」（user_rules: false）"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(n, 1 << 20)) or b"{}")
            self.reply(200, rules_change(op, body))
        except BadRule as e:
            self.reply(400, {"error": str(e)})
        except (ValueError, OSError) as e:
            self.reply(500, {"error": f"保存失败：{e}"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/apply":
            # 只给本机脚本用：网页发来的一律拒绝；必须有密钥
            if self.headers.get("Origin") or not SECRET or self.headers.get("Authorization") != "Bearer " + SECRET:
                return self.reply(401, {"error": "密钥不对（或请求来自网页）"})
            try:
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(min(n, 1 << 16)) or b"{}")
                self.reply(200, apply_update(body.get("src")))
            except BadConfig as e:
                self.reply(400, {"error": str(e)})
            except (ValueError, OSError, subprocess.SubprocessError) as e:
                self.reply(500, {"error": f"更新失败：{e}"})
        elif path == "/rules":
            self.change("add")
        elif path == "/rules/delete":
            self.change("delete")
        else:
            self.send_error(404)

    def do_PUT(self):
        if self.path.split("?")[0] == "/rules":
            self.change("replace")
        else:
            self.send_error(404)

    def log_message(self, *a):
        pass


def stop(*_):
    save()
    os._exit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
os.makedirs(args.dir, exist_ok=True)
if TARGETS:
    with rules_lock:
        apply_rules(load_rules())  # 启动时按 user-rules.json 重写一遍规则文件（升级后新增的目标也会有文件）
threading.Thread(target=collect, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
