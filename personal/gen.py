#!/usr/bin/env python3
"""把妙妙屋「自用东大版」订阅（mihomo 格式）转成 sing-box 配置 + 面板分组说明。

东大校园网三层分流：
  ① 国内域名解析出 v6（经 v6 DNS 查询）→ 🇨🇳 国内v6（默认直连）
  ② 其余国内                          → 🇨🇳 国内v4（默认 免流入口，即经 Oracle v6 出 v4）
  ③ 国外                              → 🌍 国外（默认 家宽Sixtynet，挂在 免流入口 上）
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

from groups import (ABROAD, BASE_GROUPS, CN4, CN6, D_ANY, D_V4, D_V6, D_V6PREF, ENTRY, INFO_PAGES,
                    OPTION_NOTES, SERVICE_GROUPS, V4_SUFFIX)

ROOT = pathlib.Path(__file__).resolve().parent
INSTALL_ETC = "/usr/local/etc/neu-v6-router"

DEFAULTS = {
    "listen": "127.0.0.1",
    "main_port": 10808,
    "hk_port": 10809,
    "clash_api": "127.0.0.1:9090",
    "entries": ["🇺🇸[hy2]Oracle-SJ-ARM-v6", "🇺🇸[vless]Oracle-SJ-ARM-v6"],
    "default_landing": "🇺🇸 家宽Sixtynet",
    "cn_dns_v6": "2400:3200::1",  # 国内 CDN 只对 v6 来源的查询返回 AAAA
    "cn_dns_v4": "223.5.5.5",
    "direct_domains": ["neu.edu.cn"],
    # 不作为落地的节点：Oracle 的 v4 节点与「免流入口」（Oracle 出口，免费）重复且计费
    "exclude_nodes_regex": r"Oracle-SJ-ARM$",
    "tun": True,
    "rules_dir": f"{INSTALL_ETC}/rules",  # 安装后的位置（install/update 会拷过去）
    "panel_dir": f"{INSTALL_ETC}/panel",
    "rule_set_base": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo",
}
SKIP_TYPES = {"direct", "reject", "dns"}
SUB_GROUP_ALIAS = {"🆓 免流入口": ENTRY}  # 订阅里 dialer-proxy 的组名 → 本配置的组名


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
    entries = s["entries"]

    nodes, landings = [], []
    for p in sub["proxies"]:
        if p["type"] in SKIP_TYPES or re.search(s["exclude_nodes_regex"], p["name"]):
            continue
        o = convert(p)
        if o is None:
            print(f"跳过不支持的节点: {p['name']} ({p['type']})", file=sys.stderr)
            continue
        if p.get("dialer-proxy"):
            o["detour"] = SUB_GROUP_ALIAS.get(p["dialer-proxy"], p["dialer-proxy"])
        nodes.append(o)
        if p["name"] not in entries:
            landings.append(p["name"])
    # 挂在免流入口上的落地，各生成一个去掉前置的 v4 直连副本
    v4_nodes = [dict(n, tag=n["tag"] + V4_SUFFIX) for n in nodes if n.get("detour") == ENTRY]
    for n in v4_nodes:
        n.pop("detour")
    v4_landings = [n["tag"] for n in v4_nodes]
    known = {n["tag"] for n in nodes + v4_nodes}
    missing = [e for e in entries + [s["default_landing"]] if e not in known]
    if missing:
        sys.exit(f"订阅里缺少节点: {missing}")

    hk = dict(s["hk_outbound"])
    service_members = [ABROAD, ENTRY, CN6, CN4, D_V6PREF, D_V4, *landings, *v4_landings]
    outbounds = [
        selector(ENTRY, entries + [D_ANY], entries[0]),
        selector(ABROAD, landings + v4_landings, s["default_landing"]),
        selector(CN6, [D_V6, D_V6PREF, ENTRY], D_V6),
        selector(CN4, [ENTRY, D_V4, D_V6PREF], ENTRY),
        *[selector(name, service_members, default) for name, _, _, default, _ in SERVICE_GROUPS],
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
                {"rule_set": ["geosite-cn"], "server": "cn6"},
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
                {"domain_suffix": s["direct_domains"], "outbound": D_ANY},
                *services("before_cn"),
                # ① / ②：国内域名先经 v6 DNS 解析，有 v6 地址才直连
                {"rule_set": ["geosite-cn"], "action": "resolve", "server": "cn6", "strategy": "prefer_ipv6"},
                {"type": "logical", "mode": "and", "rules": [{"rule_set": ["geosite-cn"]}, v6_any], "outbound": CN6},
                {"rule_set": ["geosite-cn"], "outbound": CN4},
                *services("after_cn"),
                # 直接访问国内 IP 的连接
                {"type": "logical", "mode": "and", "rules": [{"rule_set": ["geoip-cn"]}, v6_any], "outbound": CN6},
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
        if o["type"] in ("selector", "direct") or t in OPTION_NOTES:
            continue
        if t in entries:
            notes[t] = "Oracle 的 v6 入口（免流第一跳）"
        elif via_entry(t):
            hop = o["detour"]
            notes[t] = "经免流入口到此落地（免费）" if hop == ENTRY else f"经「{hop}」（其前置走免流入口）到此落地（免费）"
        elif t.endswith(V4_SUFFIX):
            notes[t] = "本机 v4 直连到此落地（计费，延迟低）"
        else:
            notes[t] = "本机直连此节点（不经免流入口，计费）"
    return notes


def panel_meta(cfg, entries):
    """面板用的分组顺序与说明。"""
    return {
        "node_notes": node_notes(cfg, entries),
        "groups": [{"name": n, "desc": d, "kind": "base"} for n, d in BASE_GROUPS]
        + [{"name": n, "desc": d, "kind": "service", "default": dft} for n, d, _, dft, _ in SERVICE_GROUPS],
        "info": [{"name": n, "desc": d} for n, d in INFO_PAGES],
        "notes": OPTION_NOTES,
        "v4_suffix": V4_SUFFIX,
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
    entries = settings.get("entries", DEFAULTS["entries"])
    (panel / "groups.json").write_text(json.dumps(panel_meta(cfg, entries), ensure_ascii=False, indent=1),
                                       encoding="utf-8")
    sel = {o["tag"]: o["default"] for o in cfg["outbounds"] if o["type"] == "selector"}
    print(f"已生成 {out}（{len(cfg['outbounds'])} 个出站、{len(sel)} 个分组）")


if __name__ == "__main__":
    main()
