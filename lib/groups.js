// 分组定义：名称、说明、匹配规则、可选项与默认出口。
//
// 设计原则：
//   1. 只用两个词：「服务器」= 经自己的服务器出去（校园网 v6 连过去，免费）；「直连」= 校园网直接出去（v6 免费、v4 计费）。
//   2. 最多两层：例外分组 → 总开关 → 节点。只有一个选项的组不生成（直接用那个选项）。
//   3. 不需要人选的不做成分组：国内网站有 IPv6 就 v6 直连，固定规则。
//
// 面板上依次是：
//   三个总开关：免流服务器 → 国内仅 v4 网站 → 国外网站
//   例外分组：按类别限定可选项（风控严格的只能直连，App 在直连和服务器之间选，国外类跟随「国外网站」或另选）
//
// 匹配顺序（命中第一条即停）：
//   固定端口 → 局域网 / 校园网 / 自己的服务器 → 风控类与 App 类例外 → 国内有 v6 → 直连 v6
//   → 国外类例外 → 国内仅 v4 → 「国内仅 v4 网站」 → 海外游戏 → 其余 → 「国外网站」
//
// 两种模式：
//   direct（模式一）：没有自己的服务器。国内有 v6 就 v6（免费），否则 v4 直连（计费）；国外走订阅节点或直连。
//   tunnel（模式二）：有双栈服务器（entry_servers）。校园网 v6 连服务器、服务器出 v4，只有 v4 的流量也免费。

// 三个总开关
export const ENTRY = "免流服务器";
export const CN4 = "国内仅 v4 网站";
export const ABROAD = "国外网站";

// 直连出口
export const D_V6PREF = "直连（v6 优先）";
export const D_V4 = "直连 v4";
export const D_V6 = "直连 v6";
export const D_DIRECT = "直连"; // 局域网、校园网、自己的服务器等内部规则用，不出现在选项里
export const ENTRY_OFF = "不用服务器（离校时选）"; // 「免流服务器」里的关闭项：全部改为直连
export const AUTO = "自动选最快"; // 「免流服务器」里的测速项：在全部入口里选最快可用的，挂了自动换

// 落地节点名后缀（模式二）
export const VIA = "（经服务器）"; // 先经免流服务器，再到该落地：免费
export const V4SUF = "（直连 v4）"; // 校园网 v4 直接连该落地：计费

// 服务器入口的协议简称，顺序即面板排序
export const ENTRY_PROTOCOLS = { hysteria2: "Hy2", tuic: "TUIC", vless: "Reality", anytls: "AnyTLS" };

// 不一定在 geosite-cn 里、但应按国内处理的站点（只有 v4 的部分走「国内仅 v4 网站」）
export const CN_EXTRA_SETS = ["geosite/bilibili", "geosite/douyin", "geosite/xiaohongshu"];

/** 出口选项的一句话说明（面板显示在选项下方）；settings.option_notes 可覆盖或追加 */
export function optionNotes() {
  return {
    [ENTRY]: "经免流服务器出去：免费，网站看到服务器的 IP",
    [CN4]: "跟随「国内仅 v4 网站」开关",
    [ABROAD]: "跟随「国外网站」开关",
    [D_V6PREF]: "校园网直连：有 IPv6 用 v6（免费），没有用 v4（计费），网站看到校园网 IP",
    [D_V4]: "校园网 IPv4 直连：计费，网站看到校园网 IP",
    [D_V6]: "校园网 IPv6 直连：免费；目标没有 v6 就连不上",
    [ENTRY_OFF]: "不用服务器，所有「经服务器」的流量改为直连。离开校园网（没有 IPv6）时选这个",
    [AUTO]: "每 3 分钟测一次所有服务器入口，用最快且可用的；某台挂了会自动换",
  };
}

