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
2. **退出其他代理软件**（v2rayN、Clash Verge、FlClash……），包括它们的 TUN 模式。端口 10808、9090、9091 不能被占用。

`config.yaml` 里至少填 `clash_api_secret`（面板密钥，一串足够长的随机字符）。第二部分（自己的服务器）见 [server.md](server.md)。

## 安装

在 `out\windows\install.ps1`（网页生成器的 zip 里也有）上右键 →「使用 PowerShell 运行」，弹出的管理员确认点「是」。

它会：

1. 把配置、面板、规则集装到 `C:\neu-v6-free`。
2. 准备 sing-box：旁边有 `sing-box.exe` 就用它，否则从 GitHub 下载官方最新版。也可以指定：
   `powershell -ExecutionPolicy Bypass -File install.ps1 -SingBox D:\path\sing-box.exe`
3. 注册计划任务「neu-v6-free helper」：开机以 SYSTEM 身份运行本地助手，由它启动 sing-box、崩溃自动拉起。

看到「安装完成」后，浏览器打开 `http://127.0.0.1:9090/ui`，输入面板密钥。

> 如果右键菜单里没有「使用 PowerShell 运行」，或提示「禁止运行脚本」：在开始菜单搜索 PowerShell，打开后运行
> `powershell -ExecutionPolicy Bypass -File "完整路径\install.ps1"`。
> 从网上下载的 zip 解压出来的脚本，Windows 可能会先问一次是否运行，选「运行一次」即可。

## 装了什么

| 位置 | 内容 |
|---|---|
| `C:\neu-v6-free\config.json` | sing-box 配置（只有管理员、SYSTEM 和你能读） |
| `C:\neu-v6-free\sing-box.exe` | sing-box |
| `C:\neu-v6-free\panel\` | 网页面板 |
| `C:\neu-v6-free\rules\` | 规则集，以及「我的规则」（`user-rules.json` 和 `user-*.json`） |
| `C:\neu-v6-free\data\` | sing-box 缓存（分组的选择存在这里） |
| `C:\neu-v6-free\helper.ps1`、`helper.log`、`sing-box.log` | 本地助手和日志 |
| 计划任务「neu-v6-free helper」 | 开机以 SYSTEM 运行本地助手 |

**本地助手**（`127.0.0.1:9091`）负责：运行 sing-box 并在它退出时重新拉起；面板里「我的规则」的增删改；安装新配置并重启 sing-box（所以更新不需要管理员）。

## 日常使用

- **切换线路、加规则**：都在面板里，立即生效。见 [rules.md](rules.md)。
- **改了订阅、服务器或 `config.yaml`**：重新生成（`node cli.js -p windows`，或网页生成器重新下载 zip），然后在新生成目录的 `update.ps1` 上右键 →「使用 PowerShell 运行」。
  **不需要管理员**。配置有问题时它会报错，旧配置不动。
- **规则集更新**：每次重新生成时会下载最新的规则集，隔一两个月更新一次即可。
- **离开校园网**：面板里「免流服务器」选「不用服务器（离校时选）」。

## 卸载

运行 `C:\neu-v6-free\uninstall.ps1`（右键 →「使用 PowerShell 运行」）：停掉 sing-box 和本地助手，删除计划任务和程序文件。
默认保留「我的规则」，重新安装后接着用；加 `-Purge` 全部删除。

## 排错

| 现象 | 看哪里 / 怎么办 |
|---|---|
| 安装时提示端口被占用 | 退出提示里列出的程序，再装一次 |
| 「本地助手在运行，但 sing-box 没起来」 | 看 `C:\neu-v6-free\sing-box.log` |
| 面板打不开 | 浏览器打开 `http://127.0.0.1:9091/health`，看 `singbox` 是否为 `true`；看 `helper.log`、`sing-box.log` |
| 面板提示「连不上本地助手」 | 「任务计划程序」里看「neu-v6-free helper」是否在运行；重新运行一次 `install.ps1` |
| `update.ps1` 说检查没通过 | 错误信息里有具体是哪一项；旧配置没动 |
| 某个网站打不开 | 面板「实时连接」搜索它，看实际出口；点「改规则」换一个 |
| 想暂时关掉 | 「任务计划程序」里结束「neu-v6-free helper」，再在任务管理器结束 sing-box.exe；重启电脑后会自动恢复 |

Windows 版暂时没有流量统计。遇到问题欢迎提 issue，附上 `helper.log` 和 `sing-box.log`（先删掉里面的密码）。
