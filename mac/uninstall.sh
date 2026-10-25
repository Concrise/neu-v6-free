#!/bin/bash
# 停止并移除服务（TUN 随之撤销）。用法：sudo mac/uninstall.sh [--purge]（NAME / LABEL 同 install.sh）
# 默认保留「我的规则」（<安装目录>/rules/user-*.json）和流量统计，重新安装后接着用；--purge 全部删除。
set -uo pipefail
NAME=${NAME:-neu-v6-free}
LABEL=${LABEL:-local.$NAME}
ETC_DIR=/usr/local/etc/$NAME
VAR_DIR=/usr/local/var/$NAME
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
launchctl bootout "system/$LABEL" 2>/dev/null && echo "服务已停止" || echo "服务未在运行"
for s in helper traffic; do launchctl bootout "system/$LABEL.$s" 2>/dev/null || true; done
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.helper.plist" "/Library/LaunchDaemons/$LABEL.traffic.plist"
rm -rf "/usr/local/libexec/$NAME"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$ETC_DIR" "$VAR_DIR"
  echo "已卸载并删除全部数据。可以重新打开其他代理软件。"
else
  rm -rf "$ETC_DIR/config.json" "$ETC_DIR/panel" "$VAR_DIR"/*.log "$VAR_DIR"/*.db
  rm -f "$ETC_DIR"/rules/*.srs
  echo "已卸载。可以重新打开其他代理软件。"
  echo "「我的规则」、订阅和设置（$ETC_DIR/rules、profile.json）以及流量统计（$VAR_DIR）保留，重新安装后接着用；要全部删除：sudo $0 --purge"
fi
