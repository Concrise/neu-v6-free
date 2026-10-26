# 配置参考

设置写在 YAML 文件里（复制 [config.example.yaml](../config.example.yaml) 为 `config.yaml`），所有项都可以省略。
默认值和更细的注释见 [lib/build.js](../lib/build.js) 开头的 `DEFAULTS`。

## 命令行

```bash
node cli.js [-c config.yaml ...] [-p mac,windows,android,ios | -p all] [-o out] [--sub-file sub.yaml] [--no-tun]
```

| 参数 | 作用 |
|---|---|
| `-c` | 设置文件，可以给多个，后面的覆盖前面的同名项（适合把可以公开的和含密码的分开放）。默认 `config.yaml` |
| `-p` | 生成哪些平台，默认 `mac`；`all` = 四个都生成 |
| `-o` | 输出目录，默认 `out`。结果在 `<输出目录>/<平台>/` |
| `--sub-file` | 用本地的订阅文件，不从 `subscription_url` 下载 |
| `--no-tun` | 不要 TUN（只用 10808 端口当普通代理） |

mac 和 windows 会顺便下载规则集到 `rules/`，所以生成时要能访问 GitHub。

## 基本

| 选项 | 默认 | 说明 |
|---|---|---|
| `clash_api_secret` | 空 | 面板密钥。**一定要填**，随机长字符串 |
| `subscription_url` | — | 机场订阅（Clash / mihomo 格式） |
| `nodes` | — | 直接写节点（mihomo 格式），和订阅合并 |
| `default_landing` | 第一个节点 | 「国外网站」默认用哪个节点（节点名） |
| `exclude_nodes_regex` | — | 不作为落地的节点名（正则） |
| `display_names` | — | 节点名 → 面板里的显示名 |

## 第二部分：自己的服务器

| 选项 | 默认 | 说明 |
|---|---|---|
| `entry_servers` | 空 | 服务器的 IPv4 → `{ v6, label, hy2_brutal?, landing? }`。有它就是第二部分。服务器节点本身写在 `nodes` 或订阅里 |
| `entry_default` | 自动选最快 | 「免流服务器」默认用第一台服务器的哪个协议：`vless`（Reality）/ `hysteria2` / `tuic` / `anytls` |
| `hy2_brutal` | 不用 | 自己服务器的 Hysteria2 用 Brutal：`{ up_mbps, down_mbps }`，可在 `entry_servers` 里按服务器单独设 |
| `landings_via_entry` | `true` | 订阅节点默认先经免流服务器（免费），另留一个「（直连 v4）」副本 |
| `entry_group_aliases` | 空 | 订阅里 `dialer-proxy` 指向这些组名时，视为「先经免流服务器」 |

## 分组与规则

| 选项 | 默认 | 说明 |
|---|---|---|
| `group_defaults` | — | 分组名 → 默认出口，覆盖内置默认（面板里的选择会一直保存，这里只决定初始值） |
| `custom_rules` | 空 | 写在设置里的规则，见 [rules.md](rules.md) |
| `user_rules` | `true` | 是否生成「我的规则」（macOS 后台服务和 Windows 才有） |
| `group_notes` / `base_notes` / `option_notes` | — | 面板里分组、总开关、选项的说明文字，覆盖内置的 |

## 校园网相关

用在其他学校时主要改这几项：

| 选项 | 默认 | 说明 |
|---|---|---|
| `direct_domains` | `["neu.edu.cn"]` | 校园网内网域名，一律直连 |
| `cn_dns_v6` | `2400:3200::1` | 查国内域名用的 IPv6 DNS（很多 CDN 只对 IPv6 来源的查询返回 IPv6 地址） |
| `cn_dns_v4` | `223.5.5.5` | IPv4 DNS |
| `v6_broken_cidrs` | 腾讯的一个网段 | 有 IPv6 地址但从校园网实测连不通的网段：直接拒绝，让 App 立刻回退 IPv4 |
| `v6_aliases` | 腾讯下载 | 只有 IPv4 的域名 → 同一 CDN 上有 IPv6 的域名（连接目标改过去再 v6 直连） |

## 桌面端口与安装位置

| 选项 | 默认 | 说明 |
|---|---|---|
| `listen` / `main_port` | `127.0.0.1` / `10808` | 普通代理端口（HTTP 和 SOCKS5 都行） |
| `clash_api` | `127.0.0.1:9090` | 面板地址 |
| `traffic_port` | `9091` | 本地助手端口 |
| `fixed_ports` | 空 | 每个端口固定走一个出口，不受分组影响：`{ port, outbound, page? }`，`outbound` 可以是出口名或 sing-box 出站对象 |
| `panel_pages` | — | 固定端口说明页：页名 → 说明 |
| `rules_dir` / `panel_dir` | `/usr/local/etc/neu-v6-free/…` | macOS 安装位置，要和 `mac/install.sh` 的 `NAME` 一致 |
| `windows_panel_dir` / `windows_rules_dir` | `C:/neu-v6-free/…` | Windows 安装位置，安装目录 = 面板目录的上一级 |
| `cache_file` | `neu-v6.cache.db` | sing-box 缓存文件（相对 sing-box 工作目录） |
| `rule_set_base` | MetaCubeX | 国内 IP 与其他服务分组的规则集地址；国内域名主名单使用单独转换的 ChinaMaxNoIP |
| `mac_app` | `false` | macOS 用 sing-box 官方 App 而不是后台服务（在线规则集、没有网页面板） |
| `tun` | `true` | 是否接管全部流量（TUN） |
