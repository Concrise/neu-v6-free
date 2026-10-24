# Windows

Windows 10 / 11（x64 或 ARM64）上装成**后台服务**：开机自动运行，带网页面板和「我的规则」。
只有第一次安装需要管理员确认，之后更新都不用。不需要 v2rayN。

## 准备

1. **生成配置**，二选一：
   - **命令行**：装 [Node.js](https://nodejs.org/) 18 以上和 [Git](https://git-scm.com/)，然后在 PowerShell 里：

     ```powershell
     git clone https://github.com/Concrise/neu-v6-free.git
     cd neu-v6-free
     copy config.example.yaml config.yaml   # 用记事本按注释填写
     node cli.js -p windows                 # 生成到 out\windows\，会顺便下载规则集
     ```

   - **网页生成器**：打开网页生成器，下载 Windows 的 zip 并解压。
2. **退出其他代理软件**（v2rayN、Clash Verge、FlClash……）：托盘图标右键 → 退出，不是只关窗口。端口 10808、9090、9091 不能被占用。
   - 如果你给命令行工具（比如 Claude Code）设过 `HTTPS_PROXY=http://127.0.0.1:7890` 之类，代理软件一退出它们就连不上。
     可以在设置里加 `main_port: 7890`，让 sing-box 接替同一个端口，原来的设置照样能用。

`config.yaml` 里至少填 `clash_api_secret`（面板密钥，一串足够长的随机字符）。第二部分（自己的服务器）见 [server.md](server.md)。

## 安装

双击 `out\windows\install.bat`（网页生成器的 zip 里也有），弹出的管理员确认点「是」。

它会：

1. 把配置、面板、规则集装到 `C:\neu-v6-free`。
2. 准备 sing-box：旁边有 `sing-box.exe` 就用它，否则从 GitHub 下载官方最新版。也可以指定：
   `powershell -ExecutionPolicy Bypass -File install.ps1 -SingBox D:\path\sing-box.exe`
3. 注册计划任务「neu-v6-free helper」：开机以 SYSTEM 身份运行本地助手，由它启动 sing-box、崩溃自动拉起。
4. 关掉失效的系统代理（别的代理软件退出后留下的），提示指向代理软件的环境变量。
5. **自检**：测一次能不能上网。不通就自动撤回（停掉 sing-box、取消开机启动），电脑恢复原样，并显示原因。

看到绿色「安装完成：自检通过」后，浏览器打开 `http://127.0.0.1:9090/ui`，输入面板密钥。

> 从网上下载的 zip 解压出来的文件，Windows 可能会先问一次是否运行，选「仍要运行」即可。

## 装了什么

| 位置 | 内容 |
|---|---|
| `C:\neu-v6-free\config.json` | sing-box 配置（只有管理员、SYSTEM 和你能读） |
| `C:\neu-v6-free\sing-box.exe` | sing-box |
| `C:\neu-v6-free\panel\` | 网页面板 |
| `C:\neu-v6-free\rules\` | 规则集，以及「我的规则」（`user-rules.json` 和 `user-*.json`） |
| `C:\neu-v6-free\data\` | sing-box 缓存（分组的选择存在这里） |
| `C:\neu-v6-free\helper.ps1`、`helper.log`、`sing-box.log`、`sing-box.prev.log` | 本地助手和日志（`prev` 是 sing-box 上一次运行的日志） |
| `C:\neu-v6-free\weakhost.json` | 只在助手关掉了某块网卡的 WeakHostSend 时才有，恢复时用 |
| 计划任务「neu-v6-free helper」 | 开机以 SYSTEM 运行本地助手 |

**本地助手**（`127.0.0.1:9091`）负责：运行 sing-box 并在它退出时重新拉起；面板里「我的规则」的增删改；安装新配置并重启 sing-box（所以更新不需要管理员）。

## 日常使用

- **切换线路、加规则**：都在面板里，立即生效。见 [rules.md](rules.md)。
- **改了订阅、服务器或 `config.yaml`**：重新生成（`node cli.js -p windows`，或网页生成器重新下载 zip），然后双击新生成目录里的 `update.bat`。
  **不需要管理员**。配置有问题时它会报错，旧配置不动。
- **规则集更新**：每次重新生成时会下载最新的规则集，隔一两个月更新一次即可。
- **离开校园网**：面板里「免流服务器」选「不用服务器（离校时选）」。

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

双击 `C:\neu-v6-free\uninstall.bat`：停掉 sing-box 和本地助手，删除计划任务和程序文件。
默认保留「我的规则」和流量统计（`traffic.json`），重新安装后接着用；加 `-Purge` 全部删除。

## 排错

| 现象 | 看哪里 / 怎么办 |
|---|---|
| 安装时提示端口被占用 | 退出提示里列出的程序，再装一次 |
| 「本地助手在运行，但 sing-box 没起来」 | 看 `C:\neu-v6-free\sing-box.log`；sing-box 重启过的话，上一次的日志在 `sing-box.prev.log` |
| 装上后只有 IPv6 全断（`sing-box.log` 里连服务器 `[...]:端口: i/o timeout`、`dns: exchange failed ... IN AAAA`） | 多半是网卡的 WeakHostSend 打开了（见上面「断网保护」）；新版助手会自动处理，`helper.log` 里能看到 |
| 面板打不开 | 浏览器打开 `http://127.0.0.1:9091/health`，看 `singbox` 是否为 `true`；看 `helper.log`、`sing-box.log` |
| 面板提示「连不上本地助手」 | 「任务计划程序」里看「neu-v6-free helper」是否在运行；重新运行一次 `install.ps1` |
| `update.bat` 说检查没通过或上不了网 | 错误信息里有具体原因；旧配置已经换回来了 |
| 某个网站打不开 | 面板「实时连接」搜索它，看实际出口；点「改规则」换一个 |
| 想暂时关掉 | 面板「概览」→「暂停」，或打开 `http://127.0.0.1:9091/` 点「暂停」 |
| 完全没网、面板和状态页都打不开 | 双击 `C:\neu-v6-free\uninstall.bat`，或在任务管理器结束 sing-box.exe；系统代理开着的话在「设置 → 网络 → 代理」关掉 |

遇到问题欢迎提 issue，附上 `helper.log` 和 `sing-box.log`（先删掉里面的密码）。
