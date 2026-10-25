# 自用配置

东大校园网 IPv6 免流的自用配置（原 neu-v6-router 仓库），走的是第二部分（自带服务器）。生成和安装全部用上一级目录的通用版，这里只放个人设置和几个测试脚本。
以下命令都在 `personal/` 里运行。

## 文件

| 文件 | 内容 | 入库 |
|---|---|---|
| `profile.yaml` | 默认落地、Brutal、显示名、分组默认值与面板说明 | ✅ |
| `config.local.yaml` | 入口服务器 IP（港机在前 = 默认入口，Netcup 在后也当落地）、妙妙屋订阅链接、面板密钥、HK 家宽固定端口（10809-10811）与本机直连端口（10812） | ❌（权限 600） |
| `servers.local.sh` | 测速 / 诊断 / 监测脚本用的服务器 IP、SSH 端口·用户·私钥名；模板 `servers.example.sh` | ❌（权限 600） |
| `install.sh` / `update.sh` / `uninstall.sh` | 通用版 mac 脚本的包装：固定服务名 `com.nk.neu-v6-router`、安装目录名 `neu-v6-router` | ✅ |
| `speedtest-hk.sh` / `speedtest-v6.sh` | 校园网 v6 直连港机 / Netcup 测速（iperf3，会暂停 TUN） | ✅ |
| `diag-v6.sh`、`v6monitor.sh` | 出国 IPv6 诊断；`v6monitor.sh` 由 LaunchAgent 每 30 分钟记录可达性 | ✅ |
| `test-sites.sh` | 国内常用站冒烟测试 | ✅ |

设置分三层，后面的覆盖前面的：通用版内置的分组与默认值 → `profile.yaml` → `config.local.yaml`。

## macOS：现在怎么运行

| 组件 | 是什么 |
|---|---|
| `com.nk.neu-v6-router`（LaunchDaemon） | sing-box（从 v2rayN 拷出来的），配置 `/usr/local/etc/neu-v6-router/config.json`，含 TUN |
| `com.nk.neu-v6-router.helper`（LaunchDaemon） | 本地助手 `127.0.0.1:9091`：我的规则、流量统计、免 sudo 更新 |
| `com.nk.neu-v6-monitor`（LaunchAgent） | 每 30 分钟跑一次 `personal/v6monitor.sh`，日志 `out/v6monitor.log` |

端口：10808 普通代理；10809-10811 各固定一条 HK 家宽（给指纹浏览器）；10812 本机直连 v4；面板 `http://127.0.0.1:9090/ui`。

运行的服务和仓库是分开的：安装 / 更新时配置、面板、规则集被复制到 `/usr/local/{libexec,etc,var}/neu-v6-router`。
仓库挪位置不影响服务，只有监测的 LaunchAgent 引用了仓库路径。

## 日常

```bash
./update.sh              # 改了 profile / 订阅后：重新生成并装上（不用 sudo，交给本地助手）
./install.sh             # 重装（只有这个要 sudo）
sudo ./uninstall.sh      # 卸载（保留我的规则和流量统计；加 --purge 全删），之后可以打开 FlClash / v2rayN
```

切换线路、加规则都在面板里，不用运行脚本。`update.sh` 会把 `profile.yaml` + `config.local.yaml` 同步到面板的「订阅与节点」「设置」里；
在面板里改了订阅或设置再运行 `update.sh`，会被文件里的设置覆盖（以文件为准）。通用版改动后想先看看配置差别：

```bash
node ../cli.js -c profile.yaml -c config.local.yaml -p mac -o /tmp/x
```

## Windows

1. 克隆仓库：`git clone https://github.com/Concrise/neu-v6-free.git`
2. 把 Mac 上的 `personal/config.local.yaml` 拷到 Windows 上同一位置（`servers.local.sh` 只给 Mac 测速脚本用，不需要）。
3. 如果 Windows 上的程序（比如 Claude Code）靠 FlClash 的代理端口上网（`HTTPS_PROXY=http://127.0.0.1:7890`），
   写一个 `personal\windows.local.yaml`，内容 `main_port: 7890`：sing-box 接替这个端口，FlClash 退出后它们照样能用。
4. 在 `personal\` 里生成（没有 `windows.local.yaml` 就去掉那个 `-c`）：

   ```powershell
   node ..\cli.js -c profile.yaml -c config.local.yaml -c windows.local.yaml -p windows -o out
   ```

5. 第一次：退出 FlClash（托盘右键退出），双击 `out\windows\install.bat`，管理员确认点「是」。
   装到 `C:\neu-v6-free`，开机自启，装完会自检，不通会自动撤回。面板同样是 `http://127.0.0.1:9090/ui`，状态页 `http://127.0.0.1:9091/`。
6. 以后改了设置：重新生成，双击 `out\windows\update.bat`（不需要管理员）。

注意 `profile.yaml` 里的 `rules_dir` / `panel_dir` 是 Mac 的路径，Windows 用的是 `windows_rules_dir` / `windows_panel_dir`（默认 `C:/neu-v6-free/…`），互不影响。

## 和服务器的关系

- **港机 `azure-hk`**：sing-box 四入站；每月出站 130GB 到上限自动停，此时要在面板把「免流服务器」手动换成 Netcup 的入口或「自动选最快」。
- **妙妙屋「自用东大版」订阅**：`🆓 免流入口` 组对应这里的「免流服务器」（`entry_group_aliases`）。CF 优选节点有意不挂免流入口，所以设了 `landings_via_entry: false`。
- 服务器侧的详细文档在 netcup 的 `~/docs/services/proxy-network.md`。
