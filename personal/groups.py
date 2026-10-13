"""分组定义：面板展示顺序、用途说明、匹配规则与默认出口。

路由优先级（从上到下，命中即停，因此不会冲突）：
  HK 入口 → 局域网/校园网 → 按进程（豆包、微信）→ BEFORE_CN 业务分组
  → 国内域名（有 v6 → 国内v6，否则 国内v4）→ AFTER_CN 业务分组 → 国内 IP → ② 国外出口（兜底）
"""

ENTRY, ABROAD, CN6, CN4 = "① 免流隧道", "② 国外出口", "③ 国内·有IPv6", "④ 国内·仅IPv4"
ORACLE_EXIT = "隧道直出"  # 只含 ① 的分组：作为「出口」时语义是「从隧道入口那台服务器直接出去」
D_V6PREF, D_V4, D_V6 = "本机直连·IPv6优先", "本机直连·仅IPv4", "本机直连·仅IPv6"
D_ANY = "不走隧道（本机直连）"
AUTO = "自动选择（最快可用）"  # ① 里的 urltest：定时测速，自动避开挂掉的入口
FREE, V4 = "[免流] ", "[v4直连] "  # 节点前缀：第一跳走 ① 免流隧道（免费） / 本机 v4 直接连（计费）

# 订阅节点名 → 面板显示名（不含前缀）。中转链写成「落地 · 经X中转」，避免和链路箭头混淆
DISPLAY_NAMES = {
    "🇺🇸 家宽Sixtynet": "美国家宽 Sixtynet",
    "🇺🇸 搬瓦工→Sixtynet家宽": "美国家宽 Sixtynet · 经搬瓦工中转",
    "🇺🇸 DMIT→Sixtynet家宽": "美国家宽 Sixtynet · 经DMIT中转",
    "🇺🇸 DMIT-圣何塞": "DMIT 圣何塞 · 机房IP",
    "🇺🇸搬瓦工-洛杉矶": "搬瓦工 洛杉矶 · 机房IP",
    "🇩🇪 Netcup-AnyTLS": "Netcup 德国 · AnyTLS",
    "🇩🇪 Netcup-Reality": "Netcup 德国 · Reality",
    "🇩🇪 Netcup-VMess-WS": "Netcup 德国 · VMess",
    "🇩🇪 Netcup-Hysteria2": "Netcup 德国 · Hysteria2",
    "🇩🇪 Netcup-TUIC": "Netcup 德国 · TUIC",
    "Netcup-CF-家庭WiFi-联通-SJC": "Netcup CF优选 · 联通SJC",
    "Netcup-CF-手机流量-移动-FRA": "Netcup CF优选 · 移动FRA",
    "Netcup-CF-家庭WiFi-联通-LAX-1": "Netcup CF优选 · 联通LAX",
}

# 出口选项的说明（面板里显示在选项下方）
OPTION_NOTES = {
    ORACLE_EXIT: "走 ① 免流隧道，直接从入口那台服务器出去（目前是 Netcup 德国机房 IP，免费）",
    ABROAD: "跟随「② 国外出口」的选择",
    CN6: "跟随「③ 国内·有IPv6」",
    CN4: "跟随「④ 国内·仅IPv4」",
    D_V6PREF: "有 IPv6 走 v6（免费），否则 v4（计费）",
    D_V4: "只用 IPv4（计费），对方看到校园网 IP",
    D_V6: "只用 IPv6（免费），目标没有 v6 就连不上",
    D_ANY: "不走隧道。离开校园网（没有 v6）时选这个",
    AUTO: "每 3 分钟测一次所有入口，自动用最快且可用的；某台服务器挂了会自动换",
}

