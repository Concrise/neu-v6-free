// 分组定义：面板展示顺序、用途说明、匹配规则与默认出口。
//
// 路由优先级（从上到下，命中即停，因此不会冲突）：
//   固定端口 → 局域网/校园网 → 按进程（豆包、微信、网易云）
//   → 国内资源有 v6 地址 → ③ 国内·有IPv6（总原则：能 v6 直连的一律 v6 直连）
//   → before_cn 业务分组 → cn_v4 国内站点分组（只剩纯 v4 部分）→ 其余国内域名 → ④
//   → after_cn 业务分组 → 国内 v4 IP → ④ → ② 国外出口（兜底）
//
// 两种模式：
//   direct：没有自己的服务器。国内能 v6 就 v6 直连（免费），否则 v4 直连（计费）；国外走订阅节点或直连。
//   tunnel：有双栈服务器（entry_servers）。校园网 v6 连到服务器、服务器出 v4，只有 v4 的流量也免费。

export const ENTRY = "① 免流隧道";
export const ABROAD = "② 国外出口";
export const CN6 = "③ 国内·有IPv6";
export const CN4 = "④ 国内·仅IPv4";
export const TUNNEL_EXIT = "隧道直出"; // 只含 ① 的分组：作为「出口」时语义是「从隧道入口那台服务器直接出去」
export const D_V6PREF = "本机直连·IPv6优先";
export const D_V4 = "本机直连·仅IPv4";
export const D_V6 = "本机直连·仅IPv6";
export const D_ANY = "不走隧道（本机直连）";
export const AUTO = "自动选择（最快可用）"; // ① 里的 urltest：定时测速，自动避开挂掉的入口
export const FREE = "[免流] "; // 节点前缀：第一跳走 ① 免流隧道（免费）
export const V4 = "[v4直连] "; // 节点前缀：本机 v4 直接连（计费）

export const ENTRY_PROTOCOLS = { hysteria2: "Hysteria2", tuic: "TUIC", vless: "Reality", anytls: "AnyTLS" }; // 顺序即排序

// 出口选项的说明（面板里显示在选项下方）；settings.option_notes 可覆盖或追加
export function optionNotes(protoAutoName) {
  const notes = {
    [TUNNEL_EXIT]: "走 ① 免流隧道，直接从入口那台服务器出去（免费，对方看到服务器机房 IP）",
    [ABROAD]: "跟随「② 国外出口」的选择",
    [CN6]: "跟随「③ 国内·有IPv6」",
    [CN4]: "跟随「④ 国内·仅IPv4」",
    [D_V6PREF]: "有 IPv6 走 v6（免费），否则 v4（计费）",
    [D_V4]: "只用 IPv4（计费），对方看到校园网 IP",
    [D_V6]: "只用 IPv6（免费），目标没有 v6 就连不上",
    [D_ANY]: "不走隧道。离开校园网（没有 v6）时选这个",
    [AUTO]: "每 3 分钟测一次所有入口，自动用最快且可用的；某台服务器挂了会自动换",
  };
  for (const p of Object.values(ENTRY_PROTOCOLS)) {
    notes[protoAutoName.replace("{}", p)] =
      `每 3 分钟测一次各服务器的 ${p} 入口，用最快且可用的；某台服务器挂了会自动换`;
  }
  return notes;
}

// 基础分组：[名称, 说明]，按模式给出；settings.base_notes 可覆盖说明
export function baseGroups(tunnel) {
  if (tunnel) {
    return [
      [ENTRY, "决定流量怎么离开校园网（第一跳）。所有带 [免流] 的节点和「隧道直出」都先走这里。"
        + "「自动选择」会定时测速、用最快且可用的入口，某台服务器挂了会自动换；手动指定某个入口后，该入口挂了不会自动切。"
        + "Hysteria2/TUIC 走 UDP，丢包多的线路上更快；Reality/AnyTLS 走 TCP，更稳。"
        + "离开校园网时选「不走隧道」，[免流] 节点会自动变成普通直连代理。"],
      [ABROAD, "国外网站最终从哪里出去（落地），也是所有没被规则匹配到的流量的兜底。"
        + "[免流] = 先走 ① 隧道再到该落地（免费）；[v4直连] = 本机直接用 IPv4 连该落地（延迟低、计费）。"
        + "大多数业务分组默认「跟随② 国外出口」，改这里它们一起变。"],
      [CN6, "国内网站、且查得到 IPv6 地址时走这里。默认「本机直连·仅IPv6」，校园网 v6 免费。"],
      [CN4, "国内网站、但只有 IPv4 时走这里。默认「隧道直出」（免费，对方看到服务器机房 IP）；"
        + "遇到不认海外 IP 的网站，可临时切到「本机直连·仅IPv4」（计费）。"],
    ];
  }
  return [
    [ABROAD, "国外网站从哪里出去，也是所有没被规则匹配到的流量的兜底。"
      + "填了订阅时可选订阅节点：节点地址有 IPv6 的会用 v6 连接（免费），否则 v4（计费）。"
      + "「本机直连·IPv6优先」= 不走代理，目标有 v6 就免费。"],
    [CN6, "国内网站、且查得到 IPv6 地址时走这里。默认「本机直连·仅IPv6」，校园网 v6 免费。"],
    [CN4, "国内网站、但只有 IPv4 时走这里。没有自己的服务器时只能 v4 直连（计费）。"],
  ];
}

