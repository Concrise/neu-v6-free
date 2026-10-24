# Android / iOS

手机上用 sing-box 官方 App 导入生成的配置。分组在 App 里切换；没有网页面板和「我的规则」，想加规则写在设置的 `custom_rules` 里（见 [rules.md](rules.md)）。

## 安装 App

- **Android**：[sing-box 发布页](https://github.com/SagerNet/sing-box/releases) 下载 SFA，或从 Google Play / F-Droid 安装。
- **iOS**：App Store 搜索 sing-box（需要非中国区账号）。

## 生成配置

- 命令行：`node cli.js -p android`（或 `-p ios`），得到 `out/android/config.json`。
- 网页生成器：选好后点 Android / iOS 下载。

## 导入

App 里「配置」→ 新建 →「本地」→ 选择文件。也可以把配置放到你自己的网址上，选「远程」导入，以后改了设置 App 会自动更新。

> 配置里有你的节点密码，放到网上时用只有自己知道的地址，不要公开。

## 和电脑的区别

| | 电脑（后台服务） | 手机 |
|---|---|---|
| 规则集 | 随配置安装到本地 | App 在线下载、每天更新（第二部分经服务器下载，第一部分直连） |
| 按 App 分流 | ✅ | Android 按包名 ✅；iOS 系统不支持 |
| 加规则 | 面板「我的规则」，即时生效 | 写进 `custom_rules`，重新生成后导入 |

第一次打开时 App 要下载规则集：第二部分请确认服务器能连上（在校园网里），否则先在设置里用第一部分生成一份。

## 离开校园网

App 里「免流服务器」分组选「不用服务器（离校时选）」。