# 基础分组：(名称, 说明)
BASE_GROUPS = [
    (ENTRY, "决定流量怎么离开校园网（第一跳）。所有带 [免流] 的节点和「隧道直出」都先走这里。"
            "默认「自动选择」：定时测速，自动用最快且可用的入口，某台服务器挂了会自动换。"
            "也可手动指定某个入口协议（Hysteria2/TUIC 走 UDP 通常更快，Reality/AnyTLS 走 TCP 更稳）。"
            "离开校园网时选「不走隧道」，[免流] 节点会自动变成普通直连代理。"),
    (ABROAD, "国外网站最终从哪里出去（落地），也是所有没被规则匹配到的流量的兜底。"
             "[免流] = 先走 ① 隧道再到该落地（免费）；[v4直连] = 本机直接用 IPv4 连该落地（延迟低、计费）。"
             "大多数业务分组默认「跟随② 国外出口」，改这里它们一起变。"),
    (CN6, "国内网站、且查得到 IPv6 地址时走这里。默认「本机直连·仅IPv6」，校园网 v6 免费。"),
    (CN4, "国内网站、但只有 IPv4 时走这里。默认「隧道直出」（免费，但对方看到海外机房 IP、延迟较高）；"
          "遇到不认海外 IP 的网站，可临时切到「本机直连·仅IPv4」（计费）。"),
]

# 业务分组：(名称, 说明, 匹配条件, 默认出口, 位置)。规则集用 "kind/name" 表示 MetaCubeX 的 geosite/geoip 文件
SERVICE_GROUPS = [
    ("⌨️ 豆包输入法", "按进程匹配豆包输入法的所有联网。默认「本机直连·仅IPv4」，避免被当成海外 IP。",
     {"process": [r"/DoubaoIme\.app/"]}, D_V4, "before_cn"),
    ("💬 微信", "按进程匹配微信全部流量（含表情包、小程序）。默认「本机直连·IPv6优先」：有 v6 免费，没有则 v4 计费；"
              "不走 Oracle，避免表情包等资源因海外 IP 加载失败。",
     {"process": [r"/微信\.app/", r"/WeChat\.app/"]}, D_V6PREF, "before_cn"),
    ("🤖 AI", "ChatGPT、Claude、Gemini、Perplexity 等海外 AI 服务。默认「[v4直连] 美国家宽 Sixtynet · 经搬瓦工中转」"
             "（家宽 IP，延迟低，计费）；想省流量可切到 [免流] 版本。",
     {"rule_sets": ["geosite/category-ai-!cn", "geosite/openai", "geosite/anthropic", "geosite/google-gemini"]},
     V4 + "美国家宽 Sixtynet · 经搬瓦工中转", "before_cn"),
    ("📢 谷歌推送", "Google FCM 推送通道（安卓模拟器、部分 App 的消息推送）。",
     {"rule_sets": ["geosite/googlefcm"]}, ABROAD, "before_cn"),
    ("📺 YouTube", "YouTube 视频与 App。流量大，默认跟随「② 国外出口」。",
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
    ("🍎 苹果", "Apple 全部服务（App Store、iCloud、系统更新，含国内 CDN）。默认「隧道直出」（免费）。",
     {"rule_sets": ["geosite/apple"]}, ORACLE_EXIT, "before_cn"),
    ("🎮 Steam", "Steam 商店与下载。下载流量大，默认「隧道直出」，不占家宽带宽。",
     {"rule_sets": ["geosite/steam"]}, ORACLE_EXIT, "before_cn"),
    ("🅾️ Oracle", "甲骨文云控制台等。默认跟随「② 国外出口」，保持固定落地 IP 便于账号风控。",
     {"rule_sets": ["geosite/oracle"]}, ABROAD, "before_cn"),
    ("🚀 测速", "Speedtest、fast.com 等测速网站，想测哪条线路就切到哪条。",
     {"rule_sets": ["geosite/category-speedtest"]}, ABROAD, "before_cn"),
    ("🎯 海外游戏", "海外游戏平台与游戏（国内游戏已在前面按国内规则处理）。默认「隧道直出」。",
     {"rule_sets": ["geosite/category-games"]}, ORACLE_EXIT, "after_cn"),
]

# 固定入口（面板里只做说明，不可切换）
INFO_PAGES = [
    ("🏠 HK家宽(10809)", "本地端口 127.0.0.1:10809 专供指纹浏览器，全部流量固定走 HK 家宽、本机 v4 直连（计费）。"
                        "与其他分组完全隔离，切换任何分组都不影响它。"),
]
