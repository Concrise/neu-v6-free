// 生成 sing-box 配置（浏览器与 Node 共用，纯函数，不做任何网络/文件操作）。
//
// build(settings, proxies, platform) → { config, panel }
//   settings：合并后的用户设置（见 DEFAULTS 与 config.example.yaml）
//   proxies：mihomo 格式的节点列表（订阅里的 proxies + settings.nodes）
//   platform：mac / windows / android / ios
import { convert } from "./convert.js";
import {
  ABROAD, AUTO, CN4, CN6, D_ANY, D_V4, D_V6, D_V6PREF, ENTRY, ENTRY_PROTOCOLS, FREE, SERVICE_GROUPS, TUNNEL_EXIT, V4,
  baseGroups, optionNotes,
} from "./groups.js";

export const PLATFORMS = ["mac", "windows", "android", "ios"];

export const DEFAULTS = {
  listen: "127.0.0.1",
  main_port: 10808, // mac/windows 的 mixed 代理端口（系统代理用）；手机只用 TUN
  clash_api: "127.0.0.1:9090",
  clash_api_secret: "",
  // 免流隧道入口（模式二）：节点 server（v4 地址）→ { v6, label, hy2_brutal?, landing? }。
  // 这些服务器的节点各派生一个 v6 入口（同端口同凭据，服务端需监听 ::）。为空 = 模式一（v6 优先直连）
  entry_servers: {},
  // ② 国外出口 的默认落地（节点名）；不填 = 第一个落地，没有落地时为隧道直出 / 本机直连
  default_landing: null,
  // 自有服务器的 Hysteria2 用 Brutal（按带宽发包、丢包不降速）；服务端 ignore_client_bandwidth=false 才生效。
  // 例 { up_mbps: 30, down_mbps: 100 }；null = BBR。entry_servers 里可按服务器单独覆盖
  hy2_brutal: null,
  // ① 免流隧道 默认用哪种协议的入口：hysteria2 / tuic / vless / anytls；null = 自动选择全部入口。
  // 指定协议时生成「<协议> · 自动」组，只在各服务器的该协议入口间测速
  entry_default: null,
  proto_auto_name: "{} · 自动",
  cn_dns_v6: "2400:3200::1", // 国内 CDN 只对 v6 来源的查询返回 AAAA
  cn_dns_v4: "223.5.5.5",
  direct_domains: ["neu.edu.cn"],
  // 只有 v4 的国内域名 → 同一 CDN 上有 AAAA 的「v6 孪生域名」：连接目标改成孪生域名再走 ③ 国内·有IPv6。
  // 腾讯把 v6 放在单独的域名上（同一批节点按 Host/SNI 服务原域名），自动判断查不到 v6
  v6_aliases: { "down.qq.com": "downv6.qq.com", "dldir1.qq.com": "downv6.qq.com" },
  // 有 AAAA 但从校园网 v6 实测不通的段：直接拒绝（TCP RST），让 App 立刻回退 v4。
  // 不拒绝的话 TUN 会先替 App 完成握手，App 以为 v6 已连上，干等到超时（微信图片极慢/加载失败）
  v6_broken_cidrs: ["2402:4e00:1830:1214::/64"], // 腾讯 *.tc.qq.com / wxsnsdy.wxs.qq.com：微信图片、视频、文件下载
  exclude_nodes_regex: null, // 不作为落地的节点名（正则）
  // 订阅里 dialer-proxy 指向这些组名时，视为「先走 ① 免流隧道」
  entry_group_aliases: [],
  // 模式二：没有前置的订阅节点也先走 ① 免流隧道（[免流]，免费），另留一个 [v4直连] 副本
  landings_via_entry: true,
  display_names: {}, // 订阅节点名 → 面板显示名（不含前缀）
  group_defaults: {}, // 业务分组名 → 默认出口，覆盖内置默认
  group_notes: {}, // 业务分组名 → 说明，覆盖内置说明
  base_notes: {}, // 基础分组名 → 说明
  option_notes: {}, // 出口选项 → 说明
  // mac/windows 的固定端口：每个端口固定走一个出口，不受任何分组影响（例：给指纹浏览器）。
  // 每项 { port, outbound: <sing-box outbound 对象> 或 <已有出口名>, tag?, page? }；page 相同的端口在面板里合成一页
  fixed_ports: [],
  panel_pages: {}, // 固定端口说明页：页名 → 说明
  rule_set_base: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo",
  rules_dir: "/usr/local/etc/neu-v6-free/rules", // mac：本地规则集（启动不依赖网络）
  panel_dir: "/usr/local/etc/neu-v6-free/panel", // mac：面板目录
  windows_panel_dir: "C:/neu-v6-free/panel",
  cache_file: "neu-v6.cache.db", // 相对 sing-box 工作目录
  // mac 用 sing-box 官方 App（而不是 mac/install.sh 装的后台服务）：在线规则集、不带网页面板（App 自带分组切换）
  mac_app: false,
  tun: true,
};

