# neu-v6-router

把妙妙屋「自用东大版」订阅转成 sing-box 配置（给 v2rayN「自定义配置」用），实现东大校园网 IPv6 免流三层分流：

| 流量 | 出站分组（默认） | 计费 |
|---|---|---|
| 国内域名经 v6 DNS 解析出 AAAA | `国内v6` → `direct-v6`（只经 v6 DNS、只拨 v6） | 免费 |
| 其余国内（仅 v4） | `国内v4` → `免流入口`（默认 Azure 香港 v6 入口，港机出 v4；超限退回 Netcup） | 免费 |
| 国外 | `国外` → 家宽Sixtynet（detour `免流入口`） | 免费 |
| 入口 `direct-port`（10812） | 本机 v4 直连（给指纹浏览器） | 计费 |
| 入口 `hk-<端口>`（10809/10810/10811） | 各固定一条 HK家宽 13/14/15（v4 直连，给指纹浏览器） | 计费 |

- 主入口 mixed `127.0.0.1:10808`（v2rayN 系统代理端口），HK 入口 `127.0.0.1:10809-10811`（config.local.yaml 的 `hk_outbounds`，每项带 `port`），本机直连入口 `127.0.0.1:10812`（全部 v4 直连）。
- 面板：自写单页面板 `panel/index.html`（每个分组单独一页 + 用途说明 + 实时连接），`http://127.0.0.1:9090/ui`，secret 在 `config.local.yaml`。
- 分组、用途说明与优先级集中在 `groups.py`；规则集由 gen.py 预下载到 `out/rules`（本地规则集，启动不依赖网络）。
- 离开校园网（无 v6）：在面板把 `免流入口` 切到 `direct`；国内 v6 DNS 不可用时改用 FlClash「自用-」。

## 用法

```bash
python3 gen.py            # 拉订阅 → out/sing-box.json
```

`config.local.yaml`（不入库，权限 600）：`subscription_url`、`clash_api_secret`、`hk_outbounds`（HK 家宽列表，每项一个本地 `port`）。

## 安装为系统服务（含 TUN）

```bash
sudo ./install.sh     # 装到 /usr/local/{libexec,etc,var}/neu-v6-router，LaunchDaemon com.nk.neu-v6-router
./update.sh           # 改了订阅后：重新生成并热更新
sudo ./uninstall.sh   # 回滚（之后重新打开 FlClash）
```

安装前需停止 v2rayN 核心并退出 FlClash（端口 10808/10809/9090 不能被占）。日志：`/usr/local/var/neu-v6-router/sing-box.log`。
TUN 同时接管 v4/v6；`auto_detect_interface` 让自身出站绑物理网卡防环路；国外域名用 fakeip。

## 关键坑

- 国内 CDN 只对 **v6 来源** 的 DNS 查询返回 AAAA，所以国内解析用 `2400:3200::1`。
- sing-box 默认规则里 `rule_set` 与 `ip_cidr` 是「或」，「国内且有 v6」必须用 `logical and`。
- `resolve` 动作后 direct 出站拿到的仍是域名，会用 `default_domain_resolver` 重解析；所以国内v6 用单独的 `direct-v6`（`domain_resolver: cn6, ipv6_only`）。
- TUN 的 v6 地址不能用 ULA（`fd00::/8`）：RFC 6724 下「ULA 源 → 公网 v6」排在 v4 后，App 拿 v4 IP 进 TUN，`resolve` 对 IP 目标不生效，结果有 v6 的国内站也走了隧道。现用 `2001:db8:6e75::1`（仅本机内部）。
- 腾讯等把 v6 放在单独域名（`down.qq.com` 无 AAAA，`downv6.qq.com` 有，同批节点）：`v6_aliases` 用 `override_address` 只改拨号目标，SNI 不变。
- 有些国内 CDN 段有 AAAA 但校园网 v6 不通（如腾讯 `2402:4e00:1830:1214::/64`，微信图片/视频下载）。TUN 会先替 App 完成握手，App 的 Happy Eyeballs 失效、干等超时；`v6_broken_cidrs` 在 sniff 前 `reject`，App 立刻收到 RST 回退 v4。