// 业务分组。match.rule_sets 用 "kind/name" 表示 MetaCubeX 的 geosite/geoip 文件；
// match.process 按平台给：mac/windows 是进程路径正则，android 是包名；iOS 不支持按进程。
// def: { tunnel, direct } 两种模式下的默认出口；where: before_cn / cn_v4 / after_cn
export const SERVICE_GROUPS = [
  {
    name: "⌨️ 豆包输入法",
    desc: "按进程匹配豆包输入法的所有联网。默认「本机直连·仅IPv4」，避免被当成海外 IP。",
    match: { process: { mac: ["/DoubaoIme\\.app/"] } },
    def: { tunnel: D_V4, direct: D_V4 }, where: "before_cn",
  },
  {
    name: "💬 微信",
    desc: "按进程匹配微信全部流量（含表情包、小程序），以及浏览器里的微信网页（扫码登录、公众号文章）。"
      + "默认「本机直连·IPv6优先」：有 v6 免费，没有则 v4 计费；不走隧道，避免资源因海外 IP 加载失败——"
      + "例如从海外解析 res.wx.qq.com 会被分到海外节点并被重置，网站上的「微信扫码登录」二维码就加载不出来。",
    match: { process: { mac: ["/微信\\.app/", "/WeChat\\.app/"], windows: ["\\\\(Weixin|WeChat)\\.exe$"],
      android: ["com.tencent.mm"] },
      domain_suffix: ["weixin.qq.com", "wx.qq.com", "wechat.com", "servicewechat.com", "weixinbridge.com"] },
    def: { tunnel: D_V6PREF, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🎵 网易云",
    desc: "按进程匹配网易云音乐全部流量（含内置的 Helper 进程）。默认「本机直连·IPv6优先」：有 v6 免费，没有则 v4 计费；"
      + "不走隧道，否则取播放地址的接口看到海外 IP，会不给歌曲链接或提示版权限制。",
    match: { process: { mac: ["/网易云音乐\\.app/", "/NeteaseMusic\\.app/"], windows: ["\\\\cloudmusic\\.exe$"],
      android: ["com.netease.cloudmusic"] } },
    def: { tunnel: D_V6PREF, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🔐 登录·支付·政务",
    desc: "国内登录、支付、银行、政务入口，以及实测从海外访问会出错的国内站（如 CSDN）。默认「本机直连·IPv6优先」："
      + "这类网站常对海外 IP 风控、限制或被 CDN 分错节点，导致扫码登录、付款、验证码失败；它们流量很小，直连（v4 计费）代价不大。"
      + "只收登录/支付入口，不收整个公司（视频、网盘下载等大流量仍走 ④ 免流）。参考了其他东大免流项目的直连白名单。",
    match: {
      rule_sets: ["geosite/category-bank-cn", "geosite/unionpay"],
      domain_suffix: [
        "alipay.com", "alipay.cn", "alipayobjects.com", "mybank.cn", "tenpay.com", "jdpay.com",
        "login.taobao.com", "login.tmall.com", "passport.alibaba.com", "login.alibaba.com",
        "passport.jd.com", "pay.jd.com", "ptlogin2.qq.com", "graph.qq.com", "id.qq.com",
        "passport.baidu.com", "wappass.baidu.com", "passport.163.com", "reg.163.com", "passport.meituan.com",
        // 上游 category-bank-cn 漏了几家最大的银行（实测 2026-10-18），手动补上
        "icbc.com.cn", "ccb.com", "boc.cn", "bankofchina.com", "cmbchina.com",
        "12306.cn", "gov.cn", "chsi.com.cn", "csdn.net",
      ],
    },
    def: { tunnel: D_V6PREF, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "📱 B站·抖音·小红书",
    desc: "哔哩哔哩、抖音、小红书（网页与 App，含视频/图片 CDN）。有 IPv6 的资源固定走「③ 国内·有IPv6」"
      + "（直连免费），这里只管它们只有 IPv4 的部分（主站、大部分视频）。默认跟随「④ 国内·仅IPv4」；"
      + "有服务器时那是免流隧道（会绕服务器再回国，可能被分到海外 CDN），想要速度就切「本机直连·仅IPv4」（计费）。",
    match: { rule_sets: ["geosite/bilibili", "geosite/douyin", "geosite/xiaohongshu"] },
    def: { tunnel: CN4, direct: CN4 }, where: "cn_v4",
  },
  {
    name: "🤖 AI",
    desc: "ChatGPT、Claude、Gemini、Perplexity 等海外 AI 服务。这类服务对 IP 风控严格，建议固定一个干净的落地。",
    match: { rule_sets: ["geosite/category-ai-!cn", "geosite/openai", "geosite/anthropic", "geosite/google-gemini"] },
    def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "📢 谷歌推送", desc: "Google FCM 推送通道（安卓、部分 App 的消息推送）。",
    match: { rule_sets: ["geosite/googlefcm"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "📺 YouTube",
    desc: "YouTube 视频与 App。流量大，有服务器时默认「隧道直出」：只经一跳、延迟最低，看视频不需要家宽 IP。",
    match: { rule_sets: ["geosite/youtube"] }, def: { tunnel: TUNNEL_EXIT, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🎬 流媒体", desc: "Netflix、Disney+、Spotify。需要解锁特定地区时在这里换落地。",
    match: { rule_sets: ["geosite/netflix", "geosite/disney", "geosite/spotify"] },
    def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "✈️ Telegram", desc: "Telegram 的域名与 IP 段。",
    match: { rule_sets: ["geosite/telegram", "geoip/telegram"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🐦 社交媒体", desc: "X/Twitter、Facebook/Instagram、TikTok。",
    match: { rule_sets: ["geosite/twitter", "geosite/facebook", "geosite/tiktok"] },
    def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🐙 GitHub", desc: "GitHub 网页、代码下载、Release。",
    match: { rule_sets: ["geosite/github"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🛠 开发者", desc: "Docker、npm、JetBrains 等开发相关站点（不含 GitHub）。",
    match: { rule_sets: ["geosite/category-dev", "geosite/docker"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🇬 谷歌服务", desc: "Google 搜索、Gmail、Drive 等（Gemini 归 AI，YouTube 单独分组）。",
    match: { rule_sets: ["geosite/google"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "Ⓜ️ 微软", desc: "Microsoft、OneDrive、Bing、Office、Windows 更新（含国内 CDN）。",
    match: { rule_sets: ["geosite/microsoft", "geosite/onedrive"] }, def: { tunnel: ABROAD, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🍎 苹果", desc: "Apple 全部服务（App Store、iCloud、系统更新，含国内 CDN）。有服务器时默认「隧道直出」（免费）。",
    match: { rule_sets: ["geosite/apple"] }, def: { tunnel: TUNNEL_EXIT, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🎮 Steam", desc: "Steam 商店与下载。下载流量大，有服务器时默认「隧道直出」。",
    match: { rule_sets: ["geosite/steam"] }, def: { tunnel: TUNNEL_EXIT, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🅾️ Oracle", desc: "甲骨文云控制台等。默认跟随「② 国外出口」，保持固定落地 IP 便于账号风控。",
    match: { rule_sets: ["geosite/oracle"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🚀 测速", desc: "Speedtest、fast.com 等测速网站，想测哪条线路就切到哪条。",
    match: { rule_sets: ["geosite/category-speedtest"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🎯 海外游戏", desc: "海外游戏平台与游戏（国内游戏已在前面按国内规则处理）。有服务器时默认「隧道直出」。",
    match: { rule_sets: ["geosite/category-games"] }, def: { tunnel: TUNNEL_EXIT, direct: ABROAD }, where: "after_cn",
  },
];
