// Shadowrocket 的 RULE-SET 与 DOMAIN-SET 互补，必须一起转换。
export const CHINA_MAX_SOURCES = [
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Shadowrocket/ChinaMaxNoIP/ChinaMaxNoIP.list",
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Shadowrocket/ChinaMaxNoIP/ChinaMaxNoIP_Domain.list",
];

export function convertChinaMax(ruleText, domainText) {
  const sets = { domain: new Set(), domain_suffix: new Set(), domain_keyword: new Set() };
  const counts = { domain: 0, domain_suffix: 0, domain_keyword: 0, user_agent: 0 };
  const lines = (text) => String(text).replace(/^\uFEFF/, "").split(/\r?\n/).map((s) => s.trim()).filter((s) => s && !s.startsWith("#"));
  const add = (field, value) => {
    let v = value.trim().toLowerCase();
    if (!v || /[\s,/:@?#*]/.test(v)) throw new Error("ChinaMaxNoIP 含无效域名条目");
    if (field !== "domain_keyword") {
      v = new URL("http://" + v).hostname;
      if (v.length > 253) throw new Error("ChinaMaxNoIP 域名过长");
    }
    sets[field].add(v);
    counts[field]++;
  };
  for (const line of lines(ruleText)) {
    const [type, value, ...extra] = line.split(",");
    if (!value || extra.length) throw new Error("ChinaMaxNoIP RULE-SET 格式不对");
    const field = { DOMAIN: "domain", "DOMAIN-SUFFIX": "domain_suffix", "DOMAIN-KEYWORD": "domain_keyword" }[type];
    if (field) add(field, value);
    else if (type === "USER-AGENT") counts.user_agent++;
    else throw new Error("ChinaMaxNoIP 含不支持的规则类型：" + type);
  }
  for (const line of lines(domainText)) add(line.startsWith(".") ? "domain_suffix" : "domain", line.replace(/^\./, ""));
  // 上游头部的计数也要吻合，截断下载不能变成一份貌似有效、实际缺规则的名单。
  for (const [field, type] of Object.entries({ domain: "DOMAIN", domain_suffix: "DOMAIN-SUFFIX", domain_keyword: "DOMAIN-KEYWORD", user_agent: "USER-AGENT" })) {
    const declared = ruleText.match(new RegExp("^# " + type + ": (\\d+)\\s*$", "m"));
    if (declared && Number(declared[1]) !== counts[field]) throw new Error("ChinaMaxNoIP 两份名单不完整或版本不一致：" + type);
  }
  if (!counts.domain && !counts.domain_suffix) throw new Error("ChinaMaxNoIP 域名名单为空");
  return { ruleSet: { version: 2, rules: [Object.fromEntries(Object.entries(sets).filter(([, s]) => s.size).map(([k, s]) => [k, [...s].sort()]))] }, counts };
}
