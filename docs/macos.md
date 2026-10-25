# macOS

macOS 上推荐装成**后台服务**：开机自动运行，带网页面板、「我的规则」和流量统计。只有第一次安装需要 `sudo`，之后更新都不用。

不想装后台服务也可以用 sing-box 官方 App，见文末。

## 安装（安装包，推荐）

1. **退出其他代理软件**（ClashX、Clash Verge、FlClash、v2rayN、Surge……），包括它们的 TUN / 增强模式。端口 10808、9090、9091 不能被占用。
2. 到 [Releases](https://github.com/Concrise/neu-v6-free/releases) 下载 `neu-v6-free-<版本>-macos.pkg`，双击打开，按提示安装，输入电脑密码。
   安装程序没有经过苹果公证，第一次打开会被拦下：到「系统设置 → 隐私与安全性」，在底部点「仍要打开」。

安装程序会：

- 装好自带的 sing-box（1.13.21 官方版，Intel 和 Apple 芯片通用），装到 `/usr/local/{libexec,etc,var}/neu-v6-free`，设成开机自启；
- 生成随机的面板密钥，自检能不能上网，不通自动撤回（会弹窗说明原因，完整记录在 `/var/log/neu-v6-free-install.log`）；
- 在「应用程序」里装好「校园网 v6 免流」App 并打开：窗口里是面板（自动登录；sing-box 暂停时显示状态页），
  菜单栏有 v6 图标（实心 = 正在免流，空心 = 已暂停，感叹号 = 出问题），菜单里能暂停 / 重新启用、看今天的流量、设开机自动打开；
  关掉窗口只留菜单栏图标，退出 App 也不影响免流。App 要 macOS 13 以上；面板也能用浏览器打开 `http://127.0.0.1:9090/ui`。

不想用安装程序也可以下载 `neu-v6-free-<版本>-macos.zip`，解压后右键「安装.command」→「打开」。它找 sing-box 的顺序是：
PATH 里的（`brew install sing-box`）→ v2rayN 自带的 → 从官方发布页下载 1.13.21。

装好时是第一部分（v6 优先省流）。在面板「📦 订阅与节点」里加订阅或节点，有自己的服务器就把服务器脚本的输出粘进去（见 [server.md](server.md)），点「应用」。

**升级**：有新版本时面板侧栏「设置」上会提示「有更新」，在「设置 → 版本与更新」点「更新」即可，不用密码；装完点一次页面上方的「应用」。
本地助手每天自动查一次 GitHub 上的新版本，下载的安装包按发布里的 SHA256SUMS 校验，不对就不装。
也可以下载新版安装包再运行一次「安装.command」（1.0.0 升上来要这样，那时还没有自动更新）。
卸载脚本装在 `/usr/local/libexec/neu-v6-free/uninstall.sh`，不用留着安装包。

## 安装（命令行生成，高级）

想把设置写在文件里：需要 Node.js 18 以上（`brew install node`）。

```bash
git clone https://github.com/Concrise/neu-v6-free.git
cd neu-v6-free
cp config.example.yaml config.yaml
```

编辑 `config.yaml`：

- `clash_api_secret`：面板密钥，随便填一串足够长的随机字符（例如 `openssl rand -hex 16` 的输出）。
- 第一部分（不用服务器）：其他都可以不填；想让国外流量走自己的机场，填 `subscription_url`。
- 第二部分（自己的服务器）：把服务器脚本的输出粘贴进来，见 [server.md](server.md)。

然后：

```bash
node cli.js -p mac        # 生成到 out/mac/，会顺便下载规则集
sudo mac/install.sh       # 只有这一次要 sudo
```

`install.sh` 找 sing-box 的顺序同上。想用别的，把路径作为第一个参数：`sudo mac/install.sh /path/to/sing-box`。

装好后浏览器打开 `http://127.0.0.1:9090/ui`，输入面板密钥。命令行生成的设置会同步到面板的「订阅与节点」「设置」里。

## 装了什么

| 位置 | 内容 |
|---|---|
| `/usr/local/libexec/neu-v6-free/` | `sing-box`、本地助手 `helper.py` |
| `/usr/local/etc/neu-v6-free/` | `config.json`、`profile.json`（面板里的订阅、节点、设置；都只有 root 能读）、`panel/`（面板）、`rules/`（规则集和「我的规则」） |
| `/usr/local/var/neu-v6-free/` | sing-box 缓存（分组的选择存在这里）、日志、流量统计 `traffic.json` |
| `/Library/LaunchDaemons/local.neu-v6-free.plist` | sing-box 服务：开机启动，崩溃自动拉起 |
| `/Library/LaunchDaemons/local.neu-v6-free.helper.plist` | 本地助手服务 |

**本地助手**是和 sing-box 一起装的一个小程序（`127.0.0.1:9091`），做 sing-box 自己做不到的事：
面板里「我的规则」的增删改、流量统计、保存订阅和设置、代面板下载订阅，以及安装新配置并重启 sing-box（所以改设置不用 `sudo`）。

## 日常使用

- **切换线路、加规则、切代理模式**：都在面板里，立即生效，不用运行任何命令。见 [rules.md](rules.md)。
- **加订阅、更新订阅、加节点、改服务器**：面板「订阅与节点」「设置」，改完点页面上方的「应用」。
  面板在浏览器里生成新配置，交给本地助手检查、安装、重启 sing-box；不通会自动换回旧配置。
- **命令行用户改了 `config.yaml`**：

  ```bash
  mac/update.sh
  ```

  它重新生成配置、下载最新规则集，交给本地助手检查并安装，然后重启 sing-box。**不需要 sudo**。
  如果配置有问题，助手会报错并保留旧配置，网络不受影响。
- **规则集更新**：规则集（哪些网站算国内、哪些算 AI……）在每次 `mac/update.sh` 时下载最新版。隔一两个月运行一次即可。
- **离开校园网**：面板里「免流服务器」选「不用服务器（离校时选）」。

## 断网保护

- 安装和 `mac/update.sh` 都会自检：装上后经 sing-box 上不了网（绕过它能上），安装会自动撤回，更新会换回旧配置。
- 本地助手每 30 秒检查一次，连续 3 次不通就暂停 sing-box（安全模式），电脑回到普通网络。
- 状态页 `http://127.0.0.1:9091/`：看原因、输入面板密钥后暂停或重新启用。面板「概览」里也有「暂停」按钮。
- 安全模式重启后也保持，直到重新启用、`mac/update.sh` 或重新安装。

## 卸载

```bash
sudo mac/uninstall.sh            # 保留「我的规则」和流量统计，重新安装后接着用
sudo mac/uninstall.sh --purge    # 全部删除
```

卸载后 TUN 随之撤销，可以重新打开其他代理软件。

## 装多套 / 改名字

安装、更新、卸载脚本都认两个环境变量：`NAME`（安装目录名，默认 `neu-v6-free`）和 `LABEL`（服务名，默认 `local.<NAME>`）。
改了 `NAME` 时，设置里的 `rules_dir`、`panel_dir` 也要改成 `/usr/local/etc/<NAME>/rules`、`/usr/local/etc/<NAME>/panel`。
可以参考 [personal/](../personal/) 的写法：它用包装脚本固定了 `NAME` 和 `LABEL`。

## 排错

| 现象 | 看哪里 / 怎么办 |
|---|---|
| 安装时提示端口被占用 | 退出提示里列出的程序（通常是别的代理软件），再装一次 |
| 面板打不开 | `sudo launchctl print system/local.neu-v6-free \| grep state` 看服务是否在运行；日志 `/usr/local/var/neu-v6-free/sing-box.log` |
| 面板提示「连不上本地助手」 | `curl http://127.0.0.1:9091/health`；日志 `/usr/local/var/neu-v6-free/helper.log`；`sudo mac/helper-service.sh` 重装助手 |
| `mac/update.sh` 说 sing-box 检查没通过 | 错误信息里有具体是哪一项；旧配置没动，修好设置再运行 |
| 某个网站打不开 | 面板「实时连接」搜索它，看实际出口；点「改规则」换一个 |
| 想暂时关掉 | 面板「概览」→「暂停」，或打开 `http://127.0.0.1:9091/` 点「暂停」；在那里重新启用 |

## 不装后台服务：用 sing-box 官方 App

App Store 搜 sing-box（或从 [sing-box 发布页](https://github.com/SagerNet/sing-box/releases) 下载 SFM）。
用网页生成器下载 macOS 配置，或 `config.yaml` 里加 `mac_app: true` 再 `node cli.js -p mac`，然后在 App 里新建配置 → 本地 → 选这个文件。

这样规则集在线下载，没有网页面板（App 里自带分组切换），没有「我的规则」和流量统计；想加规则写在设置的 `custom_rules` 里，见 [rules.md](rules.md)。
