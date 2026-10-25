# Windows

Windows 10 / 11（x64 或 ARM64）上装成**后台服务**：开机自动运行，带网页面板、订阅管理、「我的规则」和流量统计。
只有第一次安装需要管理员确认，之后更新都不用。不需要 v2rayN。

## 准备

1. **退出其他代理软件**（v2rayN、Clash Verge、FlClash……）：托盘图标右键 → 退出，不是只关窗口。端口 10808、9090、9091 不能被占用。
   - 如果你给命令行工具（比如 Claude Code）设过 `HTTPS_PROXY=http://127.0.0.1:7890` 之类，代理软件一退出它们就连不上。
     装好后在面板「⚙️ 设置」里把代理端口改成 7890，让 sing-box 接替同一个端口，原来的设置照样能用。
2. 到 [Releases](https://github.com/Concrise/neu-v6-free/releases) 下载 `neu-v6-free-<版本>-windows-setup.exe`。

## 安装

双击 `setup.exe`，弹出的管理员确认点「是」（只有这一次）。没有数字签名，弹出「Windows 已保护你的电脑」时点「更多信息 → 仍要运行」。

它会：

1. 把面板、规则集和起步配置装到 `C:\neu-v6-free`，生成随机的面板密钥。
2. 装好自带的 sing-box（1.13.21 官方版，x64 和 ARM64 电脑各用对应的版本）。
3. 注册 Windows 服务「校园网 v6 免流」（`neu-v6-free`）：开机以 SYSTEM 身份运行本地助手，由它启动并看着 sing-box；助手崩溃时系统自动拉起。
4. 关掉失效的系统代理（别的代理软件退出后留下的），提示指向代理软件的环境变量。
5. **自检**：测一次能不能上网。不通就暂停 sing-box（安全模式），电脑回到普通网络，并显示原因；排除问题后在 App 或状态页点「重新启用」。
6. 通过后打开「校园网 v6 免流」App：窗口里是面板（自动登录；sing-box 暂停时显示状态页），右下角托盘有 v6 图标
   （蓝绿 = 正在免流，灰 = 已暂停，橙色感叹号 = 出问题；右键菜单能暂停 / 重新启用、看今天的流量、设开机自动打开）。
   关掉窗口只是藏到托盘，退出 App 也不影响免流。开始菜单和桌面有「校园网 v6 免流」，「设置 → 应用」里登记卸载。
   App 用 WebView2 显示面板：Windows 11 自带，Windows 10 一般随 Edge 装好；缺的话 App 会提示去微软官网装。
   安装目录 `C:\neu-v6-free` 普通用户只能读和运行；有密钥的文件只给管理员和 SYSTEM，App 读的 `panel-secret` 另外允许登录的用户读。
   安装过程的输出都显示在安装窗口里，不通时会说明原因。

不想用安装程序也可以下载 `neu-v6-free-<版本>-windows.zip`，解压后双击 `install.bat`（没有自带 sing-box，会从 GitHub 下载 1.13.21；
也可以在命令行里 `install.bat --singbox D:\path\sing-box.exe` 指定）。安装、卸载、本地助手都是同一个 `neu-v6-free.exe`，不用 PowerShell 脚本。

装好时是第一部分（v6 优先省流）。在面板「📦 订阅与节点」里加订阅或节点，有自己的服务器就把服务器脚本的输出粘进去（见 [server.md](server.md)），点「应用」。

**升级**：有新版本时面板侧栏「设置」上会提示「有更新」，在「设置 → 版本与更新」点「更新」即可，不需要管理员；装完点一次页面上方的「应用」。
本地助手每天自动查一次 GitHub 上的新版本，下载的安装包按发布里的 SHA256SUMS 校验，不对就不装。
也可以下载新版安装包再运行一次。
从 1.1.x 一键更新到 1.2.1 及以后：本地助手换成了 Go 写的单个程序，更新后旧助手先换成一个过渡脚本，由它下载、校验新版并运行一次安装（一两分钟，期间面板会暂时连不上本地助手，网络不受影响）。迁移记录在 `C:\neu-v6-free\migrate.log`。

### 命令行生成（高级）

想把设置写在文件里：装 [Node.js](https://nodejs.org/) 18 以上、[Go](https://go.dev/dl/)（本地助手是 Go 写的，生成时顺便编译）和 [Git](https://git-scm.com/)，然后在 PowerShell 里：

```powershell
git clone https://github.com/Concrise/neu-v6-free.git
cd neu-v6-free
copy config.example.yaml config.yaml   # 用记事本按注释填写，至少填 clash_api_secret
node cli.js -p windows                 # 生成到 out\windows\，会顺便下载规则集
```

再双击 `out\windows\install.bat`。以后改了 `config.yaml`：重新生成，双击新生成目录里的 `update.bat`（不需要管理员）。
命令行生成的设置会同步到面板里；之后再用命令行更新，会用文件里的设置覆盖面板里改的。

> 从网上下载的 zip 解压出来的文件，Windows 可能会先问一次是否运行，选「仍要运行」即可。

## 装了什么

| 位置 | 内容 |
|---|---|
| `C:\neu-v6-free\config.json` | sing-box 配置（只有管理员、SYSTEM 和你能读） |
| `C:\neu-v6-free\sing-box.exe` | sing-box |
| `C:\neu-v6-free\panel\` | 网页面板 |
| `C:\neu-v6-free\rules\` | 规则集，以及「我的规则」（`user-rules.json` 和 `user-*.json`） |
| `C:\neu-v6-free\data\` | sing-box 缓存（分组的选择存在这里） |
| `C:\neu-v6-free\neu-v6-free.exe`、`helper.log`、`sing-box.log`、`sing-box.prev.log` | 本地助手（安装、卸载也是它）和日志（`prev` 是 sing-box 上一次运行的日志） |
| `C:\neu-v6-free\profile.json` | 面板里的订阅、节点、设置（只有管理员和 SYSTEM 能读；卸载时默认保留） |
| `C:\neu-v6-free\weakhost.json` | 只在助手关掉了某块网卡的 WeakHostSend 时才有，恢复时用 |
| Windows 服务「校园网 v6 免流」（`neu-v6-free`） | 开机以 SYSTEM 运行本地助手 |

**本地助手**（`127.0.0.1:9091`，Go 写的，不依赖任何东西）负责：运行 sing-box 并在它退出时重新拉起；面板里「我的规则」的增删改、流量统计；安装新配置并重启 sing-box（所以更新不需要管理员）。
暂停、重新启用时它会清掉系统的 DNS 缓存，切换后网站马上能打开。

## 日常使用

- **切换线路、加规则、切代理方式（智能分流 / 全部走代理 / 全部直连）**：都在面板里，立即生效。见 [rules.md](rules.md)。
- **加订阅、更新订阅、加节点、改服务器**：面板「订阅与节点」「设置」，改完点页面上方的「应用」。**不需要管理员**。
  新配置检查不过或装上后上不了网，会自动保留 / 换回旧配置。
- **规则集更新**：升级安装包或命令行重新生成时会带上最新的规则集。
- **离开校园网**：连不上服务器时会自动改走「不用服务器」，能连上自动切回；也可以在面板里手动选。

## 断网保护

- 本地助手每 30 秒检查一次：连续 3 次「经 sing-box 上不了网、绕过它能上」就暂停 sing-box（安全模式），电脑回到普通网络；sing-box 3 分钟内崩溃 5 次也会暂停。
  连续 3 次「都上不了」时，会停掉 sing-box 试一下（最多 10 分钟一次）：停掉就能上，同样进安全模式。安装和更新后的自检也是这样判断的。
- **WeakHostSend**：有的电脑网卡的「弱主机发送」被别的软件打开了（Windows 默认是关的，可以用 `Get-NetIPInterface | ft InterfaceAlias,AddressFamily,WeakHostSend` 查看）。
  打开时 sing-box 自己连服务器、查 DNS 的包会绕回它自己的 TUN，全部超时，整台电脑断网。
  本地助手在 sing-box 运行期间把**物理网卡**（Wi-Fi、网线）的这一项关掉，暂停、安全模式、卸载时恢复原值（改过哪些记在 `C:\neu-v6-free\weakhost.json`），`helper.log` 里有记录。
- 停止 / 重启 sing-box 时先让它自己退出（撤掉 TUN 网卡），10 秒没退才强杀。强杀后紧接着再启动常常打不开 TUN（日志里是 `configure tun interface: Cannot create a file when that file already exists`），助手会再拉起一次，约 20 秒恢复，期间网络是普通直连。
- 状态页 `http://127.0.0.1:9091/`：看是否在安全模式、原因是什么，输入面板密钥后可以暂停或重新启用。sing-box 停着时面板打不开，状态页还在。
- 面板「概览」里也有「暂停」按钮。
- 安全模式重启电脑后也保持，直到重新启用、`update.bat` 或重新安装。

## 卸载

「设置 → 应用」里卸载，或双击 `C:\neu-v6-free\uninstall.bat`：停掉 sing-box 和本地助手，删除服务和程序文件。
默认保留「我的规则」、订阅和设置（`profile.json`）、流量统计（`traffic.json`），重新安装后接着用；命令行里 `uninstall.bat --purge` 全部删除。

## 排错

| 现象 | 看哪里 / 怎么办 |
|---|---|
| 安装时提示端口被占用 | 退出提示里列出的程序，再装一次 |
| 「本地助手在运行，但 sing-box 没起来」 | 看 `C:\neu-v6-free\sing-box.log`；sing-box 重启过的话，上一次的日志在 `sing-box.prev.log` |
| 装上后只有 IPv6 全断（`sing-box.log` 里连服务器 `[...]:端口: i/o timeout`、`dns: exchange failed ... IN AAAA`） | 多半是网卡的 WeakHostSend 打开了（见上面「断网保护」）；新版助手会自动处理，`helper.log` 里能看到 |
| 面板打不开 | 浏览器打开 `http://127.0.0.1:9091/health`，看 `singbox` 是否为 `true`；看 `helper.log`、`sing-box.log` |
| 面板提示「连不上本地助手」 | 「服务」（services.msc）里看「校园网 v6 免流」是否在运行，可以在那里重新启动；还不行就重新安装一次 |
| `update.bat` 说检查没通过或上不了网 | 错误信息里有具体原因；旧配置已经换回来了 |
| 某个网站打不开 | 面板「线路与规则」粘贴网址换个去向；或「设置 → 诊断 → 实时连接」搜索它，看实际出口，点「改规则」 |
| 想暂时关掉 | 面板「概览」→「暂停」，或打开 `http://127.0.0.1:9091/` 点「暂停」 |
| 完全没网、面板和状态页都打不开 | 双击 `C:\neu-v6-free\uninstall.bat`，或在任务管理器结束 sing-box.exe；系统代理开着的话在「设置 → 网络 → 代理」关掉 |

遇到问题欢迎提 issue，附上 `helper.log` 和 `sing-box.log`（先删掉里面的密码）。
