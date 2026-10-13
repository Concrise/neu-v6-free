#!/usr/bin/env python3
"""把妙妙屋「自用东大版」订阅（mihomo 格式）转成 sing-box 配置 + 面板分组说明。

东大校园网三层分流：
  ① 国内域名解析出 v6（经 v6 DNS 查询）→ ③ 国内·有IPv6（默认本机 v6 直连）
  ② 其余国内                          → ④ 国内·仅IPv4（默认 隧道直出，即经 ① 免流隧道从入口服务器出 v4）
  ③ 国外                              → ② 国外出口（默认 [免流] 美国家宽 Sixtynet）
业务分组与优先级见 groups.py。另有独立入口 hk（10809）固定走 HK家宽。

用法：python3 gen.py [-o out/sing-box.json] [--no-tun] [--rules-dir DIR] [--panel-dir DIR]
"""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.parse

import yaml

from groups import (ABROAD, AUTO, BASE_GROUPS, CN4, CN6, D_ANY, D_V4, D_V6, D_V6PREF, DISPLAY_NAMES, ENTRY, FREE,
                    INFO_PAGES, OPTION_NOTES, ORACLE_EXIT, SERVICE_GROUPS, V4)

ROOT = pathlib.Path(__file__).resolve().parent
INSTALL_ETC = "/usr/local/etc/neu-v6-router"

DEFAULTS = {
    "listen": "127.0.0.1",
    "main_port": 10808,
    "hk_port": 10809,
    "clash_api": "127.0.0.1:9090",
    # 免流隧道入口：订阅里这些服务器的 v4 节点会各派生一个 v6 入口（同端口同凭据，服务端需监听 ::）
    "entry_servers": {
        "203.0.113.20": {"v6": "2001:db8::2", "label": "Netcup 德国"},
    },
    "default_landing": "🇺🇸 家宽Sixtynet",
    "cn_dns_v6": "2400:3200::1",  # 国内 CDN 只对 v6 来源的查询返回 AAAA
    "cn_dns_v4": "223.5.5.5",
    "direct_domains": ["neu.edu.cn"],
    # 不作为落地的节点：Oracle 的 v4 节点与「隧道直出」重复且计费；订阅里现成的 -v6 节点由 entry_servers 取代
    "exclude_nodes_regex": r"Oracle-SJ-ARM(-v6)?$",
    "tun": True,
    "rules_dir": f"{INSTALL_ETC}/rules",  # 安装后的位置（install/update 会拷过去）
    "panel_dir": f"{INSTALL_ETC}/panel",
    "rule_set_base": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo",
}
SKIP_TYPES = {"direct", "reject", "dns"}
SUB_GROUP_ALIAS = {"🆓 免流入口": ENTRY}
ENTRY_PROTOCOLS = {"hysteria2": "Hysteria2", "tuic": "TUIC", "vless": "Reality", "anytls": "AnyTLS"}  # 顺序即排序
DELAY_URL = "https://www.gstatic.com/generate_204"  # 订阅里 dialer-proxy 的组名 → 本配置的组名


def tls_block(p, *, sni_key="servername", reality=False):
    tls = {"enabled": True}
    sni = p.get(sni_key) or p.get("sni") or p.get("servername")
    if sni:
        tls["server_name"] = sni
    if p.get("skip-cert-verify"):
        tls["insecure"] = True
    if p.get("alpn"):
        tls["alpn"] = p["alpn"]
    if p.get("client-fingerprint"):
        tls["utls"] = {"enabled": True, "fingerprint": p["client-fingerprint"]}
    if reality:
        ro = p["reality-opts"]
        tls["reality"] = {"enabled": True, "public_key": ro["public-key"], "short_id": ro.get("short-id", "")}
        tls.pop("insecure", None)
    return tls


def ws_transport(p):
    wo = p.get("ws-opts") or {}
    t = {"type": "ws", "path": wo.get("path", "/")}
    if wo.get("headers"):
        t["headers"] = wo["headers"]
    return t


def convert(p):
    """mihomo proxy → sing-box outbound；不支持的类型返回 None。"""
    t = p["type"]
    o = {"type": t, "tag": p["name"], "server": p["server"], "server_port": int(p["port"])}
    if t == "vless":
        o["uuid"] = p["uuid"]
        if p.get("flow"):
            o["flow"] = p["flow"]
        if p.get("tls"):
            o["tls"] = tls_block(p, reality="reality-opts" in p)
        if p.get("network") == "ws":
            o["transport"] = ws_transport(p)
        o["packet_encoding"] = "xudp"
    elif t == "vmess":
        o.update(uuid=p["uuid"], security=p.get("cipher", "auto"), alter_id=int(p.get("alterId", 0)))
        if p.get("tls"):
            o["tls"] = tls_block(p)
        if p.get("network") == "ws":
            o["transport"] = ws_transport(p)
    elif t == "hysteria2":
        o["password"] = p["password"]
        o["tls"] = tls_block(p, sni_key="sni")
    elif t == "tuic":
        o.update(uuid=p["uuid"], password=p["password"],
                 congestion_control=p.get("congestion-controller", "bbr"),
                 udp_relay_mode=p.get("udp-relay-mode", "native"))
        o["tls"] = tls_block(p, sni_key="sni")
    elif t == "anytls":
        o["password"] = p["password"]
        o["tls"] = tls_block(p, sni_key="sni")
    else:
        return None
    return o


