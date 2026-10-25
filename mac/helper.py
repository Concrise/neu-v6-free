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

四、断网保护：sing-box 装上、更新后、运行中，只要「经 sing-box 上不了网、绕过它却能上」，就停掉 sing-box（安全模式），
   电脑回到普通网络。安装与更新时不通会自动撤回；运行中每 30 秒检查一次，连续 3 次不通就暂停。
   状态页 http://127.0.0.1:<端口>/ 可以看原因、重新启用；面板里也能手动暂停。
   服务器单独看：当前网络连不上免流服务器（离开校园网、换了热点、服务器挂了）而网络本身是通的，
   就把「免流服务器」自动切到「不用服务器」，经服务器的流量改为直连；每两分钟试一次，连上了自动切回。

五、客户端（/profile、/fetch、/apply）：订阅、节点、设置在面板里管。设置存在安装目录的 profile.json；
   助手代面板下载订阅（浏览器有跨域限制）；面板在浏览器里生成配置后交给 /apply，和 update.sh 一样检查、安装、不通就换回。

六、自动更新（/update、/update/check、/update/install）：每天查一次 GitHub 上本项目的最新发布，面板里点「更新」后
   下载 macOS 安装包、按 SHA256SUMS 校验，换上新的面板、生成器、规则集和助手本身；配置、订阅与设置、我的规则不动。

