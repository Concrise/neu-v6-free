# neu-v6-free

东北大学校园网 IPv6 免流的 sing-box 配置生成器。校园网 IPv6 流量不计费、IPv4 计费，这个工具尽量让流量走 v6。

`personal/` 是作者自用的配置（不含密钥与服务器 IP），可以当填写示例参考，用不到可以忽略。

## 两种模式

| | 模式一：v6 优先直连 | 模式二：自带双栈服务器 |
|---|---|---|
| 需要 | 什么都不需要（可选：自己的机场订阅） | 一台有 IPv4 + IPv6 的 VPS |
| 国内有 v6 的站 | v6 直连，免费 | v6 直连，免费 |
| 国内只有 v4 的站 | v4 直连，计费 | 经服务器出去（v6 进、v4 出），免费 |
| 国外 | 走订阅节点（节点有 v6 地址就免费）或直连 | 经服务器，或经服务器再到其他落地，免费 |

两种模式都会做这些事：
- 国内域名用 IPv6 DNS（`2400:3200::1`）查询：很多国内 CDN 只对 v6 来源的查询返回 v6 地址。
- 有 v6 地址的国内资源一律 v6 直连，优先级高于所有按站点分的规则。
- v6 放在单独域名上的服务（如腾讯下载）改写到 v6 域名。
- 校园网 v6 实测不通的网段直接拒绝，让 App 立刻回退 v4，不用干等超时。
- 微信、网易云等按 App 整体直连（v6 优先），避免被当成海外 IP。

## 平台

| 平台 | 客户端 | 按 App 分流 | 切换分组 |
|---|---|---|---|
| macOS | sing-box 后台服务（`mac/install.sh`） | ✅ 程序路径 | 网页面板 `http://127.0.0.1:9090/ui` |
| Windows | v2rayN「自定义配置」，内核选 sing-box | ✅ exe 名 | 网页面板 |
| Android | sing-box 官方 App | ✅ 包名 | App 内 |
| iOS | sing-box 官方 App | ❌ 系统不支持 | App 内 |

## 网页生成器（不用装任何东西）

打开 `web/index.html` 页面（开启 GitHub Pages 后就是 `https://<用户名>.github.io/<仓库名>/web/`）：
1. 选模式。
2. 粘贴服务器脚本的输出和（或）机场订阅内容。
3. 给每个分组选默认出口。
4. 下载各平台的配置。

所有处理都在浏览器里完成，不上传任何内容。网页和命令行用的是同一份生成代码（`lib/`），同样的输入得到完全相同的配置。

本地打开要用 HTTP 服务（ES 模块不能从 `file://` 加载）：

```bash
python3 -m http.server 8765
```

然后访问 `http://127.0.0.1:8765/web/`。

## 命令行用法

需要 Node.js 18 以上。

```bash
cp config.example.yaml config.yaml   # 按注释填写；纯直连可以什么都不填
node cli.js -p all                   # 生成四个平台：out/<平台>/config.json
```

- 多个配置文件可以叠加：`node cli.js -c config.yaml -c secrets.local.yaml`，后面的覆盖前面的同名项。适合把可以公开的设置和含密码的设置分开放。
- 本地订阅文件：`--sub-file sub.yaml`。

### 模式二：部署服务器

准备一台有公网 IPv4 + IPv6 的 Debian / Ubuntu VPS。登录后以 root 运行：

```bash
bash setup.sh
```

`setup.sh` 在仓库的 `server/` 目录里，可以先 scp 到服务器。它会做这些事：
- 安装官方 sing-box，开 Reality / AnyTLS（TCP）和 Hysteria2 / TUIC（UDP）四个入站，都监听 IPv4 与 IPv6。
- 端口默认随机，可以用 `PORTS="a b c d"` 指定。
- 没开 BBR 的话顺便开上。
- 最后输出一段设置，原样粘贴进客户端的 `config.yaml` 就是模式二。

再次运行不会换密码，只会重新输出这段设置；`bash setup.sh --show` 只输出不改动。脚本**不改防火墙**，只告诉你要放行哪些端口：云平台的安全组要放行，本机如果开了防火墙也要放行，IPv4 和 IPv6 都要。

服务器出站流量通常计费（比如 Azure 亚洲区每月前 100GB 免费），校园网下载的数据都会从服务器发出，留意额度。

### macOS

```bash
node cli.js -p mac
sudo mac/install.sh /path/to/sing-box     # 装成开机自启的服务（含 TUN）
mac/update.sh                             # 改了配置或订阅后：重新生成并热更新
sudo mac/uninstall.sh                     # 卸载
```

安装前先退出其他代理软件（端口 10808 / 9090 / 9091 不能被占）。

安装 / 更新时会一并装上流量统计服务（`mac/traffic.py`，随服务一起卸载）：每秒按连接的实际出口记账，面板「📊 流量统计」页显示本月 **v6 直连省下多少**、**经服务器免流省下多少**（同时就是服务器的出站消耗，按服务器分开）、以及校园网 v4 计费用了多少。数据存在 `/usr/local/var/<NAME>/traffic.json`，端口可用 `traffic_port` 改。

### Windows

把 `out/windows/panel` 文件夹复制到 `C:\neu-v6-free\panel`（路径可用 `windows_panel_dir` 改）。在 v2rayN 里添加「自定义配置」，选 `out/windows/config.json`，内核选 sing-box，以管理员身份运行（TUN 需要）。

### Android / iOS

在 sing-box App 里新建配置：选「本地」导入 `out/android/config.json` 或 `out/ios/config.json`；也可以放到你自己的网址上，用「远程」导入。

## 离开校园网

没有 IPv6 时：
- 模式二：在「免流服务器」里选「不用服务器（离校时选）」。
- 模式一：所有出口本来就是直连，不受影响。

## 注意

- 生成的配置里有你的节点密码和面板密钥，不要公开分享。
- 规则集来自 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)。