def rs_tag(ref):
    """'geosite/category-ai-!cn' → 'geosite-category-ai-!cn'"""
    return ref.replace("/", "-")


def all_rule_sets():
    refs = ["geosite/cn", "geoip/cn"]
    for _, _, match, _, _ in SERVICE_GROUPS:
        refs += [r for r in match.get("rule_sets", []) if r not in refs]
    return refs


def download_rule_sets(base, dest):
    """下载规则集到 dest；某个下载失败时保留旧文件，没有旧文件则报错退出。"""
    dest.mkdir(parents=True, exist_ok=True)
    for ref in all_rule_sets():
        target = dest / f"{rs_tag(ref)}.srs"
        tmp = target.with_suffix(".tmp")
        url = f"{base}/{urllib.parse.quote(ref)}.srs"
        r = subprocess.run(["curl", "-fsSL", "-m", "60", "--noproxy", "*", "-o", str(tmp), url])
        if r.returncode == 0 and tmp.stat().st_size > 0:
            tmp.replace(target)
        else:
            tmp.unlink(missing_ok=True)
            if not target.exists():
                sys.exit(f"规则集下载失败且无旧文件: {ref} ({url})")
            print(f"规则集 {ref} 下载失败，沿用旧文件", file=sys.stderr)


def selector(tag, members, default):
    assert default in members, (tag, default)
    return {"type": "selector", "tag": tag, "outbounds": members, "default": default,
            "interrupt_exist_connections": True}


def service_rule(match, outbound):
    if "process" in match:
        return {"process_path_regex": match["process"], "outbound": outbound}
    return {"rule_set": [rs_tag(r) for r in match["rule_sets"]], "outbound": outbound}


