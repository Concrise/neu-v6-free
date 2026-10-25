import test from "node:test";
import assert from "node:assert/strict";
import { build } from "./build.js";
import { CN4, D_V6 } from "./groups.js";

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
    const fallback = rules.findIndex((r) => r.outbound && r.rule_set?.includes("geosite-cn"));
    assert.ok(probe >= 0 && probe < only6 && only6 < direct6 && direct6 < only4 && only4 < fallback);
    assert.ok(rules[probe].rule_set.includes("geosite-bilibili"));
    assert.deepEqual(rules[only6].rules, rules[direct6].rules);
    assert.ok(rules[direct6].rules.some((r) => r.invert && r.ip_cidr?.length));
    assert.equal(rules[only4].server, tunnel ? "cn-fallback" : "cn6");
    if (tunnel) assert.equal(config.dns.servers.find((s) => s.tag === "cn-fallback").detour, CN4);
    assert.equal(rules.find((r) => r.rule_set?.includes("geoip-cn") && r.outbound === D_V6).ip_version, 6);
  }
});
