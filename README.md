# neu-v6-free

东北大学校园网 IPv6 免流工具。它生成一份 [sing-box](https://github.com/SagerNet/sing-box) 配置，让能走 IPv6 的流量都走 IPv6（校园网不计费），
并带一个网页面板：随时切换线路、看每个连接走哪条路、一键改规则，改完 1–2 秒生效。

有一台自己的双栈服务器的话，只有 IPv4 的网站也能免费访问（IPv6 连到服务器，服务器再用 IPv4 访问）。

> 其他「IPv6 免费、IPv4 计费」的校园网也能用：把 `direct_domains` 改成你们学校的域名即可，见 [配置参考](docs/config.md)。

![面板概览](docs/images/panel-home.png)

## 为什么需要它

校园网 IPv6 流量不计费，IPv4 按流量计费。但是：

- 很多国内网站（B 站、淘宝、腾讯、网易……）其实有 IPv6，系统和 App 却经常优先用 IPv4；有的 DNS 根本不返回 IPv6 地址，白白计费。
- 只有 IPv4 的网站、国外网站，直接访问一定计费。

这个工具把这些情况都处理好：国内 DNS 走 IPv6 查询（很多 CDN 只给 IPv6 来源返回 IPv6 地址），有 IPv6 的一律直连 IPv6；
实测校园网 IPv6 连不通的网段直接拒绝，让 App 立刻回退，不用干等超时；微信、网易云、英雄联盟等按整个 App 处理，避免被当成海外用户。

## 两部分：先省流，再免流

| | 第一部分：v6 优先省流 | 第二部分：自带服务器免流 |
|---|---|---|
| 需要什么 | 什么都不需要 | 一台有 IPv4 + IPv6 的 VPS |
| 有 IPv6 的国内网站 | IPv6 直连，**免费** | IPv6 直连，**免费** |
| 只有 IPv4 的国内网站 | IPv4 直连，计费 | IPv6 连服务器 → 服务器用 IPv4 访问，**免费** |
| 国外网站 | 你的机场节点（节点有 IPv6 地址时免费）或直连 | 经服务器，或经服务器再到你的其他节点，**免费** |
| 调整规则 | ✅ 面板里随时改 | ✅ 面板里随时改 |

第二部分就是在第一部分的设置里加上服务器信息，其他都一样。可以先用第一部分，以后随时加服务器。

## 功能

- **一个完整的客户端**：下载安装包、双击安装，订阅、节点、服务器都在网页面板里管，不用装 Node、不用碰命令行。
- **订阅与节点**：加机场订阅（Clash / mihomo、sing-box、v2rayN 格式都认），或粘贴节点链接（vless / vmess / trojan / ss / hy2 / tuic / anytls）。
  每个订阅自成一组、自动选最快，都当「落地」用；显示剩余流量和到期时间，「剩余流量」这类假节点自动排除。
- **新手引导**：第一次打开时一步步带你加订阅或服务器、应用并检查能不能上网。
- **代理方式**：智能分流 / 全部走代理 / 全部直连，一键切换。
- **网页面板**（`http://127.0.0.1:9090/ui`，App 窗口里也是它）：概览、线路与规则、订阅与节点、设置四页；每类网站走哪条线路，点一下立即生效、自动保存。
- **我的规则**：「线路与规则」里粘贴网址、域名、IP 或程序名，选去向，1–2 秒生效，不用重新生成配置。
- **实时连接**（设置 → 诊断）：看每个连接是哪个程序发起的、为什么走这条路、免费还是计费；走得不对点「改规则」。
- **流量统计**（macOS、Windows）：本月 v6 直连省了多少、经服务器免流省了多少、v4 计费用了多少。
  点击概览中的流量卡片，可以看各网站的流量排名和占比，支持切换月份。网站明细从升级后开始记录，只保存在本机，保留最近 3 个月，查看需要面板密钥；升级前及无法归属的流量单独合并显示。
  更新后请点面板上方的「应用」，启用新版的国内域名识别和 IPv6 判断规则；订阅、设置和分组选项继续保留。
  排名和实时连接中的纯 IPv6 地址会尝试补充网络服务商及 ASN。信息来自 Team Cymru 的 DNS 查询，仅发送 /64 网络前缀；查询失败不影响联网和统计，网络所属机构也不等同于具体网站。
- **日志**：sing-box 的警告和错误实时显示，节点连不上、规则集出错一眼看到。
- **只有第一次安装要管理员权限**：之后更新配置交给后台的本地助手，不用再输密码。
- **自动检查更新**：本地助手每天查一次 GitHub 上的新版本，面板里一键更新（下载后按 SHA256 校验，不用管理员密码，订阅、设置、我的规则都保留）。
- **断网保护**：装完、更新后、运行中都会检查，经 sing-box 上不了网就暂停 sing-box 或换回旧配置，电脑回到普通网络。见下方[断网保护](#断网保护)。
- **启动不依赖网络**：电脑上规则集随配置一起装，服务器不通时也能正常上网。

| 线路与规则 | 实时连接 · 改规则 |
|---|---|
| ![线路与规则](docs/images/panel-rules.png) | ![改规则](docs/images/panel-conn-modal.png) |

## 支持的平台

| 平台 | 运行方式 | 网页面板 | 我的规则 | 流量统计 | 按 App 分流 |
|---|---|---|---|---|---|
| macOS | 后台服务（推荐） | ✅ | ✅ | ✅ | ✅ |
| Windows 10 / 11 | 后台服务 | ✅ | ✅ | ✅ | ✅ |
| Android | sing-box 官方 App | App 内切换分组 | 写在设置里 | — | ✅（包名） |
| iOS | sing-box 官方 App | App 内切换分组 | 写在设置里 | — | — |
| macOS（不想装后台服务） | sing-box 官方 App | App 内切换分组 | 写在设置里 | — | ✅ |

## 快速开始

### 1. 下载安装

到 [Releases](https://github.com/Concrise/neu-v6-free/releases) 下载安装程序。安装前先退出其他代理软件（Clash、v2rayN、FlClash 等，托盘右键退出）。

- **macOS**：`neu-v6-free-<版本>-macos.pkg`，双击安装，输入电脑密码。安装程序没有经过苹果公证，被拦下时到
  「系统设置 → 隐私与安全性」底部点「仍要打开」。装好后会打开「校园网 v6 免流」App：窗口里是面板，菜单栏有 v6 图标（看状态、暂停 / 重新启用、今天的流量）；退出 App 不影响免流。详见 [docs/macos.md](docs/macos.md)。
- **Windows 10 / 11**：`neu-v6-free-<版本>-windows-setup.exe`，双击安装，管理员确认点「是」。没有数字签名，弹出「Windows 已保护你的电脑」时
  点「更多信息 → 仍要运行」。装到 `C:\neu-v6-free`，开始菜单和桌面有「校园网 v6 免流」，卸载在「设置 → 应用」。详见 [docs/windows.md](docs/windows.md)。

安装程序自带 sing-box 内核，不用另外下载。只有这一次要管理员权限。装完会自检，不通就暂停 sing-box、电脑回到普通网络；
通过后自动打开「校园网 v6 免流」App：窗口里是面板（自动登录，面板密钥是安装时随机生成的），菜单栏 / 托盘里有 v6 图标，能看运行状态、暂停 / 重新启用、看今天的流量。关掉窗口、退出 App 都不影响免流。

装好时是**第一部分**：有 IPv6 的国内网站已经在走 v6 免费了。

### 2. 在面板里加订阅和服务器

面板 `http://127.0.0.1:9090/ui`：

1. **📦 订阅与节点**：粘贴机场订阅链接，或者粘贴节点链接。它们都是「落地」，在「国外网站」和 AI、YouTube 等分组里选用。
2. **有自己的双栈服务器（第二部分）**：服务器上运行 [server/setup.sh](server/setup.sh)，把它最后输出的那一段原样粘进「订阅与节点」的手动添加框，
   就会加好节点并设为免流服务器。也可以在「⚙️ 设置」→「免流服务器」里手动选节点、填 IPv6。
3. 点页面上方的「**应用**」：生成新配置、检查、重启 sing-box；新配置上不了网会自动换回旧的。

**Android / iOS**：装 sing-box 官方 App，导入生成的配置，见 [docs/mobile.md](docs/mobile.md)。

### 3. 以后

| 想做什么 | 怎么做 | 需要管理员？ |
|---|---|---|
| 换线路、换服务器 | 面板「线路与规则」，或订阅卡片上的下拉框 | 不需要，立即生效 |
| 临时全部走代理 / 全部直连 | 面板「概览」→「现在怎么走」右上角：智能分流 / 全部走代理 / 全部直连 | 不需要，立即生效 |
| 某个网站或 App 走得不对 | 面板「线路与规则」粘贴网址选去向，或「设置 → 诊断 → 实时连接」→「改规则」 | 不需要，1–2 秒生效 |
| 加订阅、更新订阅、加节点、改服务器 | 面板「订阅与节点」「设置」，改完点「应用」 | 不需要 |
| 离开校园网（没有 IPv6） | 连不上服务器时自动改走「不用服务器」，能连上自动切回；也可以手动选 | 不需要 |
| 上不了网 / 想临时关掉 | 会自动暂停；也可以面板「概览」→「暂停」，或打开 `http://127.0.0.1:9091/` | 不需要 |
| 升级到新版本 | 有新版本时面板侧栏「设置」上会提示，在「设置 → 版本与更新」点「更新」；装完点一次「应用」 | 不需要 |

调整规则的完整说明见 [docs/rules.md](docs/rules.md)。

### 高级：用命令行生成

想把设置写在文件里管理（或自己改生成器）：需要 [Node.js](https://nodejs.org/) 18 以上和 [Go](https://go.dev/dl/)（本地助手是 Go 写的，生成时顺便编译）。

```bash
git clone https://github.com/Concrise/neu-v6-free.git
cd neu-v6-free
cp config.example.yaml config.yaml   # 按注释填写
node cli.js -p mac                   # 或 -p windows、-p android、-p ios、-p all；结果在 out/<平台>/
sudo mac/install.sh                  # Windows：双击 out\windows\install.bat
```

以后改了 `config.yaml`：重新生成，macOS 运行 `mac/update.sh`、Windows 双击新生成目录里的 `update.bat`（都不用管理员）。
命令行生成的设置会同步到面板里；之后再用命令行更新，会用文件里的设置覆盖面板里改的。
发布新版本：改 `package.json` 的版本号，提交并推送，等 GitHub Actions 的「Windows App」编译完（Windows 的 App 在那里编译），
再运行 `node cli.js --package -o dist`（需要 `brew install makensis go` 编译 Windows 安装程序和本地助手、`gh` 下载编好的 Windows App，
macOS 的 App 用本机的 swiftc 编译），
得到 macOS 的 `.pkg`、Windows 的 `-setup.exe`（都自带 sing-box）、两个 `.zip`（自动更新用）和 `SHA256SUMS`，
再 `gh release create v<版本> dist/*.pkg dist/*.exe dist/*.zip dist/SHA256SUMS`。已经装好的客户端会在一天内发现并提示更新。

还有一个不用装任何东西的[网页生成器](web/)（本地打开要先在仓库目录运行 `python3 -m http.server 8765`，再访问 `http://127.0.0.1:8765/web/`），
在浏览器里生成各平台的配置，不上传任何内容。

## 断网保护

这个工具会接管整台电脑的网络，所以它的第一原则是**绝不能让你断网**：

- **装完自检**：安装后立刻测一次。经 sing-box 上不了网、绕过它却能上，就暂停 sing-box（安全模式），电脑回到普通网络，并说明原因；排除问题后在 App 或状态页点「重新启用」。
- **更新自检**：新配置装上后不通，自动换回旧配置。
- **运行中看门狗**：本地助手每 30 秒检查一次，连续 3 次「经 sing-box 不通、绕过它能通」就暂停 sing-box（安全模式），电脑回到普通网络。离开校园网连不上服务器时也会这样。sing-box 反复崩溃也会停手。
- **随时手动暂停**：面板「概览」里的「暂停」；或打开本地助手的状态页 `http://127.0.0.1:9091/`（sing-box 停着时面板打不开，状态页还在），在那里暂停或重新启用。
- **安装前清理**：别的代理软件退出后留下的失效系统代理（指向已经没有程序监听的端口）会被关掉；代理环境变量会提示出来。

暂停后的状态重启电脑也保持，直到你重新启用、更新配置或重新安装。

## 第二部分：加上自己的服务器

1. 准备一台有公网 IPv4 + IPv6 的 Debian / Ubuntu VPS。
2. 把 [server/setup.sh](server/setup.sh) 传上去，以 root 运行 `bash setup.sh`：装好 sing-box，开 Reality / AnyTLS / Hysteria2 / TUIC 四个入站。
3. 云平台安全组放行它提示的端口（IPv4 和 IPv6 都要）。
4. 把它最后输出的那段原样粘进面板「订阅与节点」的手动添加框，点「应用」（命令行用户粘进 `config.yaml`，重新生成并更新）。

详见 [docs/server.md](docs/server.md)。注意服务器的出站流量通常计费（例如 Azure 亚洲区每月前 100GB 免费），校园网下载的数据都会从服务器发出。

## 文档

- [macOS](docs/macos.md)：安装、更新、卸载、文件位置、排错
- [Windows](docs/windows.md)：安装、更新、卸载、文件位置、排错
- [Android / iOS](docs/mobile.md)
- [自己的服务器（第二部分）](docs/server.md)
- [调整规则](docs/rules.md)：分组、我的规则、写在设置里的规则、分流顺序
- [配置参考](docs/config.md)：`config.yaml` 的全部选项
- [常见问题与工作原理](docs/faq.md)

## 目录结构

```
cli.js              命令行生成器
lib/                生成逻辑（命令行、网页生成器、面板共用）：groups.js 是分组与规则定义，build.js 生成 sing-box 配置，
                    subscription.js 解析订阅与节点链接，convert.js 把节点转成 sing-box 出站
panel/              网页面板（单个 HTML 文件；安装时 lib/ 一起装进 panel/lib/，面板在浏览器里生成配置）
helper/             本地助手（Go，单个程序，不依赖任何东西）：启动并看着 sing-box、我的规则、流量统计、安装新配置和更新，
                    安装 / 卸载也是它（neu-v6-free install / uninstall）；GitHub Actions 上编译检查
mac/                macOS 安装 / 更新 / 卸载的包装脚本；pkg/ 是 .pkg 安装程序的资源，app/ 是 App（Swift）
windows/            Windows 安装 / 更新 / 卸载的 .bat；installer.nsi 是 setup.exe 的 NSIS 脚本，
                    app/ 是 App（C# + WebView2，在 GitHub Actions 上编译：.github/workflows/windows-app.yml）
licenses/           随安装程序附带的第三方许可证（sing-box 的 GPLv3 全文）
server/setup.sh     第二部分的服务器一键部署脚本
web/                网页生成器
docs/               文档
personal/           作者自用的配置（可以当填写示例参考）
```

## 安全与隐私

- 生成的配置里有你的节点密码和面板密钥，不要发到群里或公开。
- 面板和本地助手只监听 `127.0.0.1`，都要求面板密钥；本地助手只接受面板页面的跨域请求，更新接口不接受任何网页发来的请求。
- 本地助手以管理员身份运行。它安装新配置前会检查配置里所有文件路径都在安装目录内，并用 `sing-box check` 验证，不通过就不动旧配置。
- 国内域名识别采用 [blackmatrix7 ChinaMaxNoIP](https://github.com/blackmatrix7/ios_rule_script/tree/master/rule/Shadowrocket/ChinaMaxNoIP)，合并 `ChinaMaxNoIP.list` 与 `ChinaMaxNoIP_Domain.list` 的精确域名、域名后缀和关键词规则，转换为 sing-box 原生格式。`USER-AGENT` 匹配不适用于 sing-box 网络层，未纳入转换；原始名单、转换脚本与 GPLv2 许可随规则源码包提供。
- 国内 IP 和其他服务分组仍使用 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)。ChinaMaxNoIP 只负责识别国内，出口仍按 IPv6 判断与用户选择决定，不将名单里的 `DIRECT` 照搬为强制直连。

## 许可证

项目代码使用 [MIT](LICENSE)。随包提供的 ChinaMaxNoIP 规则数据使用 [GPLv2](licenses/GPL-2.0.txt)，sing-box 使用 GPLv3。