def build(settings, sub):
    s = {**DEFAULTS, **settings}
    servers = s["entry_servers"]

    raw = {}  # 订阅名 → sing-box outbound（tag 暂为订阅名）
    entry_nodes = []  # (服务器序, 协议序, outbound)
    for p in sub["proxies"]:
        if p["type"] in SKIP_TYPES:
            continue
        o = convert(p)
        if o is None:
            print(f"跳过不支持的节点: {p['name']} ({p['type']})", file=sys.stderr)
            continue
        srv = servers.get(p["server"])
        if srv and p["type"] in ENTRY_PROTOCOLS and (p["type"] != "vless" or "reality-opts" in p):
            e = json.loads(json.dumps(o))  # 派生 v6 入口：同端口同凭据，只换地址
            e.update(server=srv["v6"], tag=f"{srv['label']} v6 · {ENTRY_PROTOCOLS[p['type']]}")
            entry_nodes.append((list(servers).index(p["server"]), list(ENTRY_PROTOCOLS).index(p["type"]), e))
        if re.search(s["exclude_nodes_regex"], p["name"]):
            continue
        if p.get("dialer-proxy"):
            o["detour"] = SUB_GROUP_ALIAS.get(p["dialer-proxy"], p["dialer-proxy"])
        raw[p["name"]] = o
    entry_nodes = [e for *_, e in sorted(entry_nodes, key=lambda x: x[:2])]
    entry_tags = [e["tag"] for e in entry_nodes]
    if not entry_tags or s["default_landing"] not in raw:
        sys.exit(f"订阅里缺少入口节点或默认落地: entries={entry_tags} landing={s['default_landing']}")

    def via_entry(name, seen=()):
        d = raw[name].get("detour")
        return d == ENTRY or (d in raw and d not in seen and via_entry(d, seen + (name,)))

    # 统一命名：第一跳走 ① 的加 [免流]，其余（本机直连）加 [v4直连]
    disp = lambda n: DISPLAY_NAMES.get(n, n)  # noqa: E731
    tag = {n: (FREE if via_entry(n) else V4) + disp(n) for n in raw}
    nodes = []
    for n, o in raw.items():
        o["tag"] = tag[n]
        if o.get("detour") in tag:
            o["detour"] = tag[o["detour"]]
        nodes.append(o)
    landings = [tag[n] for n in raw]
    # 第一跳直接是 ① 的落地，再各生成一个本机 v4 直连的副本
    v4_nodes = [dict(raw[n], tag=V4 + disp(n)) for n in raw if raw[n].get("detour") == ENTRY]
    for n in v4_nodes:
        n.pop("detour")
    v4_landings = [n["tag"] for n in v4_nodes]
    own_servers = [f"{ip}/32" for ip in servers] + [f"{v['v6']}/128" for v in servers.values()]

    hk = dict(s["hk_outbound"])
    service_members = [ABROAD, ORACLE_EXIT, CN6, CN4, D_V6PREF, D_V4, *landings, *v4_landings]
    outbounds = [
        selector(ENTRY, [AUTO, *entry_tags, D_ANY], AUTO),
        {"type": "urltest", "tag": AUTO, "outbounds": entry_tags, "url": DELAY_URL,
         "interval": "3m", "tolerance": 50, "idle_timeout": "30m"},
        selector(ABROAD, landings + v4_landings, tag[s["default_landing"]]),
        selector(CN6, [D_V6, D_V6PREF, ORACLE_EXIT], D_V6),
        selector(CN4, [ORACLE_EXIT, D_V4, D_V6PREF], ORACLE_EXIT),
        selector(ORACLE_EXIT, [ENTRY], ENTRY),
        *[selector(name, service_members, default) for name, _, _, default, _ in SERVICE_GROUPS],
        *entry_nodes,
        *nodes,
        *v4_nodes,
        hk,
        {"type": "direct", "tag": D_ANY},
        # direct 收到的仍是域名，会用 default_domain_resolver（v4 DNS）重解析；
        # 所以按 IP 版本区分的直连都要自带 domain_resolver
        {"type": "direct", "tag": D_V6, "domain_resolver": {"server": "cn6", "strategy": "ipv6_only"}},
        {"type": "direct", "tag": D_V4, "domain_resolver": {"server": "cn4", "strategy": "ipv4_only"}},
        {"type": "direct", "tag": D_V6PREF, "domain_resolver": {"server": "cn6", "strategy": "prefer_ipv6"}},
    ]

    rule_sets = [{"type": "local", "tag": rs_tag(r), "format": "binary",
                  "path": f"{s['rules_dir']}/{rs_tag(r)}.srs"} for r in all_rule_sets()]
    v6_any = {"ip_cidr": ["::/0"]}
    services = lambda where: [service_rule(m, name) for name, _, m, _, w in SERVICE_GROUPS if w == where]  # noqa: E731

    # 国内站点分组（cn_v4）的规则集不一定都在 geosite-cn 里，一起参与 v6 解析与直连判断
    cn_sets = ["geosite-cn", *(rs_tag(r) for _, _, m, _, w in SERVICE_GROUPS if w == "cn_v4" for r in m["rule_sets"])]

    inbounds = [
        {"type": "mixed", "tag": "main", "listen": s["listen"], "listen_port": s["main_port"]},
        {"type": "mixed", "tag": "hk", "listen": s["listen"], "listen_port": s["hk_port"]},
    ]
    if s["tun"]:
        # v4/v6 都接管：否则国外站的 v6 会绕过代理从校园网直出
        inbounds.append({"type": "tun", "tag": "tun", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                         "auto_route": True, "strict_route": True, "stack": "mixed"})

    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": [
                {"type": "udp", "tag": "cn6", "server": s["cn_dns_v6"]},
                {"type": "udp", "tag": "cn4", "server": s["cn_dns_v4"]},
                {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": ABROAD},
                {"type": "fakeip", "tag": "fakeip", "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"},
            ],
            "rules": [
                {"domain_suffix": s["direct_domains"], "server": "cn4"},
                {"rule_set": cn_sets, "server": "cn6"},
                # 国外域名给 fakeip，连接时由代理端解析，省去本地查询绕国外的延迟
                {"query_type": ["A", "AAAA"], "server": "fakeip"},
            ],
            "final": "remote",
            "independent_cache": True,
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rule_set": rule_sets,
            "rules": [
                {"inbound": ["hk"], "outbound": hk["tag"]},
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": True, "outbound": D_ANY},
                # 自己的服务器（SSH、面板等）本机直连，不绕去落地
                {"ip_cidr": own_servers, "outbound": D_ANY},
                {"domain_suffix": s["direct_domains"], "outbound": D_ANY},
                # 按进程的分组（豆包、微信）最优先：整个 App 一起决定，不拆
                *[r for r in services("before_cn") if "process_path_regex" in r],
                # 总原则：国内资源只要有 v6 地址就 v6 直连（免费且最快），排在所有按站点分的分组前面
                {"rule_set": cn_sets, "action": "resolve", "server": "cn6", "strategy": "prefer_ipv6"},
                {"type": "logical", "mode": "and", "rules": [{"rule_set": cn_sets}, v6_any], "outbound": CN6},
                {"type": "logical", "mode": "and", "rules": [{"rule_set": ["geoip-cn"]}, v6_any], "outbound": CN6},
                *[r for r in services("before_cn") if "process_path_regex" not in r],
                # 下面都是只有 v4 的连接
                *services("cn_v4"),
                {"rule_set": ["geosite-cn"], "outbound": CN4},
                *services("after_cn"),
                # 直接访问国内 v4 IP 的连接（v6 的已在前面直连）
                {"rule_set": ["geoip-cn"], "outbound": CN4},
            ],
            "final": ABROAD,
            "default_domain_resolver": "cn4",
            # 出站绑定物理网卡，避免自身连接被 TUN 抓回形成环路
            "auto_detect_interface": True,
            # 识别发起连接的进程：豆包/微信分流 + 面板里能看到是哪个 App
            "find_process": True,
        },
        "experimental": {
            "cache_file": {"enabled": True, "path": "neu-v6-router.cache.db", "store_fakeip": True},
            "clash_api": {
                "external_controller": s["clash_api"],
                "secret": s["clash_api_secret"],
                "external_ui": s["panel_dir"],
                "default_mode": "rule",
            },
        },
    }


