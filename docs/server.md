# 第二部分：加上自己的服务器

第一部分只能省下「有 IPv6 的网站」的流量。加一台**同时有公网 IPv4 和 IPv6** 的服务器后：
校园网用 IPv6 连到服务器（免费），服务器再用 IPv4 去访问网站，只有 IPv4 的国内网站和国外网站也都免费了。

```
你的电脑 ──IPv6（免费）──► 你的服务器 ──IPv4──► 只有 IPv4 的网站 / 国外网站
```

代价：网站看到的是服务器的 IP；校园网下载的数据都会从服务器发出，算进服务器的出站流量。

## 1. 准备服务器

- 系统：Debian 或 Ubuntu（有 systemd），能用 root 登录。
- 必须有公网 IPv4 和 IPv6。云平台上 IPv6 往往要单独开启（例如 Azure 要给网卡加 IPv6 配置，很多厂商要在控制台申请）。
- 离学校近、延迟低的更好（例如香港）。出站流量额度要够：经服务器的流量每 GB 都算。

## 2. 部署

把仓库里的 `server/setup.sh` 传到服务器上，以 root 运行：

```bash
scp server/setup.sh root@你的服务器:/root/
ssh root@你的服务器 'bash /root/setup.sh'
```

它会：

- 安装官方 sing-box，开四个入站，都同时监听 IPv4 和 IPv6：Reality（TCP）、AnyTLS（TCP）、Hysteria2（UDP）、TUIC（UDP）。
- 端口默认随机，凭据随机生成；再次运行不会换密码，只会重新输出设置。
- 没开 BBR 的话顺便开上。
- 最后输出一段客户端设置（同时保存在服务器的 `/root/neu-v6-nodes.yaml`），并告诉你要放行哪些端口。

可选的环境变量（写在命令前面，例如 `PORTS="41443 41444 41445 41446" bash setup.sh`）：

| 变量 | 作用 |
|---|---|
| `PORTS="a b c d"` | 指定 Reality、AnyTLS、Hysteria2、TUIC 的端口 |
| `LABEL="香港"` | 面板里显示的服务器名 |
| `REALITY_SNI=www.microsoft.com` | Reality 伪装的网站（要支持 TLS 1.3） |
| `V4=… V6=…` | 自动检测的公网地址不对时手动指定（NAT 机器等） |
| `SB_VERSION=…` | 指定服务器上 sing-box 的版本 |

其他命令：`bash setup.sh --show` 只重新输出设置；`bash setup.sh --uninstall` 停掉并删除它生成的配置。

## 3. 放行端口

脚本**不改防火墙**，只告诉你要放行哪些端口。两处都要处理，IPv4 和 IPv6 都要：

1. 云平台的安全组 / 防火墙规则。
2. 服务器本机的防火墙（ufw、firewalld、nftables）：脚本会按检测到的情况给出命令。

## 4. 填进客户端设置

**用安装包装的客户端**：把脚本输出的那段（从 `entry_servers:` 到节点列表结束）原样粘进面板「📦 订阅与节点」→「手动添加的节点」，
点「添加节点」：四个节点加进来，同时这台服务器被设为免流服务器。然后点页面上方的「应用」。

**用命令行生成的**：原样粘贴进 `config.yaml`（或网页生成器的「服务器脚本输出」），然后重新生成并安装或更新：

```bash
node cli.js -p mac && mac/update.sh      # macOS（已安装时）
node cli.js -p windows                    # Windows：然后双击 out\windows\update.bat（已安装时）或 install.bat
```

`entry_servers` 里有服务器就是第二部分。面板里会多出「免流服务器」开关，「国内仅 v4 网站」默认经服务器。

## 常用设置

| 设置 | 作用 |
|---|---|
| `entry_default: vless` | 「免流服务器」默认用哪个协议：`vless`（Reality，TCP，最稳）、`hysteria2`、`tuic`（UDP，丢包多的线路更快）、`anytls`。不填 = 自动选最快 |
| `hy2_brutal: { up_mbps: 30, down_mbps: 100 }` | Hysteria2 用 Brutal 拥塞控制（按带宽发包，丢包不降速）。按实测带宽填，填大了反而更差 |
| `entry_servers.<IP>.landing: true` | 这台服务器同时当国外落地（默认只当入口） |
| 多台服务器 | `entry_servers` 里写多台，第一台是默认入口；面板里随时切换，或选「自动选最快」 |

## 和机场节点一起用

在设置里同时填 `subscription_url`（Clash / mihomo 格式的订阅）。第二部分里，订阅节点默认先经你的服务器再到节点（面板里显示「（经服务器）」，免费），
另有一份「（直连 v4）」副本（校园网 v4 直接连，计费，延迟低）。「国外网站」开关里选哪个落地都行。

订阅里已经用 `dialer-proxy` 标好前置的，把那个组名加进 `entry_group_aliases`；不想经服务器的订阅节点，设 `landings_via_entry: false`。见 [config.md](config.md)。

## 注意

- 服务器出站流量通常计费（例如 Azure 亚洲区每月前 100GB 免费）。YouTube、Steam 这类大流量分组默认经服务器，额度紧张时在面板里改成直连。
- 服务器挂了或流量用完：面板「免流服务器」换一台，或选「不用服务器（离校时选）」。电脑上的规则集是本地的，服务器不通也能正常上网。
- 离开校园网（没有 IPv6）时连不上服务器的 IPv6 地址：选「不用服务器（离校时选）」。