/** 三个总开关的说明，按面板顺序；settings.base_notes 可覆盖 */
export function baseGroups(tunnel) {
  return [
    ...(tunnel ? [[ENTRY, "所有免费流量经哪台服务器出去。默认第一台服务器；挂了或流量用完时手动换一台，或选「自动选最快」。"
      + "离开校园网（没有 IPv6）时选「不用服务器」，全部改为直连。"]] : []),
    [CN4, tunnel
      ? "没有 IPv6 的国内网站怎么走。选「免流服务器」= 免费，但网站看到的是服务器 IP（个别网站会出错）；"
        + "选「直连 v4」= 计费，网站看到校园网 IP，和不开代理时一样。有 IPv6 的国内网站不受它影响，固定 v6 直连。"
      : "没有 IPv6 的国内网站：没有自己的服务器时只能 v4 直连（计费）。"],
    [ABROAD, tunnel
      ? "国外网站最后从哪出去，也是没被任何规则匹配到的流量的兜底。「（经服务器）」= 先到免流服务器再到该落地，免费；"
        + "「（直连 v4）」= 校园网 v4 直接连该落地，计费；「免流服务器」= 从服务器直接出去。"
      : "国外网站从哪出去，也是没被任何规则匹配到的流量的兜底。订阅节点地址有 IPv6 时用 v6 连接（免费），否则 v4（计费）。"],
  ];
}

