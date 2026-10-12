#!/bin/bash
# 停止并移除 neu-v6-router 服务（TUN 随之撤销）。用法：sudo ./uninstall.sh
set -uo pipefail
LABEL=com.nk.neu-v6-router
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
launchctl bootout system/$LABEL 2>/dev/null && echo "服务已停止" || echo "服务未在运行"
rm -f /Library/LaunchDaemons/$LABEL.plist
rm -rf /usr/local/libexec/neu-v6-router /usr/local/etc/neu-v6-router /usr/local/var/neu-v6-router
echo "已卸载。可重新打开 FlClash / v2rayN。"