const SKIP_TYPES = new Set(["direct", "reject", "dns"]);
const DELAY_URL = "https://www.gstatic.com/generate_204";
const clone = (o) => JSON.parse(JSON.stringify(o));
const isIP = (h) => /^[\d.]+$/.test(h) || h.includes(":");

export const rsTag = (ref) => ref.replace("/", "-"); // 'geosite/category-ai-!cn' → 'geosite-category-ai-!cn'
export const ruleSetUrl = (base, ref) => `${base}/${ref.split("/").map(encodeURIComponent).join("/")}.srs`;

/** 本配置用到的全部规则集（kind/name）。 */
export function ruleSetRefs(platform = "mac") {
  const refs = ["geosite/cn", "geoip/cn"];
  for (const g of SERVICE_GROUPS) for (const r of g.match.rule_sets || []) if (!refs.includes(r)) refs.push(r);
  return refs;
}

function selector(tag, members, def) {
  if (!members.includes(def)) throw new Error(`分组「${tag}」的默认出口「${def}」不在可选项里：${members.join("、")}`);
  return { type: "selector", tag, outbounds: members, default: def, interrupt_exist_connections: true };
}

const urltest = (tag, members) => ({
  type: "urltest", tag, outbounds: members, url: DELAY_URL, interval: "3m", tolerance: 50, idle_timeout: "30m",
});

/** 业务分组在该平台上的匹配规则（可能有多条：按进程、按域名、按规则集）；本平台一条都用不了时返回空数组。 */
function serviceRules(g, platform, outbound) {
  const m = g.match;
  const rules = [];
  const p = m.process?.[platform];
  if (p?.length) rules.push(platform === "android" ? { package_name: p, outbound } : { process_path_regex: p, outbound });
  if (m.domain_suffix?.length) rules.push({ domain_suffix: m.domain_suffix, outbound });
  if (m.rule_sets?.length) rules.push({ rule_set: m.rule_sets.map(rsTag), outbound });
  return rules;
}

