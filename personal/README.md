# neu-v6-router（自用）

东大校园网 IPv6 免流的自用配置。生成逻辑全部来自通用版 [neu-v6-free](core/)（git 子模块 `core/`），这里只放个人的东西。

| 文件 | 内容 | 入库 |
|---|---|---|
| `profile.yaml` | 默认落地、Brutal、显示名、分组默认值与说明 | ✅ |
| `config.local.yaml` | 入口服务器 IP（港机优先、Netcup 备用）、妙妙屋订阅链接、面板密钥、HK 家宽固定端口（10809-10811）与本机直连端口（10812） | ❌（权限 600） |
| `servers.local.sh` | 测速 / 诊断 / 监测脚本用的服务器 IP、SSH 端口·用户·私钥名；模板 `servers.example.sh` | ❌（权限 600） |
| `speedtest-hk.sh` / `speedtest-v6.sh` | 校园网 v6 直连港机 / Netcup 测速（iperf3，暂停 TUN） | ✅ |
| `diag-v6.sh`、`v6monitor.sh` | 出国 IPv6 诊断；LaunchAgent `com.nk.neu-v6-monitor` 每 30 分钟记录可达性 | ✅ |

## 日常

```bash
./update.sh              # 改了 profile / 订阅后：重新生成并热更新（sudo）
./install.sh             # 首次安装或重装（默认用 v2rayN 自带的 sing-box）
sudo ./uninstall.sh      # 卸载，之后可重新打开 FlClash / v2rayN
```

服务沿用旧名字：LaunchDaemon `com.nk.neu-v6-router`，目录 `/usr/local/{libexec,etc,var}/neu-v6-router`。面板地址 `http://127.0.0.1:9090/ui`。

## 更新通用版核心

```bash
git -C core pull                 # core 指向 GitHub 的 Concrise/neu-v6-free：先在 ~/Dev/neu-v6-free 提交并 push
git add core && git commit -m "更新 core"
```

通用版改动后，先对比新旧配置再 `./update.sh`：

```bash
node core/cli.js -c profile.yaml -c config.local.yaml -p mac -o /tmp/x
```

## 和服务器的关系

- **港机 `azure-hk`**：sing-box 四入站；每月出站 130GB 到上限自动停，此时要在面板把「免流服务器」手动换成 Netcup 的入口或「自动选最快」。
- **妙妙屋「自用东大版」订阅**：`🆓 免流入口` 组对应这里的「免流服务器」（`entry_group_aliases`）。CF 优选节点有意不挂免流入口，所以设了 `landings_via_entry: false`。
- 服务器侧的详细文档在 netcup 的 `~/docs/services/proxy-network.md`。
