#!/bin/bash
# 重新生成 mac 配置并装到已安装的服务上（不用 sudo）。用法：mac/update.sh [传给 cli.js 的参数，如 -c config.yaml]
# 改了订阅、服务器或 config.yaml 才需要它；在面板里改设置、切换分组、加「我的规则」都是立即生效的，不用运行。
# 新配置交给本地助手（安装时以 root 装好的后台服务）去检查、安装、重启 sing-box，所以只有第一次安装要 sudo。
# 本地助手不在（没装好，或者是 1.1 以前的版本）时退回用 sudo 安装一次。环境变量 NAME / LABEL 同 install.sh；OUT 为生成目录（默认 out）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=${NAME:-neu-v6-free}
OUT=${OUT:-out}
node "$ROOT/cli.js" "$@" -p mac -o "$OUT"
SRC=$(cd "$OUT/mac" && pwd)
[ -x "$SRC/neu-v6-free" ] || { echo "缺少 $SRC/neu-v6-free：要装 go，或者推送后等 GitHub Actions 编好"; exit 1; }
# 已经装的是新版本地助手：交给它（不用 sudo）
if [ -x "/usr/local/libexec/$NAME/neu-v6-free" ] && "$SRC/neu-v6-free" apply "$SRC"; then exit 0; fi
echo "本地助手不可用或是旧版，这次用 sudo 安装；装好后以后更新不再需要 sudo。"
ARGS=(install --from "$SRC" --name "$NAME" --no-open)
[ -n "${LABEL:-}" ] && ARGS+=(--label "$LABEL")
sudo "$SRC/neu-v6-free" "${ARGS[@]}"