只监听 127.0.0.1。/rules、/profile、/fetch、/apply、/update 都要带和 Clash API 相同的密钥；网页发来的请求只认面板页面。
用法：helper.py -c config.json -d 状态目录 [-p 9091] [-l 服务名]
"""
import argparse, filecmp, glob, hashlib, io, ipaddress, json, os, re, shutil, signal, subprocess, tempfile, threading, time, urllib.parse, urllib.request, zipfile
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


def publish_secret():
    """把面板密钥另存一份给 App 读（root:admin 640：管理员账户能读，和它们能 sudo 看配置一样）。
    App 用它自动登录面板、在菜单栏暂停 / 重新启用。config.json 本身仍然只有 root 能读。"""
    if os.geteuid() != 0:
        return
    f = os.path.join(ETC_DIR, "panel-secret")
    if not SECRET:
        if os.path.exists(f):
            os.unlink(f)
        return
    tmp = f + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        fh.write(SECRET + "\n")
    os.chown(tmp, 0, 80)  # 80 = admin 组
    os.chmod(tmp, 0o640)
    os.replace(tmp, f)


def reload():
    """读配置：Clash API 地址与密钥、出口（流量统计用）、「我的规则」的目标。/apply 装了新配置后再调一次。"""
    global cfg, API, SECRET, PANEL_ORIGINS, OUT, ENTRY_MEMBERS, TARGETS, RULES_DIR, RULES_FILE
    cfg = json.load(open(CONFIG))
    clash = cfg["experimental"]["clash_api"]
    API = "http://" + clash["external_controller"]
    SECRET = clash.get("secret", "")
    publish_secret()
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


# ---------- 断网保护 ----------
# 经 sing-box 的探测：域名（走 TUN、sing-box 的 DNS 与分流）；绕过 sing-box 的探测：绑定物理网卡访问 IP（不经 DNS）。
# 校园网 IPv4 拦了公共 DNS 的地址，所以绕过探测同时用 IPv6 和几个 IPv4 网站地址，任意一个有响应就算「网络本身是通的」
TUN_PROBES = ["https://www.taobao.com", "https://www.baidu.com", "https://www.qq.com"]
DIRECT_PROBES = ["http://[2400:3200::1]/", "http://[2402:4e00::]/", "http://220.181.111.1/", "http://110.242.68.66/"]
SAFE_FILE = os.path.join(args.dir, "safe-mode.json")
WATCH_INTERVAL, WATCH_FAILS = 30, 3


def log(msg):
    print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def responds(url, iface=None):
    cmd = ["/usr/bin/curl", "-skI", "-o", "/dev/null", "-m", "6", "--noproxy", "*", "-w", "%{http_code}", url]
    if iface:
        cmd[1:1] = ["--interface", iface]
    try:
        code = subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return code not in ("", "000")


def physical_iface():
    """默认路由所在的物理网卡（sing-box 只加 0/1、128/1 两条路由，默认路由还在物理网卡上）。"""
    try:
        out = subprocess.run(["/sbin/route", "-n", "get", "default"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"interface: (\S+)", out)
    return m.group(1) if m and not m.group(1).startswith("utun") else None


def net_state():
    """ok：经 sing-box 能上网；broken：经 sing-box 不通、绕过它能通（sing-box 的问题）；offline：网络本身不通（不是 sing-box 的问题）。"""
    if any(responds(u) for u in TUN_PROBES):
        return "ok"
    iface = physical_iface()
    if iface and any(responds(u, iface) for u in DIRECT_PROBES):
        return "broken"
    return "offline"


def wait_net(seconds=25):
    """sing-box 刚启动时给它一点时间；期间一通就返回 ok。"""
    end, st = time.time() + seconds, "broken"
    while time.time() < end:
        time.sleep(4)
        st = net_state()
        if st == "ok":
            return st
    return st


def singbox_running():
    if not args.label:
        return False
    r = subprocess.run(["launchctl", "print", f"system/{args.label}"], capture_output=True, text=True, timeout=10)
    return "state = running" in r.stdout


def safe_mode():
    try:
        with open(SAFE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def enter_safe_mode(reason):
    """停掉 sing-box（TUN 随之撤销，电脑回到普通网络），记下原因；重启电脑后也保持，直到手动重新启用或更新配置。"""
    if args.label:
        subprocess.run(["launchctl", "bootout", f"system/{args.label}"], capture_output=True, timeout=60)
    with open(SAFE_FILE, "w") as f:
        json.dump({"since": datetime.now().isoformat(timespec="seconds"), "reason": reason}, f, ensure_ascii=False)
    log(f"进入安全模式：{reason}")


def leave_safe_mode():
    if os.path.exists(SAFE_FILE):
        os.unlink(SAFE_FILE)
    if args.label and not singbox_running():
        subprocess.run(["launchctl", "bootstrap", "system", f"/Library/LaunchDaemons/{args.label}.plist"], capture_output=True, timeout=60)


def resume():
    """重新启用：启动 sing-box 并确认能上网，不行就退回安全模式。"""
    leave_safe_mode()
    st = wait_net()
    if st == "broken":
        enter_safe_mode("重新启用后经 sing-box 仍然上不了网")
        raise BadConfig("重新启用后经 sing-box 仍然上不了网，已再次暂停。看 sing-box.log；离开校园网时先在面板里选「不用服务器」")
    log("已重新启用")
    if st == "ok":
        server_check(quick=True)
    return {"ok": True, "net": st, "server_fallback": server_fallback()}


# ---------- 服务器连不上时自动改走「不用服务器」 ----------
ENTRY_OFF = "不用服务器（离校时选）"  # 与 lib/groups.js 一致
FALLBACK_FILE = os.path.join(args.dir, "server-fallback.json")
DELAY_URL = "https://www.gstatic.com/generate_204"


def clash(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + SECRET, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=12) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def entry_now():
    try:
        return clash("GET", "/proxies/" + urllib.parse.quote(ENTRY)).get("now")
    except Exception:
        return None


def reachable_via(name):
    """经某个出口（服务器入口、自动选最快、或「免流服务器」当前的选择）能不能打开网页：sing-box 自己测，不经 TUN。"""
    try:
        q = urllib.parse.quote(DELAY_URL, safe="")
        r = clash("GET", f"/proxies/{urllib.parse.quote(name)}/delay?timeout=6000&url={q}")
        return bool(r and r.get("delay"))
    except Exception:
        return False


def internet_ok():
    """绕过 sing-box，网络本身通不通。"""
    iface = physical_iface()
    return bool(iface) and any(responds(u, iface) for u in DIRECT_PROBES)


def server_fallback():
    try:
        with open(FALLBACK_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def fall_back(previous, reason):
    clash("PUT", "/proxies/" + urllib.parse.quote(ENTRY), {"name": ENTRY_OFF})
    with open(FALLBACK_FILE, "w") as f:
        json.dump({"previous": previous, "since": datetime.now().isoformat(timespec="seconds"), "reason": reason}, f, ensure_ascii=False)
    log(f"免流服务器连不上，已自动改走「{ENTRY_OFF}」（原来是「{previous}」）：{reason}")


guard_state = {"fails": 0, "oks": 0, "last_retry": 0.0, "checked": False}


def server_check(quick=False):
    """模式二才有「免流服务器」。quick：安装 / 更新 / 重新启用后立刻判断（连续 2 次连不上就切），平时要连续 3 次。"""
    guard_state["checked"] = True
    if ENTRY not in OUT:
        return
    now = entry_now()
    if now is None:
        return
    fb = server_fallback()
    if fb:
        if now != ENTRY_OFF:  # 用户自己在面板里改了选择：交还给用户
            os.unlink(FALLBACK_FILE)
            log("「免流服务器」已被手动改选，不再自动切换")
            return
        if time.time() - guard_state["last_retry"] < 120:
            return
        guard_state["last_retry"] = time.time()
        if reachable_via(fb["previous"]):
            guard_state["oks"] += 1
            if guard_state["oks"] >= 2:
                clash("PUT", "/proxies/" + urllib.parse.quote(ENTRY), {"name": fb["previous"]})
                os.unlink(FALLBACK_FILE)
                guard_state["oks"] = 0
                log(f"免流服务器又能连上了，已切回「{fb['previous']}」")
        else:
            guard_state["oks"] = 0
        return
    if now == ENTRY_OFF:  # 用户自己选的「不用服务器」
        guard_state["fails"] = 0
        return
    tries = 2 if quick else 1
    for i in range(tries):
        if reachable_via(ENTRY):
            guard_state["fails"] = 0
            return
        if i + 1 < tries:
            time.sleep(4)
    if not internet_ok():  # 网络本身不通，不是服务器的问题
        guard_state["fails"] = 0
        return
    guard_state["fails"] += 1
    log(f"连不上免流服务器「{now}」（第 {guard_state['fails']} 次）")
    if quick or guard_state["fails"] >= WATCH_FAILS:
        guard_state["fails"] = 0
        fall_back(now, "当前网络连不上免流服务器（离开了校园网、换了网络，或服务器挂了）")


def watchdog():
    fails, first = 0, True
    time.sleep(20)  # 等 sing-box 启动好
    while True:
        try:
            if safe_mode() or apply_lock.locked() or not singbox_running():
                fails = 0
            else:
                st = net_state()
                fails = fails + 1 if st == "broken" else 0
                if fails:
                    log(f"经 sing-box 上不了网，绕过它能上（第 {fails} 次）")
                if fails >= WATCH_FAILS:
                    enter_safe_mode(f"连续 {WATCH_FAILS} 次检查经 sing-box 上不了网、绕过它能上（配置或 sing-box 本身有问题）")
                    fails = 0
                elif st == "ok":
                    server_check(quick=first)  # 刚启动时立刻判断一次服务器，免得连不上时干等一分多钟
                    first = False
        except Exception as e:  # 看门狗自己不能挂
            log(f"看门狗出错：{e}")
        time.sleep(WATCH_INTERVAL)


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
        libs = glob.glob(os.path.join(src, "panel", "lib", "*.js")) + glob.glob(os.path.join(src, "panel", "lib", "*.mjs"))
        if libs:  # 面板在浏览器里生成配置用的模块
            os.makedirs(os.path.join(panel_dir, "lib"), exist_ok=True)
            for f in libs:
                install_file(f, os.path.join(panel_dir, "lib", os.path.basename(f)))
        if os.path.isfile(os.path.join(src, "VERSION")):
            install_file(os.path.join(src, "VERSION"), VERSION_FILE)
        if os.path.isfile(os.path.join(src, "profile.json")):  # update.sh：命令行的设置覆盖面板里的
            install_file(os.path.join(src, "profile.json"), PROFILE, 0o600)
        staged = CONFIG + ".new"
        install_file(cfg_file, staged, 0o600)
        r = subprocess.run([os.path.join(BIN_DIR, "sing-box"), "check", "--disable-color", "-c", staged], capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            os.unlink(staged)
            raise BadConfig("sing-box 检查没通过，旧配置没动：" + (r.stderr or r.stdout).strip()[-800:])
        backup = CONFIG + ".prev"
        install_file(CONFIG, backup, 0o600)  # 有密钥和节点密码，和 config.json 一样只给 root
        os.replace(staged, CONFIG)
        restarted = bool(args.label)
        if restarted:
            if safe_mode():
                leave_safe_mode()  # 更新配置 = 重新启用
            else:
                subprocess.run(["launchctl", "kickstart", "-k", f"system/{args.label}"], timeout=60, check=False)
            if wait_net() == "broken":
                os.replace(backup, CONFIG)
                subprocess.run(["launchctl", "kickstart", "-k", f"system/{args.label}"], timeout=60, check=False)
                st = wait_net()
                if st == "broken":
                    enter_safe_mode("新配置和旧配置经 sing-box 都上不了网")
                log("新配置装上后经 sing-box 上不了网，已换回旧配置")
                raise BadConfig("新配置装上后经 sing-box 上不了网，已自动换回旧配置" + ("" if st != "broken" else "；旧配置也不通，已暂停 sing-box（安全模式）")
                                + "。看 sing-box.log；离开校园网时先在面板里选「不用服务器」")
        reload()
        if TARGETS:
            with rules_lock:
                apply_rules(load_rules())
        new_helper = os.path.join(src, "helper.py")
        helper_updated = os.path.isfile(new_helper) and not filecmp.cmp(new_helper, os.path.abspath(__file__), shallow=False)
        if helper_updated:
            install_file(new_helper, os.path.join(BIN_DIR, "helper.py"), 0o755)
            threading.Timer(1.0, stop).start()  # 退出后 launchd 会拉起新版助手
        if restarted:
            server_check(quick=True)
    return {"ok": True, "restarted": restarted, "helper_updated": helper_updated, "server_fallback": server_fallback()}


# ---------- 客户端：订阅、节点、设置都在面板里管 ----------
# 面板保存的全部设置（订阅链接与内容、手动节点、模式、服务器……）存在安装目录的 profile.json，只有 root 能读。
# 面板在浏览器里用 lib/build.js 生成配置，再交给 /apply 安装；助手只负责存取设置、代为下载订阅（浏览器有跨域限制）
PROFILE = os.path.join(ETC_DIR, "profile.json")
MAX_BODY = 32 << 20
MAX_DOWNLOAD = 20 << 20
SAFE_NAME = re.compile(r"^[\w.!+-]+$")


def install_defaults():
    """和这次安装绑定、面板不该改的设置：从正在用的配置里读。面板生成配置时用它们覆盖 profile 里的同名项。"""
    clash = cfg["experimental"]["clash_api"]
    main = next((i for i in cfg.get("inbounds", []) if i.get("tag") == "main"), {})
    srs = [rs["path"] for rs in cfg["route"].get("rule_set", []) if rs.get("type") == "local" and rs.get("format") == "binary"]
    return {"platform": "mac", "clash_api": clash["external_controller"], "clash_api_secret": SECRET,
            "panel_dir": clash.get("external_ui") or os.path.join(ETC_DIR, "panel"),
            "rules_dir": os.path.dirname(srs[0]) if srs else os.path.join(ETC_DIR, "rules"),
            "listen": main.get("listen", "127.0.0.1"), "main_port": main.get("listen_port", 10808), "traffic_port": args.port}


def load_profile():
    try:
        with open(PROFILE, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return None


def save_profile(p):
    if not isinstance(p, dict):
        raise BadConfig("设置的格式不对")
    tmp = PROFILE + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
        json.dump(p, f, ensure_ascii=False)
    os.replace(tmp, PROFILE)
    return {"ok": True}


def download(url, limit=MAX_DOWNLOAD, ua="neu-v6-free"):
    u = urllib.parse.urlsplit(url or "")
    if u.scheme not in ("http", "https") or not u.hostname:
        raise BadConfig("只支持 http / https 链接")
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read(limit + 1)
            if len(data) > limit:
                raise BadConfig(f"内容太大（超过 {limit >> 20}MB）")
            return r, data
    except urllib.error.HTTPError as e:
        raise BadConfig(f"服务器返回 {e.code}（链接失效或过期？）")
    except (urllib.error.URLError, OSError) as e:
        raise BadConfig(f"下载失败：{getattr(e, 'reason', e)}")


def fetch_subscription(url):
    # 带 clash.meta 的 User-Agent：多数机场据此返回完整的 mihomo 配置（不然给的是 base64 链接，信息更少）
    r, data = download(url, ua="clash.meta (neu-v6-free)")
    return {"status": r.status, "text": data.decode("utf-8", "replace"),
            "userinfo": r.headers.get("subscription-userinfo"), "disposition": r.headers.get("content-disposition")}


def apply_inline(body):
    """面板生成的配置：放进临时生成目录（和 cli.js 的输出一样的结构），缺的规则集按面板给的地址下载，再走 apply_update。"""
    conf, panel = body.get("config"), body.get("panel")
    # 面板发来的是 JSON 文本（Windows 的助手要原样写盘）；也接受对象
    conf, panel = [json.loads(x) if isinstance(x, str) else x for x in (conf, panel)]
    if not isinstance(conf, dict) or not isinstance(panel, dict):
        raise BadConfig("缺少 config 或 panel")
    check_paths(conf)
    urls = body.get("rule_sets") or {}
    stage = tempfile.mkdtemp(prefix=".stage-", dir=ETC_DIR)
    try:
        os.makedirs(os.path.join(stage, "rules"))
        os.makedirs(os.path.join(stage, "panel"))
        with open(os.path.join(stage, "config.json"), "w", encoding="utf-8") as f:
            json.dump(conf, f, ensure_ascii=False)
        with open(os.path.join(stage, "panel", "groups.json"), "w", encoding="utf-8") as f:
            json.dump(panel, f, ensure_ascii=False)
        for rs in (conf.get("route") or {}).get("rule_set") or []:
            if rs.get("type") != "local":
                continue
            name = os.path.basename(rs.get("path") or "")
            if not SAFE_NAME.match(name):
                raise BadConfig(f"规则集文件名不对：{name}")
            if rs.get("format") == "source":  # 「我的规则」的文件：apply_update 只补缺的
                with open(os.path.join(stage, "rules", name), "w") as f:
                    f.write('{"version":2,"rules":[]}\n')
            elif not os.path.exists(rs["path"]):
                url = urls.get(rs.get("tag"))
                if not (isinstance(url, str) and url.startswith("https://")):
                    raise BadConfig(f"本机没有规则集 {rs.get('tag')}，也没有给下载地址")
                _, data = download(url)
                with open(os.path.join(stage, "rules", name), "wb") as f:
                    f.write(data)
        return apply_update(stage)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


# ---------- 自动更新：从 GitHub Releases 升级程序本身 ----------
# 只从本仓库的正式发布下载 macOS 安装包，按同一发布里的 SHA256SUMS 校验；装的是面板、生成器、规则集、本地助手和脚本，
# 配置、订阅与设置、我的规则都不动（新生成器要在面板里点一次「应用」才用上）。每天自动查一次，装要用户在面板里点
UPDATE_REPO = "Concrise/neu-v6-free"
UPDATE_API = os.environ.get("NEU_UPDATE_API") or f"https://api.github.com/repos/{UPDATE_REPO}/releases/latest"  # 环境变量只给测试用
UPDATE_PREFIX = "" if os.environ.get("NEU_UPDATE_API") else f"https://github.com/{UPDATE_REPO}/releases/download/"
VERSION_FILE = os.path.join(ETC_DIR, "VERSION")
update_state = {"latest": None, "notes": "", "url": None, "asset": None, "sums": None, "checked": None, "error": None}


def current_version():
    try:
        return open(VERSION_FILE).read().strip() or "0"
    except OSError:
        return "0"  # 1.0.0 及更早的安装没有版本文件


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or "")[:3]) or (0,)


def update_view():
    u, cur = update_state, current_version()
    newer = bool(u["latest"]) and vtuple(u["latest"]) > vtuple(cur)
    error = u["error"] or ("新版本还没有 macOS 安装包" if newer and not u["asset"] else None)
    return {"current": cur, "latest": u["latest"], "available": newer and bool(u["asset"]), "notes": u["notes"], "url": u["url"],
            "checked": u["checked"], "error": error}


def check_update():
    try:
        _, data = download(UPDATE_API, limit=1 << 20)
        rel = json.loads(data)
        assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets") or []}
        mac = next((n for n in assets if n.endswith("-macos.zip")), None)
        update_state.update(latest=str(rel["tag_name"]).lstrip("v"), notes=rel.get("body") or "", url=rel.get("html_url"),
                            asset=mac and {"name": mac, "url": assets[mac]}, sums=assets.get("SHA256SUMS"), error=None)
    except (BadConfig, ValueError, KeyError) as e:
        update_state["error"] = f"检查更新失败：{e}"
    update_state["checked"] = datetime.now().isoformat(timespec="seconds")
    return update_view()


def install_update():
    v = check_update()
    if not v["available"]:
        raise BadConfig(v.get("error") or "已经是最新版本")
    a = update_state["asset"]
    for url in (a["url"], update_state["sums"] or ""):
        if not url.startswith(UPDATE_PREFIX):
            raise BadConfig(f"下载地址不是本项目的发布：{url}")
    if not update_state["sums"]:
        raise BadConfig("发布里没有 SHA256SUMS，没法校验，不安装")
    _, z = download(a["url"], limit=60 << 20)
    _, sums = download(update_state["sums"], limit=1 << 16)
    want = next((l.split()[0] for l in sums.decode().splitlines() if l.strip().endswith(a["name"])), None)
    if not want or hashlib.sha256(z).hexdigest() != want.lower():
        raise BadConfig("安装包校验不通过（SHA256 不符），没有安装")
    old = current_version()
    stage = tempfile.mkdtemp(prefix=".update-", dir=ETC_DIR)
    try:
        with zipfile.ZipFile(io.BytesIO(z)) as zf:
            for n in zf.namelist():
                if n.startswith("/") or ".." in n.split("/"):
                    raise BadConfig(f"安装包里有不安全的路径：{n}")
            zf.extractall(stage)
        pkg = next((os.path.dirname(f) for f in glob.glob(os.path.join(stage, "*", "VERSION"))), None)
        if not pkg or not os.path.isfile(os.path.join(pkg, "helper.py")):
            raise BadConfig("安装包的结构不对")
        new_helper = os.path.join(pkg, "helper.py")
        restart = not filecmp.cmp(new_helper, os.path.abspath(__file__), shallow=False)
        with apply_lock:
            panel_dir = (cfg["experimental"]["clash_api"].get("external_ui")) or os.path.join(ETC_DIR, "panel")
            install_file(os.path.join(pkg, "panel", "index.html"), os.path.join(panel_dir, "index.html"))
            os.makedirs(os.path.join(panel_dir, "lib"), exist_ok=True)
            for f in glob.glob(os.path.join(pkg, "panel", "lib", "*")):
                install_file(f, os.path.join(panel_dir, "lib", os.path.basename(f)))
            rules_dir = RULES_DIR or os.path.join(ETC_DIR, "rules")
            for f in glob.glob(os.path.join(pkg, "rules", "*.srs")):  # 规则集顺便换成新的
                install_file(f, os.path.join(rules_dir, os.path.basename(f)))
            for name in ("uninstall.sh", "helper-service.sh"):
                if os.path.isfile(os.path.join(pkg, name)):
                    install_file(os.path.join(pkg, name), os.path.join(BIN_DIR, name), 0o755)
            install_file(new_helper, os.path.join(BIN_DIR, "helper.py"), 0o755)
            install_app(pkg)
            install_file(os.path.join(pkg, "VERSION"), VERSION_FILE)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    log(f"已从 {old} 更新到 {current_version()}")
    if restart:
        threading.Timer(1.0, stop).start()  # 退出后 launchd 拉起新版助手
    return {"ok": True, "from": old, "to": current_version(), "helper_restart": restart}


APP_NAME = "校园网 v6 免流.app"


def install_app(pkg):
    """安装包里带了 App 就换掉 /Applications 里的（开着的 App 发现自己的版本变了会重新打开）"""
    src = os.path.join(pkg, APP_NAME)
    if not os.path.isdir(src):
        return
    dest = os.path.join("/Applications", APP_NAME)
    tmp = os.path.join("/Applications", ".neu-v6-free-app.new")
    shutil.rmtree(tmp, ignore_errors=True)
    subprocess.run(["ditto", src, tmp], check=True, timeout=120)
    subprocess.run(["chown", "-R", "root:wheel", tmp], check=True, timeout=60)
    for f in glob.glob(os.path.join(tmp, "Contents", "MacOS", "*")):
        os.chmod(f, 0o755)  # zipfile 解压不保留可执行权限
    old = None
    if os.path.exists(dest):
        old = os.path.join("/Applications", ".neu-v6-free-app.old")
        shutil.rmtree(old, ignore_errors=True)
        os.rename(dest, old)
    os.rename(tmp, dest)
    if old:
        shutil.rmtree(old, ignore_errors=True)


def update_checker():
    time.sleep(90)
    while True:
        check_update()
        time.sleep(24 * 3600)


# sing-box 停掉时面板（由 sing-box 提供）打不开，助手自己给一个最简单的状态页
STATUS_PAGE = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>校园网 v6 免流 · 状态</title><style>body{font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;max-width:620px;margin:40px auto;padding:0 16px;color:#1c2027}
.card{border:1px solid #e1e4ea;border-radius:12px;padding:16px 18px;margin:12px 0}.ok{color:#157f3b}.warn{color:#b45309}button{padding:6px 14px;border-radius:8px;border:1px solid #2457d6;background:#2457d6;color:#fff;cursor:pointer}
input{padding:6px 10px;border:1px solid #e1e4ea;border-radius:8px}.muted{color:#646b78;font-size:13px}</style></head><body>
<h2>校园网 v6 免流 · 状态</h2><div class="card" id="st">读取中……</div>
<div class="card"><input type="password" id="sec" placeholder="面板密钥"> <button id="go"></button><p class="muted" id="msg"></p></div>
<p class="muted">面板：<a href="http://127.0.0.1:9090/ui">http://127.0.0.1:9090/ui</a>（sing-box 运行时才能打开）</p>
<script>
const $=(i)=>document.getElementById(i);let h=null;try{$("sec").value=localStorage.getItem("neu-secret")||""}catch{}
async function load(){h=await (await fetch("/health",{cache:"no-store"})).json();
$("st").innerHTML=h.safe_mode?`<b class="warn">已暂停（安全模式）</b>：电脑现在走普通网络。<br>原因：${h.safe_mode.reason}<br><span class="muted">${h.safe_mode.since.replace("T"," ")} 起</span>`
:(h.singbox?'<b class="ok">运行中</b>：sing-box 正常接管网络。'+(h.server_fallback?`<br><span class="warn">连不上免流服务器，已自动改走「不用服务器」（原来是「${h.server_fallback.previous}」，${String(h.server_fallback.since).replace("T"," ")} 起）；能连上后自动切回。</span>`:''):'<b class="warn">sing-box 没有运行</b>');
$("go").textContent=h.safe_mode||!h.singbox?"重新启用":"暂停（回到普通网络）";}
$("go").onclick=async()=>{const s=$("sec").value.trim();try{localStorage.setItem("neu-secret",s)}catch{}
$("msg").textContent="处理中……（重新启用要等十几秒确认能上网）";
const r=await fetch(h.safe_mode||!h.singbox?"/resume":"/pause",{method:"POST",headers:{Authorization:"Bearer "+s}});
const d=await r.json().catch(()=>({}));$("msg").textContent=r.ok?"完成":(d.error||("失败 "+r.status));load();};
load();</script></body></html>"""


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
        if origin in PANEL_ORIGINS:  # 状态页和助手同源，不需要跨域头
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT")

    def authorized(self, own_page=False):
        # 浏览器里别的网站也能向 127.0.0.1 发请求：要求密钥，并且只认面板页面（暂停 / 重新启用还认助手自己的状态页）
        origin = self.headers.get("Origin")
        own = {f"http://127.0.0.1:{args.port}", f"http://localhost:{args.port}"} if own_page else set()
        if origin and origin not in PANEL_ORIGINS | own:
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
        elif path == "/profile":
            if not self.authorized():
                return self.reply(401, {"error": "密钥不对"})
            self.reply(200, {"profile": load_profile(), "defaults": install_defaults()})
        elif path == "/update":
            if not self.authorized():
                return self.reply(401, {"error": "密钥不对"})
            self.reply(200, update_view() if update_state["checked"] else check_update())
        elif path == "/health":
            self.reply(200, {"ok": True, "rules": bool(TARGETS), "traffic": True, "apply": True, "client": True,
                             "singbox": singbox_running(), "safe_mode": safe_mode(), "server_fallback": server_fallback(),
                             "server_checked": guard_state["checked"], "version": current_version(),
                             "update": {"latest": update_state["latest"], "available": update_view()["available"]}})
        elif path == "/":
            body = STATUS_PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)
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

    def body(self, limit=MAX_BODY):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise BadConfig("内容太大")
        return json.loads(self.rfile.read(n) or b"{}")

    def client_call(self, fn):
        """面板的客户端功能（设置、订阅、安装面板生成的配置）：和 /rules 一样只认面板页面 + 密钥。"""
        if not SECRET or not self.authorized():
            return self.reply(401, {"error": "密钥不对"})
        try:
            self.reply(200, fn(self.body()))
        except BadConfig as e:
            self.reply(400, {"error": str(e)})
        except (ValueError, OSError, subprocess.SubprocessError) as e:
            self.reply(500, {"error": f"出错了：{e}"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/apply" and self.headers.get("Origin"):
            self.client_call(apply_inline)
        elif path == "/apply":
            # 本机脚本（update.sh）：交来生成目录的路径；必须有密钥
            if not SECRET or self.headers.get("Authorization") != "Bearer " + SECRET:
                return self.reply(401, {"error": "密钥不对"})
            try:
                self.reply(200, apply_update(self.body(1 << 16).get("src")))
            except BadConfig as e:
                self.reply(400, {"error": str(e)})
            except (ValueError, OSError, subprocess.SubprocessError) as e:
                self.reply(500, {"error": f"更新失败：{e}"})
        elif path == "/fetch":
            self.client_call(lambda b: fetch_subscription(b.get("url")))
        elif path == "/update/check":
            self.client_call(lambda b: check_update())
        elif path == "/update/install":
            self.client_call(lambda b: install_update())
        elif path in ("/pause", "/resume"):
            if not self.authorized(own_page=True):
                return self.reply(401, {"error": "密钥不对"})
            try:
                if path == "/pause":
                    enter_safe_mode("手动暂停")
                    self.reply(200, {"ok": True})
                else:
                    self.reply(200, resume())
            except BadConfig as e:
                self.reply(400, {"error": str(e)})
        elif path == "/rules":
            self.change("add")
        elif path == "/rules/delete":
            self.change("delete")
        else:
            self.send_error(404)

    def do_PUT(self):
        if self.path.split("?")[0] == "/rules":
            self.change("replace")
        elif self.path.split("?")[0] == "/profile":
            self.client_call(save_profile)
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
if os.path.exists(CONFIG + ".prev"):
    os.chmod(CONFIG + ".prev", 0o600)  # 旧版留下的备份是 644
if TARGETS:
    with rules_lock:
        apply_rules(load_rules())  # 启动时按 user-rules.json 重写一遍规则文件（升级后新增的目标也会有文件）
if safe_mode() and singbox_running():
    # 开机时 launchd 会照常启动 sing-box；还在安全模式就再停掉，直到手动重新启用或更新配置
    subprocess.run(["launchctl", "bootout", f"system/{args.label}"], capture_output=True, timeout=60)
    log("安全模式：保持 sing-box 停止")
threading.Thread(target=collect, daemon=True).start()
threading.Thread(target=update_checker, daemon=True).start()
if args.label:
    threading.Thread(target=watchdog, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