export function build(settings, proxies, platform = "mac") {
  if (!PLATFORMS.includes(platform)) throw new Error(`未知平台 ${platform}，可选 ${PLATFORMS.join("/")}`);
  const s = { ...DEFAULTS, ...settings };
  const servers = s.entry_servers || {};
  const serverIds = Object.keys(servers);
  const tunnel = serverIds.length > 0;
  const desktop = platform === "mac" || platform === "windows";
  const aliases = new Set(s.entry_group_aliases || []);
  const exclude = s.exclude_nodes_regex ? new RegExp(s.exclude_nodes_regex) : null;
  const protoOrder = Object.keys(ENTRY_PROTOCOLS);

  // ---- 节点 ----
  const raw = new Map(); // 订阅名 → outbound（tag 暂为订阅名）
  const entryNodes = []; // [服务器序, 协议序, outbound]
  const warnings = [];
  for (const p of proxies) {
    if (SKIP_TYPES.has(p.type)) continue;
    const o = convert(p);
    if (!o) { warnings.push(`跳过不支持的节点: ${p.name} (${p.type})`); continue; }
    const srv = servers[p.server];
    const brutal = srv ? (srv.hy2_brutal !== undefined ? srv.hy2_brutal : s.hy2_brutal) : null;
    if (p.type === "hysteria2" && brutal) Object.assign(o, brutal); // 自有服务器的 Hy2（v6 入口与落地版本）都用 Brutal
    if (srv && p.type in ENTRY_PROTOCOLS && (p.type !== "vless" || "reality-opts" in p)) {
      const e = clone(o); // 派生 v6 入口：同端口同凭据，只换地址
      Object.assign(e, { server: srv.v6, tag: `${srv.label} v6 · ${ENTRY_PROTOCOLS[p.type]}` });
      entryNodes.push([serverIds.indexOf(p.server), protoOrder.indexOf(p.type), e]);
    }
    if (exclude && exclude.test(p.name)) continue;
    if (srv && !srv.landing) continue; // 自有服务器默认只当入口：作落地会经它再绕回它，流量翻倍
    if (p["dialer-proxy"]) o.detour = aliases.has(p["dialer-proxy"]) ? ENTRY : p["dialer-proxy"];
    else if (tunnel && s.landings_via_entry) o.detour = ENTRY;
    raw.set(p.name, o);
  }
  // 指向不存在的前置（订阅里的组名等）：去掉前置，按直连处理
  const missing = new Map();
  for (const o of raw.values()) {
    if (o.detour && o.detour !== ENTRY && !raw.has(o.detour)) {
      missing.set(o.detour, (missing.get(o.detour) || 0) + 1);
      delete o.detour;
    }
    if (o.detour === ENTRY && !tunnel) delete o.detour;
  }
  for (const [d, n] of missing) {
    warnings.push(`${n} 个节点的前置「${d}」不是节点，已按直连处理（若它是订阅里的免流入口组，请加到 entry_group_aliases）`);
  }
  entryNodes.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const entries = entryNodes.map((x) => x[2]);
  const entryTags = entries.map((e) => e.tag);
  if (tunnel && !entryTags.length) throw new Error("entry_servers 里的服务器在节点列表中没有找到可用入口（需要 hysteria2/tuic/reality/anytls）");
  if (s.default_landing && !raw.has(s.default_landing)) throw new Error(`默认落地「${s.default_landing}」不在节点列表里`);

  const viaEntry = (name, seen = []) => {
    const d = raw.get(name).detour;
    return d === ENTRY || (raw.has(d) && !seen.includes(d) && viaEntry(d, [...seen, name]));
  };
  const disp = (n) => s.display_names[n] ?? n;
  // 模式二：第一跳走 ① 的加 [免流]，其余（本机直连）加 [v4直连]；模式一不加前缀
  const tag = new Map([...raw.keys()].map((n) => [n, (tunnel ? (viaEntry(n) ? FREE : V4) : "") + disp(n)]));
  const nodes = [];
  for (const [n, o] of raw) {
    o.tag = tag.get(n);
    if (tag.has(o.detour)) o.detour = tag.get(o.detour);
    // 模式一：节点地址是域名时优先解析 v6，用 v6 连过去就免费
    if (!tunnel && !o.detour && !isIP(o.server)) o.domain_resolver = { server: "cn6", strategy: "prefer_ipv6" };
    nodes.push(o);
  }
  const landings = [...raw.keys()].map((n) => tag.get(n));
  // 第一跳直接是 ① 的落地，再各生成一个本机 v4 直连的副本
  const v4Nodes = [...raw.keys()].filter((n) => raw.get(n).detour === ENTRY).map((n) => {
    const o = { ...raw.get(n), tag: V4 + disp(n) };
    delete o.detour;
    return o;
  });
  const v4Landings = v4Nodes.map((o) => o.tag);
  const ownServers = [...serverIds.filter(isIP).map((ip) => (ip.includes(":") ? `${ip}/128` : `${ip}/32`)),
    ...serverIds.map((k) => `${servers[k].v6}/128`)];

  // ---- 固定端口（mac/windows）----
  const fixed = desktop ? (s.fixed_ports || []).map((f) => {
    const out = typeof f.outbound === "string" ? null : clone(f.outbound);
    return { port: f.port, inTag: f.tag || `port-${f.port}`, outTag: out ? out.tag : f.outbound, out, page: f.page };
  }) : [];

  // ---- 分组 ----
  const protoTags = tunnel && s.entry_default ? entries.filter((e) => e.type === s.entry_default).map((e) => e.tag) : [];
  const protoAuto = protoTags.length ? s.proto_auto_name.replace("{}", ENTRY_PROTOCOLS[s.entry_default]) : null;
  const abroadMembers = tunnel ? [...landings, ...v4Landings, TUNNEL_EXIT] : [...landings, D_V6PREF];
  const gd = s.group_defaults || {}; // 也可覆盖 ①②③④ 基础分组的默认出口（网页生成器用）
  const abroadDefault = gd[ABROAD] ?? (s.default_landing ? tag.get(s.default_landing) : abroadMembers[0]);
  const serviceMembers = tunnel
    ? [ABROAD, TUNNEL_EXIT, CN6, CN4, D_V6PREF, D_V4, ...landings, ...v4Landings]
    : [ABROAD, CN6, CN4, D_V6PREF, D_V4, ...landings];
  const services = SERVICE_GROUPS.map((g) => {
    const def = gd[g.name] ?? (tunnel ? g.def.tunnel : g.def.direct);
    return { ...g, def, rules: serviceRules(g, platform, g.name) };
  }).filter((g) => g.rules.length); // 本平台一条规则都用不了的分组（如 iOS 上只按进程的）直接不生成

  const outbounds = [
    ...(tunnel ? [
      selector(ENTRY, [...(protoAuto ? [protoAuto] : []), AUTO, ...entryTags, D_ANY], gd[ENTRY] ?? (protoAuto || AUTO)),
      ...(protoAuto ? [urltest(protoAuto, protoTags)] : []),
      urltest(AUTO, entryTags),
    ] : []),
    selector(ABROAD, abroadMembers, abroadDefault),
    selector(CN6, tunnel ? [D_V6, D_V6PREF, TUNNEL_EXIT] : [D_V6, D_V6PREF], gd[CN6] ?? D_V6),
    selector(CN4, tunnel ? [TUNNEL_EXIT, D_V4, D_V6PREF] : [D_V4, D_V6PREF], gd[CN4] ?? (tunnel ? TUNNEL_EXIT : D_V4)),
    ...(tunnel ? [selector(TUNNEL_EXIT, [ENTRY], ENTRY)] : []),
    ...services.map((g) => selector(g.name, serviceMembers, g.def)),
    ...entries,
    ...nodes,
    ...v4Nodes,
    ...fixed.filter((f) => f.out).map((f) => f.out),
    { type: "direct", tag: D_ANY },
    // direct 收到的仍是域名，会用 default_domain_resolver（v4 DNS）重解析；所以按 IP 版本区分的直连都要自带 domain_resolver
    { type: "direct", tag: D_V6, domain_resolver: { server: "cn6", strategy: "ipv6_only" } },
    { type: "direct", tag: D_V4, domain_resolver: { server: "cn4", strategy: "ipv4_only" } },
    { type: "direct", tag: D_V6PREF, domain_resolver: { server: "cn6", strategy: "prefer_ipv6" } },
  ];

  // ---- 规则集 ----
  // mac 是常驻服务，用本地规则集（启动不依赖网络）；其他平台在线下载、每天更新（有隧道走隧道，否则 v6 优先直连）
  const localRules = platform === "mac" && !s.mac_app;
  const ruleSets = ruleSetRefs(platform).map((r) => (localRules
    ? { type: "local", tag: rsTag(r), format: "binary", path: `${s.rules_dir}/${rsTag(r)}.srs` }
    : { type: "remote", tag: rsTag(r), format: "binary", url: ruleSetUrl(s.rule_set_base, r),
      download_detour: tunnel ? ENTRY : D_V6PREF, update_interval: "1d" }));
  const v6Any = { ip_cidr: ["::/0"] };
  // 按 App 的分组（含它们附带的域名规则）最先匹配，其余按位置
  const appGroup = (g) => Boolean(g.match.process);
  const rulesAt = (where, pick = () => true) => services.filter((g) => g.where === where && pick(g)).flatMap((g) => g.rules);
  // 国内站点分组（cn_v4）的规则集不一定都在 geosite-cn 里，一起参与 v6 解析与直连判断
  const cnSets = ["geosite-cn", ...services.filter((g) => g.where === "cn_v4").flatMap((g) => g.match.rule_sets.map(rsTag))];
  const proxied = tunnel || landings.length > 0;

  // ---- 入站 ----
  const inbounds = desktop ? [
    { type: "mixed", tag: "main", listen: s.listen, listen_port: s.main_port },
    ...fixed.map((f) => ({ type: "mixed", tag: f.inTag, listen: s.listen, listen_port: f.port })),
  ] : [];
  // v4/v6 都接管：否则国外站的 v6 会绕过代理从校园网直出。
  // v6 不能用 ULA（fd00::/8）：RFC 6724 下「ULA 源 → 公网 v6」排在 IPv4 后面，系统会给 App 先返回 v4，
  // 连接进 TUN 时已是 v4 IP，「国内有 v6 就直连」就判断不到。这里用文档段（只在本机 TUN 内部，不上网）
  if (s.tun !== false) {
    inbounds.push({ type: "tun", tag: "tun", address: ["172.19.0.1/30", "2001:db8:6e75::1/126"],
      auto_route: true, strict_route: true, stack: "mixed" });
  }

  const dns = proxied ? {
    servers: [
      { type: "udp", tag: "cn6", server: s.cn_dns_v6 },
      { type: "udp", tag: "cn4", server: s.cn_dns_v4 },
      { type: "https", tag: "remote", server: "1.1.1.1", detour: ABROAD },
      { type: "fakeip", tag: "fakeip", inet4_range: "198.18.0.0/15", inet6_range: "fc00::/18" },
    ],
    rules: [
      { domain_suffix: s.direct_domains, server: "cn4" },
      // 模式二：国内域名只有 AAAA 用真实解析（有 v6 就直连），A 给 fakeip。这样只有 v4 的国内站连进来时带着域名，
      // 进隧道后由服务器自己解析。若这里返回真实 A，隧道里传的就是校园网解析出的国内 IP，
      // 从海外服务器连常常超时（实测 res.wx.qq.com 的 43.141.x 节点从香港连不上，微信扫码登录二维码因此加载不出）
      tunnel ? { rule_set: cnSets, query_type: ["AAAA"], server: "cn6" } : { rule_set: cnSets, server: "cn6" },
      // 其余（国外域名、模式二的国内 A 记录）给 fakeip，连接时由代理端解析
      { query_type: ["A", "AAAA"], server: "fakeip" },
    ],
    final: "remote",
    independent_cache: true,
  } : {
    // 没有任何代理：全部本机解析。v6 DNS 才会给国内 CDN 返回 AAAA
    servers: [
      { type: "udp", tag: "cn6", server: s.cn_dns_v6 },
      { type: "udp", tag: "cn4", server: s.cn_dns_v4 },
    ],
    rules: [{ domain_suffix: s.direct_domains, server: "cn4" }],
    final: "cn6",
    independent_cache: true,
  };

  const route = {
    rule_set: ruleSets,
    rules: [
      ...fixed.map((f) => ({ inbound: [f.inTag], outbound: f.outTag })),
      // 放在 sniff 前：TUN 能在握手前就拒绝，App 马上收到 RST 改用 v4
      ...(s.v6_broken_cidrs?.length ? [{ ip_cidr: s.v6_broken_cidrs, action: "reject" }] : []),
      { action: "sniff" },
      { protocol: "dns", action: "hijack-dns" },
      { ip_is_private: true, outbound: D_ANY },
      // 自己的服务器（SSH、面板等）本机直连，不绕去落地
      ...(ownServers.length ? [{ ip_cidr: ownServers, outbound: D_ANY }] : []),
      { domain_suffix: s.direct_domains, outbound: D_ANY },
      // v6 孪生域名：只改拨号目标，TLS 的 SNI/证书仍是原域名
      ...Object.entries(s.v6_aliases || {}).map(([src, dst]) => (
        { domain: [src], action: "route", outbound: CN6, override_address: dst })),
      // 按进程的分组（豆包、微信、网易云）最优先：整个 App 一起决定，不拆
      ...rulesAt("before_cn", appGroup),
      // 海外 QUIC（UDP 443）直接拒绝：浏览器会先试 QUIC，套在多层隧道里常卡好几秒才回退 TCP；
      // 拒绝后立刻走 TCP。国内（含按进程直连的微信等）不受影响。没有代理时不需要
      ...(proxied ? [{ type: "logical", mode: "and", action: "reject",
        rules: [{ network: ["udp"], port: [443] }, { rule_set: [...cnSets, "geoip-cn"], invert: true }] }] : []),
      // 总原则：国内资源只要有 v6 地址就 v6 直连（免费且最快），排在所有按站点分的分组前面。
      // 模式一在这里解析判断；模式二不能用 resolve：它会把域名换成 IP 传进隧道（见 DNS 部分），v6 的判断交给 DNS（AAAA 真实、A 为 fakeip）
      ...(tunnel ? [] : [{ rule_set: cnSets, action: "resolve", server: "cn6", strategy: "prefer_ipv6" }]),
      { type: "logical", mode: "and", rules: [{ rule_set: cnSets }, v6Any], outbound: CN6 },
      { type: "logical", mode: "and", rules: [{ rule_set: ["geoip-cn"] }, v6Any], outbound: CN6 },
      ...rulesAt("before_cn", (g) => !appGroup(g)),
      // 下面都是只有 v4 的连接
      ...rulesAt("cn_v4"),
      { rule_set: ["geosite-cn"], outbound: CN4 },
      ...rulesAt("after_cn"),
      // 直接访问国内 v4 IP 的连接（v6 的已在前面直连）
      { rule_set: ["geoip-cn"], outbound: CN4 },
    ],
    final: ABROAD,
    default_domain_resolver: "cn4",
    // 出站绑定物理网卡，避免自身连接被 TUN 抓回形成环路
    auto_detect_interface: true,
  };
  // 识别发起连接的进程：按 App 分流 + 面板里能看到是哪个 App（iOS 不支持）
  if (platform !== "ios") route.find_process = true;

  const experimental = { cache_file: { enabled: true, path: s.cache_file, store_fakeip: true } };
  if (platform === "windows" || localRules) {
    experimental.clash_api = {
      external_controller: s.clash_api,
      secret: s.clash_api_secret,
      external_ui: platform === "mac" ? s.panel_dir : s.windows_panel_dir,
      default_mode: "rule",
    };
  }

  const config = { log: { level: "warn", timestamp: true }, dns, inbounds, outbounds, route, experimental };
  const notes = { ...optionNotes(s.proto_auto_name), ...s.option_notes };
  const entryList = tunnel ? [...entryTags] : [];
  const panel = {
    node_notes: nodeNotes(config, entryList, notes, tunnel, new Set(fixed.filter((f) => f.out).map((f) => f.outTag))),
    groups: [
      ...baseGroups(tunnel).map(([n, d]) => ({ name: n, desc: s.base_notes[n] ?? d, kind: "base" })),
      ...services.map((g) => ({ name: g.name, desc: s.group_notes[g.name] ?? g.desc, kind: "service", default: g.def })),
    ],
    info: fixedPages(fixed, s.panel_pages),
    notes,
    free_prefix: FREE,
    v4_prefix: V4,
  };
  return { config, panel, warnings, mode: tunnel ? "tunnel" : "direct" };
}

