# neu-v6-router

把妙妙屋「自用东大版」订阅转成 sing-box 配置（给 v2rayN「自定义配置」用），实现东大校园网 IPv6 免流三层分流：

| 流量 | 出站分组（默认） | 计费 |
|---|---|---|
| 国内域名经 v6 DNS 解析出 AAAA | `国内v6` → `direct-v6`（只经 v6 DNS、只拨 v6） | 免费 |
| 其余国内（仅 v4） | `国内v4` → `免流入口`（Oracle v6 入口，Oracle 出 v4） | 免费 |
| 国外 | `国外` → 家宽Sixtynet（detour `免流入口`） | 免费 |
| 入口 `hk`（10809） | HK家宽（v4 直连，给指纹浏览器） | 计费 |

- 主入口 mixed `127.0.0.1:10808`（v2rayN 系统代理端口），HK 入口 `127.0.0.1:10809`。
- 面板：Clash API `127.0.0.1:9090`，UI `http://127.0.0.1:9090/ui`，secret 在 `config.local.yaml`。
- 离开校园网（无 v6）：在面板把 `免流入口` 切到 `direct`；国内 v6 DNS 不可用时改用 FlClash「自用-」。

## 用法

```bash
python3 gen.py            # 拉订阅 → out/sing-box.json
```

`config.local.yaml`（不入库，权限 600）：`subscription_url`、`clash_api_secret`、`hk_outbound`（从 v2rayN 原配置快照）。

## 关键坑

- 国内 CDN 只对 **v6 来源** 的 DNS 查询返回 AAAA，所以国内解析用 `2400:3200::1`。
- sing-box 默认规则里 `rule_set` 与 `ip_cidr` 是「或」，「国内且有 v6」必须用 `logical and`。
- `resolve` 动作后 direct 出站拿到的仍是域名，会用 `default_domain_resolver` 重解析；所以国内v6 用单独的 `direct-v6`（`domain_resolver: cn6, ipv6_only`）。
