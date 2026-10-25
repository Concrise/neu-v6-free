#!/bin/bash
# 卸载：停止并移除服务（TUN 随之撤销）。用法：sudo mac/uninstall.sh [--purge]（NAME / LABEL 同 install.sh）
# 默认保留「我的规则」、订阅和设置、流量统计，重新安装后接着用；--purge 全部删除。
set -euo pipefail
NAME=${NAME:-neu-v6-free}
BIN=/usr/local/libexec/$NAME/neu-v6-free
[ -x "$BIN" ] || { echo "没有找到 $BIN（没装，或者装的是 1.1 以前的版本：先用新版安装一次）"; exit 1; }
ARGS=(uninstall --name "$NAME")
[ -n "${LABEL:-}" ] && ARGS+=(--label "$LABEL")
exec "$BIN" "${ARGS[@]}" "$@"
