"""分组定义：面板展示顺序、用途说明、匹配规则与默认出口。

路由优先级（从上到下，命中即停，因此不会冲突）：
  HK 入口 → 局域网/校园网 → 按进程（豆包、微信）→ BEFORE_CN 业务分组
  → 国内域名（有 v6 → 国内v6，否则 国内v4）→ AFTER_CN 业务分组 → 国内 IP → 🌍 国外（兜底）
"""

ENTRY, ABROAD, CN6, CN4 = "🆓 免流入口", "🌍 国外", "🇨🇳 国内v6", "🇨🇳 国内v4"
D_V6PREF, D_V4, D_V6, D_ANY = "直连·v6优先", "直连·仅v4", "直连·仅v6", "直连"
V4_SUFFIX = "·v4直连"  # 落地节点去掉免流前置、本机 v4 直连的副本

# 出口选项的说明（面板里显示在选项下方）
OPTION_NOTES = {
    ENTRY: "经 Oracle v6 入口，从 Oracle 出去（美国 IP，免费）",
    ABROAD: "跟随「🌍 国外」分组的选择（默认免流→家宽）",
    CN6: "跟随「🇨🇳 国内v6」",
    CN4: "跟随「🇨🇳 国内v4」",
    D_V6PREF: "本机直连：有 v6 走 v6（免费），否则 v4（计费）",
    D_V4: "本机 v4 直连（计费），对方看到校园网 IP",
    D_V6: "本机 v6 直连（免费），目标没有 v6 就连不上",
    D_ANY: "本机直连（系统决定 v4/v6）",
}

# 基础分组：(名称, 说明)
BASE_GROUPS = [
    (ENTRY, "所有「免流」流量的第一跳。在校园网选 Oracle v6（hy2 更快、reality 走 TCP 更稳）；"
            "离开校园网（没有 v6）时切到「直连」，其他分组自动跟着变成普通代理。"),
    (ABROAD, "国外网站的默认落地，也是没被任何规则匹配到的流量的兜底。默认「家宽Sixtynet」（经免流入口，免费）；"
             "带「·v4直连」的是本机直接用 v4 连过去，延迟低但计费。大多数业务分组默认跟随这里。"),
    (CN6, "国内网站且查得到 v6 地址时走这里。默认「直连·仅v6」，校园网 v6 免费。"),
    (CN4, "国内网站但只有 v4 时走这里。默认「免流入口」（从 Oracle 出去，免费但对方看到美国 IP、延迟较高）；"
          "遇到不认海外 IP 的网站，可临时切到「直连·仅v4」（计费）。"),
]

# 业务分组：(名称, 说明, 匹配条件, 默认出口, 位置)。规则集用 "kind/name" 表示 MetaCubeX 的 geosite/geoip 文件
SERVICE_GROUPS = [
    ("⌨️ 豆包输入法", "按进程匹配豆包输入法的所有联网。默认本机 v4 直连，避免被当成海外 IP。",
     {"process": [r"/DoubaoIme\.app/"]}, D_V4, "before_cn"),
    ("💬 微信", "按进程匹配微信全部流量（含表情包、小程序）。默认 v6 优先直连：有 v6 免费，没有则 v4 计费；"
              "不走 Oracle，避免表情包等资源因海外 IP 加载失败。",
     {"process": [r"/微信\.app/", r"/WeChat\.app/"]}, D_V6PREF, "before_cn"),
    ("🤖 AI", "ChatGPT、Claude、Gemini、Perplexity 等海外 AI 服务。默认「搬瓦工→Sixtynet家宽·v4直连」"
             "（家宽 IP，延迟低，计费）；想省流量可切到不带 ·v4直连 的版本。",
     {"rule_sets": ["geosite/category-ai-!cn", "geosite/openai", "geosite/anthropic", "geosite/google-gemini"]},
     "🇺🇸 搬瓦工→Sixtynet家宽" + V4_SUFFIX, "before_cn"),
    ("📢 谷歌推送", "Google FCM 推送通道（安卓模拟器、部分 App 的消息推送）。",
     {"rule_sets": ["geosite/googlefcm"]}, ABROAD, "before_cn"),
    ("📺 YouTube", "YouTube 视频与 App。流量大，默认跟随国外（免流）。",
     {"rule_sets": ["geosite/youtube"]}, ABROAD, "before_cn"),
    ("🎬 流媒体", "Netflix、Disney+、Spotify。需要解锁特定地区时在这里换落地。",
     {"rule_sets": ["geosite/netflix", "geosite/disney", "geosite/spotify"]}, ABROAD, "before_cn"),
    ("✈️ Telegram", "Telegram 的域名与 IP 段。",
     {"rule_sets": ["geosite/telegram", "geoip/telegram"]}, ABROAD, "before_cn"),
    ("🐦 社交媒体", "X/Twitter、Facebook/Instagram、TikTok。",
     {"rule_sets": ["geosite/twitter", "geosite/facebook", "geosite/tiktok"]}, ABROAD, "before_cn"),
    ("🐙 GitHub", "GitHub 网页、代码下载、Release。",
     {"rule_sets": ["geosite/github"]}, ABROAD, "before_cn"),
    ("🛠 开发者", "Docker、npm、JetBrains 等开发相关站点（不含 GitHub）。",
     {"rule_sets": ["geosite/category-dev", "geosite/docker"]}, ABROAD, "before_cn"),
    ("🇬 谷歌服务", "Google 搜索、Gmail、Drive 等（Gemini 归 AI，YouTube 单独分组）。",
     {"rule_sets": ["geosite/google"]}, ABROAD, "before_cn"),
    ("Ⓜ️ 微软", "Microsoft、OneDrive、Bing、Office、Windows 更新（含国内 CDN）。",
     {"rule_sets": ["geosite/microsoft", "geosite/onedrive"]}, ABROAD, "before_cn"),
    ("🍎 苹果", "Apple 全部服务（App Store、iCloud、系统更新，含国内 CDN）。默认从 Oracle 出去（免费）。",
     {"rule_sets": ["geosite/apple"]}, ENTRY, "before_cn"),
    ("🎮 Steam", "Steam 商店与下载。下载流量大，默认从 Oracle 出去，不占家宽带宽。",
     {"rule_sets": ["geosite/steam"]}, ENTRY, "before_cn"),
    ("🅾️ Oracle", "甲骨文云控制台等。默认跟随国外，保持固定落地 IP 便于账号风控。",
     {"rule_sets": ["geosite/oracle"]}, ABROAD, "before_cn"),
    ("🚀 测速", "Speedtest、fast.com 等测速网站，想测哪条线路就切到哪条。",
     {"rule_sets": ["geosite/category-speedtest"]}, ABROAD, "before_cn"),
    ("🎯 海外游戏", "海外游戏平台与游戏（国内游戏已在前面按国内规则处理）。默认从 Oracle 出去。",
     {"rule_sets": ["geosite/category-games"]}, ENTRY, "after_cn"),
]

# 固定入口（面板里只做说明，不可切换）
INFO_PAGES = [
    ("🏠 HK家宽(10809)", "本地端口 127.0.0.1:10809 专供指纹浏览器，全部流量固定走 HK 家宽、本机 v4 直连（计费）。"
                        "与其他分组完全隔离，切换任何分组都不影响它。"),
]
