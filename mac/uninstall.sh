#!/bin/bash
# 停止并移除服务（TUN 随之撤销）。用法：sudo mac/uninstall.sh（NAME / LABEL 同 install.sh）
set -uo pipefail
NAME=${NAME:-neu-v6-free}
LABEL=${LABEL:-local.$NAME}
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
launchctl bootout "system/$LABEL" 2>/dev/null && echo "服务已停止" || echo "服务未在运行"
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -rf "/usr/local/libexec/$NAME" "/usr/local/etc/$NAME" "/usr/local/var/$NAME"
echo "已卸载。可以重新打开其他代理软件。"
