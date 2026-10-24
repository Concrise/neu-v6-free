# macOS

macOS 上推荐装成**后台服务**：开机自动运行，带网页面板、「我的规则」和流量统计。只有第一次安装需要 `sudo`，之后更新都不用。

不想装后台服务也可以用 sing-box 官方 App，见文末。

## 准备

1. **Node.js 18 以上**：`brew install node`，或从 [nodejs.org](https://nodejs.org/) 下载。
2. **sing-box**（1.12 以上）：任选一个
   - `brew install sing-box`
   - 装过 v2rayN 的话，可以直接用它自带的（安装脚本会自动找到）
   - 从 [sing-box 发布页](https://github.com/SagerNet/sing-box/releases) 下载 `darwin-arm64`（M 系列芯片）或 `darwin-amd64`（Intel）
3. **退出其他代理软件**（ClashX、Clash Verge、FlClash、v2rayN、Surge……），包括它们的 TUN / 增强模式。端口 10808、9090、9091 不能被占用。

## 安装

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

`install.sh` 会自动找 sing-box：先找 PATH 里的（`brew install` 装的），再找 v2rayN 自带的。想用别的，把路径作为第一个参数：
`sudo mac/install.sh /path/to/sing-box`。

装好后浏览器打开 `http://127.0.0.1:9090/ui`，输入面板密钥。

## 装了什么

| 位置 | 内容 |
|---|---|
| `/usr/local/libexec/neu-v6-free/` | `sing-box`、本地助手 `helper.py` |
| `/usr/local/etc/neu-v6-free/` | `config.json`（只有 root 能读）、`panel/`（面板）、`rules/`（规则集和「我的规则」） |
| `/usr/local/var/neu-v6-free/` | sing-box 缓存（分组的选择存在这里）、日志、流量统计 `traffic.json` |
| `/Library/LaunchDaemons/local.neu-v6-free.plist` | sing-box 服务：开机启动，崩溃自动拉起 |
| `/Library/LaunchDaemons/local.neu-v6-free.helper.plist` | 本地助手服务 |

**本地助手**是和 sing-box 一起装的一个小程序（`127.0.0.1:9091`），做 sing-box 自己做不到的三件事：
面板里「我的规则」的增删改、流量统计、以及安装新配置并重启 sing-box（所以更新不用 `sudo`）。

## 日常使用

- **切换线路、加规则**：都在面板里，立即生效，不用运行任何命令。见 [rules.md](rules.md)。
- **改了订阅、服务器或 `config.yaml`**：

  ```bash
  mac/update.sh
  ```

  它重新生成配置、下载最新规则集，交给本地助手检查并安装，然后重启 sing-box。**不需要 sudo**。
  如果配置有问题，助手会报错并保留旧配置，网络不受影响。
- **规则集更新**：规则集（哪些网站算国内、哪些算 AI……）在每次 `mac/update.sh` 时下载最新版。隔一两个月运行一次即可。
- **离开校园网**：面板里「免流服务器」选「不用服务器（离校时选）」。

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
| 想暂时关掉 | `sudo launchctl bootout system/local.neu-v6-free`；恢复：`sudo launchctl bootstrap system /Library/LaunchDaemons/local.neu-v6-free.plist` |

## 不装后台服务：用 sing-box 官方 App

App Store 搜 sing-box（或从 [sing-box 发布页](https://github.com/SagerNet/sing-box/releases) 下载 SFM）。
用网页生成器下载 macOS 配置，或 `config.yaml` 里加 `mac_app: true` 再 `node cli.js -p mac`，然后在 App 里新建配置 → 本地 → 选这个文件。

这样规则集在线下载，没有网页面板（App 里自带分组切换），没有「我的规则」和流量统计；想加规则写在设置的 `custom_rules` 里，见 [rules.md](rules.md)。
