import test from "node:test";
import assert from "node:assert/strict";
import { convertChinaMax } from "./china-max.js";

test("合并两份名单，保留精确域名、后缀和关键词，明确排除 USER-AGENT", () => {
  const { ruleSet, counts } = convertChinaMax("DOMAIN-SUFFIX,cn\nDOMAIN-KEYWORD,bilibili\nUSER-AGENT,*bili*", ".example.com\nEXACT.example.net\n.example.com");
  assert.deepEqual(ruleSet.rules, [{ domain: ["exact.example.net"], domain_suffix: ["cn", "example.com"], domain_keyword: ["bilibili"] }]);
  assert.equal(counts.user_agent, 1);
  assert.ok(!JSON.stringify(ruleSet).includes("DIRECT"));
  assert.throws(() => convertChinaMax("IP-CIDR,192.0.2.0/24", ".example.com"));
  assert.throws(() => convertChinaMax("# DOMAIN-SUFFIX: 2\nDOMAIN-SUFFIX,cn", ""));
});