/** 按节点的实际前置链给出说明：是否经免流入口、是否计费。 */
function nodeNotes(cfg, entries, optNotes, tunnel, skip) {
  const byTag = Object.fromEntries(cfg.outbounds.map((o) => [o.tag, o]));
  const viaEntry = (t, seen = []) => {
    const d = byTag[t]?.detour;
    return d === ENTRY || (d != null && !seen.includes(d) && viaEntry(d, [...seen, t]));
  };
  const notes = {};
  for (const o of cfg.outbounds) {
    const t = o.tag;
    if (["selector", "direct", "urltest"].includes(o.type) || t in optNotes || skip.has(t)) continue; // 固定端口的出口在说明页里讲
    if (entries.includes(t)) notes[t] = "通过校园网 IPv6 连到这台服务器（隧道入口，免费）";
    else if (viaEntry(t)) {
      notes[t] = o.detour === ENTRY ? "先走 ① 免流隧道，再到此落地（免费）" : `先走 ① 免流隧道，经「${o.detour}」再到此落地（免费）`;
    } else if (tunnel) notes[t] = "本机直接用 IPv4 连到此落地（不走隧道，延迟低、计费）";
    else notes[t] = o.detour ? `经「${o.detour}」再到此落地` : "节点地址有 IPv6 时用 v6 连接（免费），否则 v4（计费）";
  }
  return notes;
}

/** 固定端口说明页：同一 page 的端口合成一页，页名后附端口范围。 */
function fixedPages(fixed, pages) {
  const byPage = new Map();
  for (const f of fixed) {
    const key = f.page || `🔌 固定端口 ${f.port}`;
    if (!byPage.has(key)) byPage.set(key, []);
    byPage.get(key).push(f);
  }
  return [...byPage].map(([page, fs]) => {
    const span = fs.length === 1 ? `${fs[0].port}` : `${fs[0].port}-${fs[fs.length - 1].port}`;
    const lines = fs.map((f) => `127.0.0.1:${f.port} → ${f.outTag}`).join("；");
    const desc = pages[page] ?? "每个端口固定走一个出口，与其他分组完全隔离，切换任何分组都不影响它们";
    return { name: `${page}(${span})`, desc: `${desc}：${lines}。` };
  });
}