// 例外分组。
//   kind：strict = 风控严格，只能直连；app = 国内 App，在直连与服务器之间选；foreign = 国外类，跟随「国外网站」或另选
//   match.rule_sets 用 "kind/name" 表示 MetaCubeX 的 geosite/geoip 文件；match.domain_suffix 为域名后缀；
//   match.process 按平台给：mac/windows 是进程路径正则，android 是包名；iOS 不支持按进程
//   extra：该组额外的可选项；def：{ tunnel, direct } 两种模式下的默认；where：before_cn / after_cn（国外类匹配位置）
export const SERVICE_GROUPS = [
  {
    name: "🔐 登录·支付·银行", kind: "strict",
    desc: "国内登录、支付、银行、政务入口（含 12306、学信网），以及实测经海外服务器会出错的国内站（如 CSDN）。"
      + "这类网站对 IP 风控严格，经服务器会触发异地登录、验证码或失败，所以只能直连。流量很小。",
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
    def: { tunnel: D_V6PREF, direct: D_V6PREF },
  },
  {
    name: "💬 微信", kind: "app",
    desc: "微信 App 的全部流量（含表情包、小程序），以及浏览器里的微信网页（扫码登录、公众号文章）。默认直连，避免资源因海外 IP 加载失败。",
    match: { process: { mac: ["/微信\\.app/", "/WeChat\\.app/"], windows: ["\\\\(Weixin|WeChat)\\.exe$"],
      android: ["com.tencent.mm"] },
      domain_suffix: ["weixin.qq.com", "wx.qq.com", "wechat.com", "servicewechat.com", "weixinbridge.com"] },
    def: { tunnel: D_V6PREF, direct: D_V6PREF },
  },
  {
    name: "🎵 网易云", kind: "app",
    desc: "网易云音乐 App 的全部流量。默认直连：经服务器时取播放地址的接口看到海外 IP，会不给歌曲链接或提示版权限制。",
    match: { process: { mac: ["/网易云音乐\\.app/", "/NeteaseMusic\\.app/"], windows: ["\\\\cloudmusic\\.exe$"],
      android: ["com.netease.cloudmusic"] } },
    def: { tunnel: D_V6PREF, direct: D_V6PREF },
  },
  {
    name: "⌨️ 豆包输入法", kind: "app",
    desc: "豆包输入法的全部联网。默认直连 v4，避免被当成海外用户。",
    match: { process: { mac: ["/DoubaoIme\\.app/"] } },
    def: { tunnel: D_V4, direct: D_V4 },
  },
  {
    name: "🤖 AI", kind: "foreign",
    desc: "ChatGPT、Claude、Gemini、Perplexity 等。这类服务对 IP 风控严格，建议固定一个干净的落地（如家宽）。",
    match: { rule_sets: ["geosite/category-ai-!cn", "geosite/openai", "geosite/anthropic", "geosite/google-gemini"] },
    def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "📺 YouTube", kind: "foreign",
    desc: "YouTube 视频与 App。流量大、不需要特定 IP，默认从免流服务器直接出去（一跳、最快）。",
    match: { rule_sets: ["geosite/youtube"] }, def: { tunnel: ENTRY, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🍎 苹果", kind: "foreign", extra: [D_V6PREF],
    desc: "Apple 全部服务（App Store、iCloud、系统更新，含国内 CDN）。有服务器时默认从服务器直接出去。",
    match: { rule_sets: ["geosite/apple"] }, def: { tunnel: ENTRY, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🎮 Steam", kind: "foreign", extra: [D_V6PREF],
    desc: "Steam 商店与下载。下载流量大，有服务器时默认从服务器直接出去。",
    match: { rule_sets: ["geosite/steam"] }, def: { tunnel: ENTRY, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🎬 流媒体", kind: "foreign", desc: "Netflix、Disney+、Spotify。需要解锁特定地区时在这里换落地。",
    match: { rule_sets: ["geosite/netflix", "geosite/disney", "geosite/spotify"] },
    def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "✈️ Telegram", kind: "foreign", desc: "Telegram 的域名与 IP 段。",
    match: { rule_sets: ["geosite/telegram", "geoip/telegram"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🐦 社交媒体", kind: "foreign", desc: "X/Twitter、Facebook/Instagram、TikTok。",
    match: { rule_sets: ["geosite/twitter", "geosite/facebook", "geosite/tiktok"] },
    def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🇬 谷歌", kind: "foreign", desc: "Google 搜索、Gmail、Drive 等（Gemini 归 AI，YouTube 单独分组）。",
    match: { rule_sets: ["geosite/google"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "📢 谷歌推送", kind: "foreign", desc: "Google FCM 推送通道（安卓、部分 App 的消息推送）。",
    match: { rule_sets: ["geosite/googlefcm"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🐙 GitHub", kind: "foreign", desc: "GitHub 网页、代码下载、Release。",
    match: { rule_sets: ["geosite/github"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🛠 开发者", kind: "foreign", desc: "Docker、npm、JetBrains 等开发相关站点（不含 GitHub）。",
    match: { rule_sets: ["geosite/category-dev", "geosite/docker"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "Ⓜ️ 微软", kind: "foreign", extra: [D_V6PREF], desc: "Microsoft、OneDrive、Bing、Office、Windows 更新（含国内 CDN）。",
    match: { rule_sets: ["geosite/microsoft", "geosite/onedrive"] }, def: { tunnel: ABROAD, direct: D_V6PREF }, where: "before_cn",
  },
  {
    name: "🚀 测速", kind: "foreign", desc: "Speedtest、fast.com 等测速网站，想测哪条线路就切到哪条。",
    match: { rule_sets: ["geosite/category-speedtest"] }, def: { tunnel: ABROAD, direct: ABROAD }, where: "before_cn",
  },
  {
    name: "🅾️ Oracle", kind: "foreign", extra: [D_V4],
    desc: "甲骨文云控制台等。默认直连 v4：控制台在国内能直接访问，用校园网固定 IP 登录更不容易触发账号风控。",
    match: { rule_sets: ["geosite/oracle"] }, def: { tunnel: D_V4, direct: D_V4 }, where: "before_cn",
  },
  {
    name: "🎯 海外游戏", kind: "foreign", desc: "海外游戏平台与游戏（国内游戏已按国内规则处理）。有服务器时默认从服务器直接出去。",
    match: { rule_sets: ["geosite/category-games"] }, def: { tunnel: ENTRY, direct: ABROAD }, where: "after_cn",
  },
];
