#!/bin/bash
# 命令行用：把生成的 mac 配置装成后台服务（本地助手 + sing-box，开机自启），并装好面板。只有这一次要 sudo。
# 真正的安装由生成目录里的 neu-v6-free（helper/，Go 写的，不依赖任何东西）完成，这里只是把参数转过去。
# 用法：sudo mac/install.sh [sing-box 可执行文件] [生成目录，默认 out/mac]
#   不指定 sing-box 时依次找：生成目录里的 → 已经装着的 → PATH / Homebrew / v2rayN 自带的 → 从 GitHub 下载固定版本
# 环境变量 NAME（安装目录名，默认 neu-v6-free）、LABEL（服务名，默认 local.<NAME>）：多套共存或沿用旧安装时用
set -euo pipefail
SRC=${2:-out/mac}
[ -x "$SRC/neu-v6-free" ] || { echo "缺少 $SRC/neu-v6-free：先运行 node cli.js -p mac（要装 go，或者推送后等 GitHub Actions 编好）"; exit 1; }
ARGS=(install --from "$SRC" --name "${NAME:-neu-v6-free}")
[ -n "${LABEL:-}" ] && ARGS+=(--label "$LABEL")
[ -n "${1:-}" ] && ARGS+=(--singbox "$1")
exec "$SRC/neu-v6-free" "${ARGS[@]}"
