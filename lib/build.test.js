import test from "node:test";
import assert from "node:assert/strict";
import { build, CHINA_MAX_REF, ruleSetRefs, ruleSetUrl } from "./build.js";
import { CN4, D_V4, D_V6 } from "./groups.js";

test("国内域名先探测 IPv6，再按所选出口解析 IPv4", () => {
  for (const tunnel of [false, true]) {
    const settings = tunnel ? { entry_servers: { "192.0.2.10": { v6: "2001:db8::10", label: "演示" } } } : {};
    const nodes = tunnel ? [{ name: "演示", type: "hysteria2", server: "192.0.2.10", port: 443, password: "demo" }] : [];
    const { config } = build(settings, nodes, "windows");
    const rules = config.route.rules;
    const probe = rules.findIndex((r) => r.action === "resolve" && r.strategy === "prefer_ipv6");
    const only6 = rules.findIndex((r) => r.action === "resolve" && r.strategy === "ipv6_only");
    const direct6 = rules.findIndex((r) => r.outbound === D_V6 && r.rules);
    const only4 = rules.findIndex((r) => r.action === "resolve" && r.strategy === "ipv4_only");
    const fallback = rules.findIndex((r) => r.outbound && r.rule_set?.includes(CHINA_MAX_REF));
    assert.ok(probe >= 0 && probe < only6 && only6 < direct6 && direct6 < only4 && only4 < fallback);
    assert.ok(rules[probe].rule_set.includes("geosite-bilibili"));
    assert.ok(rules[probe].rule_set.includes(CHINA_MAX_REF));
    if (tunnel) assert.ok(config.dns.rules.find((r) => r.rule_set?.includes(CHINA_MAX_REF)).rule_set.includes("geosite-bilibili"));
    assert.deepEqual(rules[only6].rules, rules[direct6].rules);
    assert.ok(rules[direct6].rules.some((r) => r.invert && r.ip_cidr?.length));
    assert.equal(rules[only4].server, tunnel ? "cn-fallback" : "cn6");
    if (tunnel) assert.equal(config.dns.servers.find((s) => s.tag === "cn-fallback").detour, CN4);
    assert.equal(rules.find((r) => r.rule_set?.includes("geoip-cn") && r.outbound === D_V6).ip_version, 6);
  }
});

test("国内主名单改用 ChinaMaxNoIP，桌面本地和手机远程指向同一规则", () => {
  assert.ok(!ruleSetRefs().includes("geosite/cn"));
  for (const platform of ["mac", "windows", "android", "ios"]) {
    const { config } = build({}, [], platform);
    const set = config.route.rule_set.find((r) => r.tag === CHINA_MAX_REF);
    assert.equal(set.format, "binary");
    assert.ok(platform === "mac" || platform === "windows" ? set.path.endsWith("china-max-no-ip.srs") : set.url === ruleSetUrl("unused", CHINA_MAX_REF));
  }
});

test("ping 在按 App 分流和代理之前就直连：查不出进程，代理也不支持 ICMP（否则 TUN 回假应答）", () => {
  const settings = { entry_servers: { "192.0.2.10": { v6: "2001:db8::10", label: "演示" } } };
  const nodes = [{ name: "演示", type: "hysteria2", server: "192.0.2.10", port: 443, password: "demo" }];
  const { config } = build(settings, nodes, "windows");
  const rules = config.route.rules;
  const icmp = rules.findIndex((r) => r.network?.includes("icmp"));
  assert.ok(icmp >= 0 && icmp < rules.findIndex((r) => r.process_path_regex));
  assert.ok(icmp < rules.findIndex((r) => r.outbound === CN4));
  assert.ok(config.outbounds.find((o) => o.tag === rules[icmp].outbound).type === "direct");
});

test("英雄联盟规则接住自带的迅游网络助手：它装在 Program Files (x86)，不在游戏目录", () => {
  const { config } = build({}, [], "windows");
  const lol = config.route.rules.find((r) => r.outbound === "⚔️ 英雄联盟" && r.process_path_regex);
  // sing-box 用 Go 正则，开头的 (?i) 换成 JS 的 i 标志
  const hit = (p) => lol.process_path_regex.some((re) => new RegExp(re.replace(/^\(\?i\)/, ""), "i").test(p));
  assert.ok(hit(String.raw`C:\Program Files (x86)\yxq_nethelper\XY_YXQ_Nethelper.exe`));
  assert.ok(hit(String.raw`D:\WeGameApps\英雄联盟\LeagueClient\NetworkAssist\xunyou\yxqxunyou.exe`));
  assert.ok(!hit(String.raw`C:\Program Files\Tencent\QQNT\QQ.exe`));
});

test("英雄联盟默认直连 v4：v6 优先时 Riot 的海外 CDN 走校园网 v6 常被掐断，启动慢", () => {
  const settings = { entry_servers: { "192.0.2.10": { v6: "2001:db8::10", label: "演示" } } };
  const nodes = [{ name: "演示", type: "hysteria2", server: "192.0.2.10", port: 443, password: "demo" }];
  for (const [s, n] of [[{}, []], [settings, nodes]]) {
    const lol = build(s, n, "windows").config.outbounds.find((o) => o.tag === "⚔️ 英雄联盟");
    assert.equal(lol.default, D_V4);
  }
});