def node_notes(cfg, entries):
    """按节点的实际前置链给出说明：是否经免流入口、是否计费。"""
    by_tag = {o["tag"]: o for o in cfg["outbounds"]}

    def via_entry(tag, seen=()):
        d = by_tag.get(tag, {}).get("detour")
        return d == ENTRY or (d is not None and d not in seen and via_entry(d, seen + (tag,)))

    notes = {}
    for o in cfg["outbounds"]:
        t = o["tag"]
        if o["type"] in ("selector", "direct", "urltest") or t in OPTION_NOTES or t == "HK家宽":
            continue
        if t in entries:
            notes[t] = "通过校园网 IPv6 连到这台服务器（隧道入口，免费）"
        elif via_entry(t):
            hop = o["detour"]
            notes[t] = "先走 ① 免流隧道，再到此落地（免费）" if hop == ENTRY else \
                f"先走 ① 免流隧道，经「{hop}」再到此落地（免费）"
        else:
            notes[t] = "本机直接用 IPv4 连到此落地（不走隧道，延迟低、计费）"
    return notes


def panel_meta(cfg, entries):
    """面板用的分组顺序与说明。"""
    return {
        "node_notes": node_notes(cfg, entries),
        "groups": [{"name": n, "desc": d, "kind": "base"} for n, d in BASE_GROUPS]
        + [{"name": n, "desc": d, "kind": "service", "default": dft} for n, d, _, dft, _ in SERVICE_GROUPS],
        "info": [{"name": n, "desc": d} for n, d in INFO_PAGES],
        "notes": OPTION_NOTES,
        "free_prefix": FREE,
        "v4_prefix": V4,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--config", default=ROOT / "config.local.yaml")
    ap.add_argument("-o", "--out", default=ROOT / "out" / "sing-box.json")
    ap.add_argument("--no-tun", action="store_true", help="不生成 TUN 入口（仅系统代理）")
    ap.add_argument("--rules-dir", help="配置里引用的规则集目录（测试用，默认安装位置）")
    ap.add_argument("--panel-dir", help="配置里引用的面板目录（测试用，默认安装位置）")
    a = ap.parse_args()
    settings = yaml.safe_load(open(a.config, encoding="utf-8"))
    if a.no_tun:
        settings["tun"] = False
    if a.rules_dir:
        settings["rules_dir"] = a.rules_dir
    if a.panel_dir:
        settings["panel_dir"] = a.panel_dir
    download_rule_sets(settings.get("rule_set_base", DEFAULTS["rule_set_base"]), ROOT / "out" / "rules")
    # 用系统 curl（走系统证书库）直连拉订阅；python.org 版 Python 默认没有根证书
    raw = subprocess.run(["curl", "-fsS", "-m", "20", "--noproxy", "*", "-A", "clash.meta",
                          settings["subscription_url"]], check=True, capture_output=True).stdout
    cfg = build(settings, yaml.safe_load(raw))

    out = pathlib.Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    out.chmod(0o600)
    panel = ROOT / "out" / "panel"
    panel.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "panel" / "index.html", panel / "index.html")
    entries = [t for t in next(o for o in cfg["outbounds"] if o["tag"] == ENTRY)["outbounds"] if t not in (AUTO, D_ANY)]
    (panel / "groups.json").write_text(json.dumps(panel_meta(cfg, entries), ensure_ascii=False, indent=1),
                                       encoding="utf-8")
    sel = {o["tag"]: o["default"] for o in cfg["outbounds"] if o["type"] == "selector"}
    print(f"已生成 {out}（{len(cfg['outbounds'])} 个出站、{len(sel)} 个分组）")


if __name__ == "__main__":
    main()
