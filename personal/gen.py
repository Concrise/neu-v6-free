#!/usr/bin/env python3
"""把妙妙屋「自用东大版」订阅（mihomo 格式）转成 sing-box 配置，实现东大校园网三层分流：

  ① 国内域名解析出 v6（经 v6 DNS 查询）→ 国内v6（默认直连）
  ② 其余国内                          → 国内v4（默认 免流入口，即经 Oracle v6 出 v4）
  ③ 国外                              → 国外（默认 家宽Sixtynet，挂在 免流入口 上）

另有独立入口 hk（默认 10809）全部走 HK家宽，供指纹浏览器使用。

用法：python3 gen.py [-o out/sing-box.json]
"""
import argparse
import json
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent

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
    "tun": True,
    "rule_set_base": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo",
    "ui_url": "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip",
}

ENTRY, CN6, CN4, ABROAD = "免流入口", "国内v6", "国内v4", "国外"
SKIP_TYPES = {"direct", "reject", "dns"}


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


def selector(tag, members, default):
    return {"type": "selector", "tag": tag, "outbounds": members, "default": default,
            "interrupt_exist_connections": True}


def build(settings, sub):
    s = {**DEFAULTS, **settings}
    entries = s["entries"]
    group_alias = {"🆓 免流入口": ENTRY}

    nodes, landings = [], []
    for p in sub["proxies"]:
        if p["type"] in SKIP_TYPES:
            continue
        o = convert(p)
        if o is None:
            print(f"跳过不支持的节点: {p['name']} ({p['type']})", file=sys.stderr)
            continue
        if p.get("dialer-proxy"):
            o["detour"] = group_alias.get(p["dialer-proxy"], p["dialer-proxy"])
        nodes.append(o)
        if p["name"] not in entries:
            landings.append(p["name"])
    missing = [e for e in entries + [s["default_landing"]] if e not in {n["tag"] for n in nodes}]
    if missing:
        sys.exit(f"订阅里缺少节点: {missing}")

    hk = dict(s["hk_outbound"])
    outbounds = [
        selector(ENTRY, entries + ["direct"], entries[0]),
        selector(CN6, ["direct-v6", "direct", ENTRY], "direct-v6"),
        selector(CN4, [ENTRY, "direct"], ENTRY),
        selector(ABROAD, landings, s["default_landing"]),
        *nodes,
        hk,
        {"type": "direct", "tag": "direct"},
        # direct 收到的仍是域名，会用 default_domain_resolver（v4 DNS）重解析并拨 v4；
        # 国内v6 必须用这个只经 v6 DNS 解析、只拨 v6 的出口
        {"type": "direct", "tag": "direct-v6", "domain_resolver": {"server": "cn6", "strategy": "ipv6_only"}},
    ]

    rs = lambda tag, kind, name: {  # noqa: E731
        "type": "remote", "tag": tag, "format": "binary",
        "url": f"{s['rule_set_base']}/{kind}/{name}.srs",
        "download_detour": ABROAD, "update_interval": "7d"}
    v6_any = {"ip_cidr": ["::/0"]}

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
            "rule_set": [rs("geosite-cn", "geosite", "cn"), rs("geoip-cn", "geoip", "cn")],
            "rules": [
                {"inbound": ["hk"], "outbound": hk["tag"]},
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": True, "outbound": "direct"},
                {"domain_suffix": s["direct_domains"], "outbound": "direct"},
                # ① / ②：国内域名先经 v6 DNS 解析，有 v6 地址才直连
                {"rule_set": ["geosite-cn"], "action": "resolve", "server": "cn6", "strategy": "prefer_ipv6"},
                {"type": "logical", "mode": "and", "rules": [{"rule_set": ["geosite-cn"]}, v6_any], "outbound": CN6},
                {"rule_set": ["geosite-cn"], "outbound": CN4},
                # 直接访问国内 IP 的连接
                {"type": "logical", "mode": "and", "rules": [{"rule_set": ["geoip-cn"]}, v6_any], "outbound": CN6},
                {"rule_set": ["geoip-cn"], "outbound": CN4},
            ],
            "final": ABROAD,
            "default_domain_resolver": "cn4",
            # 出站绑定物理网卡，避免自身连接被 TUN 抓回形成环路
            "auto_detect_interface": True,
        },
        "experimental": {
            "cache_file": {"enabled": True, "path": "neu-v6-router.cache.db", "store_fakeip": True},
            "clash_api": {
                "external_controller": s["clash_api"],
                "secret": s["clash_api_secret"],
                "external_ui": "ui",
                "external_ui_download_url": s["ui_url"],
                "external_ui_download_detour": ABROAD,
                "default_mode": "rule",
            },
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--config", default=ROOT / "config.local.yaml")
    ap.add_argument("-o", "--out", default=ROOT / "out" / "sing-box.json")
    ap.add_argument("--no-tun", action="store_true", help="不生成 TUN 入口（仅系统代理）")
    a = ap.parse_args()
    settings = yaml.safe_load(open(a.config, encoding="utf-8"))
    if a.no_tun:
        settings["tun"] = False
    # 用系统 curl（走系统证书库）直连拉订阅；python.org 版 Python 默认没有根证书
    raw = subprocess.run(["curl", "-fsS", "-m", "20", "--noproxy", "*", "-A", "clash.meta",
                          settings["subscription_url"]], check=True, capture_output=True).stdout
    sub = yaml.safe_load(raw)
    cfg = build(settings, sub)
    out = pathlib.Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    out.chmod(0o600)
    sel = {o["tag"]: o["default"] for o in cfg["outbounds"] if o["type"] == "selector"}
    print(f"已生成 {out}（{len(cfg['outbounds'])} 个出站）默认选择: {sel}")


if __name__ == "__main__":
    main()
