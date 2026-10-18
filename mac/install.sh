#!/bin/bash
# 以 root 把生成的 mac 配置装成 LaunchDaemon（开机自启、崩溃自动拉起，含 TUN）。
# 用法：sudo mac/install.sh <sing-box 可执行文件> [生成目录，默认 out/mac]
# 可用环境变量改名（多套共存或沿用旧安装）：NAME（安装目录名，默认 neu-v6-free）、LABEL（服务名）
# 注意：配置里的 rules_dir / panel_dir 要和这里的安装目录一致（默认都是 /usr/local/etc/neu-v6-free）
set -euo pipefail
NAME=${NAME:-neu-v6-free}
LABEL=${LABEL:-local.$NAME}
SRC_BIN=${1:?用法：sudo mac/install.sh <sing-box 路径> [生成目录]}
SRC=${2:-out/mac}
BIN_DIR=/usr/local/libexec/$NAME
ETC_DIR=/usr/local/etc/$NAME
VAR_DIR=/usr/local/var/$NAME
PLIST=/Library/LaunchDaemons/$LABEL.plist

[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
[ -f "$SRC/config.json" ] || { echo "缺少 $SRC/config.json，先运行 node cli.js -p mac"; exit 1; }
grep -q "\"$ETC_DIR/rules/" "$SRC/config.json" || { echo "配置里的 rules_dir 不是 $ETC_DIR/rules，请在设置里改 rules_dir/panel_dir 或设 NAME"; exit 1; }

# 先停掉旧的自身服务；之后端口仍被占用，说明别的代理软件（v2rayN / FlClash 等）还在跑
launchctl bootout system/$LABEL 2>/dev/null && sleep 2 || true
PORTS=$(/usr/bin/python3 -c "import json,sys;c=json.load(open(sys.argv[1]));p=[i['listen_port'] for i in c['inbounds'] if 'listen_port' in i];a=c.get('experimental',{}).get('clash_api',{}).get('external_controller','');p+=[int(a.rsplit(':',1)[1])] if a else [];print('|'.join(map(str,p)))" "$SRC/config.json")
if lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk -v re=":($PORTS)\$" '$9 ~ re {f=1} END {exit !f}'; then
  echo "端口被占用（$PORTS），请先退出其他代理软件："
  lsof -nP -iTCP -sTCP:LISTEN | awk -v re=":($PORTS)\$" 'NR==1 || $9 ~ re'
  exit 1
fi

install -d -o root -g wheel -m 755 "$BIN_DIR" "$ETC_DIR" "$ETC_DIR/rules" "$ETC_DIR/panel"
install -d -o root -g wheel -m 700 "$VAR_DIR"
install -o root -g wheel -m 755 "$SRC_BIN" "$BIN_DIR/sing-box"
install -o root -g wheel -m 600 "$SRC/config.json" "$ETC_DIR/config.json"
install -o root -g wheel -m 644 "$SRC"/rules/*.srs "$ETC_DIR/rules/"
install -o root -g wheel -m 644 "$SRC"/panel/* "$ETC_DIR/panel/"
"$BIN_DIR/sing-box" check -c "$ETC_DIR/config.json"

cat > "$PLIST" <<PL
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
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
sleep 3
launchctl print system/$LABEL | grep -E "state|pid" | head -3
tail -5 "$VAR_DIR/sing-box.log" 2>/dev/null || true
echo "已安装。面板 http://127.0.0.1:9090/ui ；卸载：sudo $(dirname "$0")/uninstall.sh"
