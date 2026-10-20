#!/bin/bash
# 装好 / 刷新流量统计服务（install.sh、update.sh 调用，单独运行也可以）。
# 它跟 sing-box 服务成对出现：读同一份配置里的 Clash API，统计结果在面板「📊 流量统计」页。
# 用法：sudo mac/traffic-service.sh [端口，默认读面板 groups.json 的 traffic_port，再默认 9091]（NAME / LABEL 同 install.sh）
set -euo pipefail
NAME=${NAME:-neu-v6-free}
LABEL=${LABEL:-local.$NAME}.traffic
BIN_DIR=/usr/local/libexec/$NAME
ETC_DIR=/usr/local/etc/$NAME
VAR_DIR=/usr/local/var/$NAME
PLIST=/Library/LaunchDaemons/$LABEL.plist
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
PORT=${1:-$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('traffic_port',9091))" "$ETC_DIR/panel/groups.json" 2>/dev/null || echo 9091)}

install -o root -g wheel -m 755 "$(dirname "$0")/traffic.py" "$BIN_DIR/traffic.py"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string><string>$BIN_DIR/traffic.py</string>
    <string>-c</string><string>$ETC_DIR/config.json</string>
    <string>-d</string><string>$VAR_DIR</string>
    <string>-p</string><string>$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$VAR_DIR/traffic.log</string>
  <key>StandardErrorPath</key><string>$VAR_DIR/traffic.log</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
# 重新加载：配置（密钥、出口）或脚本变了都要重启它
launchctl bootout "system/$LABEL" 2>/dev/null && sleep 1 || true
launchctl bootstrap system "$PLIST"
echo "流量统计服务已启动（127.0.0.1:${PORT}，数据在 $VAR_DIR/traffic.json）"
