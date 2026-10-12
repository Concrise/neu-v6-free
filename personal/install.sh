#!/bin/bash
# 以 root 安装 neu-v6-router 为 LaunchDaemon（开机自启、崩溃自动拉起，含 TUN）。
# 用法：sudo ./install.sh [sing-box 路径]
set -euo pipefail

LABEL=com.nk.neu-v6-router
SRC_BIN=${1:-"/Users/nk/Library/Application Support/v2rayN/bin/sing_box/sing-box"}
ROOT=$(cd "$(dirname "$0")" && pwd)
SRC_CFG="$ROOT/out/sing-box.json"
BIN_DIR=/usr/local/libexec/neu-v6-router
ETC_DIR=/usr/local/etc/neu-v6-router
VAR_DIR=/usr/local/var/neu-v6-router
PLIST=/Library/LaunchDaemons/$LABEL.plist

[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
[ -f "$SRC_CFG" ] || { echo "缺少 $SRC_CFG，先运行 python3 gen.py"; exit 1; }

# 先停掉旧的自身服务；之后端口仍被占用，说明 v2rayN / FlClash 还在跑
launchctl bootout system/$LABEL 2>/dev/null && sleep 2 || true
if lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$9 ~ /:(10808|10809|9090)$/ {f=1} END {exit !f}'; then
  echo "端口 10808/10809/9090 被占用，请先在 v2rayN 里停止核心（或退出 v2rayN）并退出 FlClash："
  lsof -nP -iTCP -sTCP:LISTEN | awk 'NR==1 || $9 ~ /:(10808|10809|9090)$/'
  exit 1
fi

install -d -o root -g wheel -m 755 "$BIN_DIR" "$ETC_DIR"
install -d -o root -g wheel -m 700 "$VAR_DIR"
install -o root -g wheel -m 755 "$SRC_BIN" "$BIN_DIR/sing-box"
install -o root -g wheel -m 600 "$SRC_CFG" "$ETC_DIR/config.json"
"$BIN_DIR/sing-box" check -c "$ETC_DIR/config.json"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/sing-box</string><string>run</string>
    <string>-c</string><string>$ETC_DIR/config.json</string>
    <string>-D</string><string>$VAR_DIR</string>
    <string>--disable-color</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$VAR_DIR/sing-box.log</string>
  <key>StandardErrorPath</key><string>$VAR_DIR/sing-box.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
sleep 3
launchctl print system/$LABEL | grep -E "state|pid" | head -3
tail -5 "$VAR_DIR/sing-box.log" 2>/dev/null || true
echo "已安装。面板 http://127.0.0.1:9090/ui ；回滚：sudo $ROOT/uninstall.sh"
