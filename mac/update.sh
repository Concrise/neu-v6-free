#!/bin/bash
# 重新生成 mac 配置并热更新到已安装的服务。用法：mac/update.sh [传给 cli.js 的参数，如 -c config.yaml]
# 环境变量 NAME / LABEL 同 install.sh；OUT 为生成目录（默认 out）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=${NAME:-neu-v6-free}
LABEL=${LABEL:-local.$NAME}
OUT=${OUT:-out}
ETC_DIR=/usr/local/etc/$NAME
node "$ROOT/cli.js" "$@" -p mac -o "$OUT"
SRC="$OUT/mac"
sudo "/usr/local/libexec/$NAME/sing-box" check -c "$SRC/config.json"
sudo install -o root -g wheel -m 644 "$SRC"/rules/*.srs "$ETC_DIR/rules/"
sudo install -o root -g wheel -m 644 "$SRC"/panel/* "$ETC_DIR/panel/"
sudo install -o root -g wheel -m 600 "$SRC/config.json" "$ETC_DIR/config.json"
sudo launchctl kickstart -k "system/$LABEL"
echo "已更新并重启服务"
