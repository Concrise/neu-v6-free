#!/bin/bash
# 第一次安装（只有这一次要 sudo）：把生成的 mac 配置装成 LaunchDaemon（开机自启、崩溃自动拉起，含 TUN），
# 并装好本地助手（「我的规则」、流量统计、免 sudo 更新）。以后改了设置用 mac/update.sh，不用 sudo。
# 用法：sudo mac/install.sh [sing-box 可执行文件] [生成目录，默认 out/mac]
#   不指定 sing-box 时依次找：PATH 里的 sing-box（如 brew install sing-box）→ v2rayN 自带的
# 可用环境变量改名（多套共存或沿用旧安装）：NAME（安装目录名，默认 neu-v6-free）、LABEL（服务名）
# 注意：配置里的 rules_dir / panel_dir 要和这里的安装目录一致（默认都是 /usr/local/etc/neu-v6-free）
set -euo pipefail
NAME=${NAME:-neu-v6-free}
LABEL=${LABEL:-local.$NAME}
SRC_BIN=${1:-}
if [ -z "$SRC_BIN" ]; then
  for c in "$(command -v sing-box || true)" /opt/homebrew/bin/sing-box /usr/local/bin/sing-box \
    "/Users/${SUDO_USER:-$USER}/Library/Application Support/v2rayN/bin/sing_box/sing-box" \
    /Applications/v2rayN.app/Contents/MacOS/bin/sing_box/sing-box; do
    [ -n "$c" ] && [ -x "$c" ] && { SRC_BIN=$c; break; }
  done
  [ -n "$SRC_BIN" ] || { echo "找不到 sing-box：先 brew install sing-box，或把可执行文件路径作为第一个参数"; exit 1; }
  echo "sing-box：$SRC_BIN（$("$SRC_BIN" version | head -1)）"
fi
SRC=${2:-out/mac}
BIN_DIR=/usr/local/libexec/$NAME
ETC_DIR=/usr/local/etc/$NAME
VAR_DIR=/usr/local/var/$NAME
PLIST=/Library/LaunchDaemons/$LABEL.plist

[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
[ -f "$SRC/config.json" ] || { echo "缺少 $SRC/config.json，先运行 node cli.js -p mac"; exit 1; }
grep -q "\"$ETC_DIR/rules/" "$SRC/config.json" || { echo "配置里的 rules_dir 不是 $ETC_DIR/rules，请在设置里改 rules_dir/panel_dir 或设 NAME"; exit 1; }

# 先停掉旧的自身服务（本地助手最后会重新装）；之后端口仍被占用，说明别的代理软件（v2rayN / FlClash 等）还在跑
launchctl bootout system/$LABEL 2>/dev/null && sleep 2 || true
PORTS=$(/usr/bin/python3 -c "import json,sys;c=json.load(open(sys.argv[1]));p=[i['listen_port'] for i in c['inbounds'] if 'listen_port' in i];a=c.get('experimental',{}).get('clash_api',{}).get('external_controller','');p+=[int(a.rsplit(':',1)[1])] if a else [];print('|'.join(map(str,p)))" "$SRC/config.json")
if lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk -v re=":($PORTS)\$" '$9 ~ re {f=1} END {exit !f}'; then
  echo "端口被占用（${PORTS}），请先退出其他代理软件："
  lsof -nP -iTCP -sTCP:LISTEN | awk -v re=":($PORTS)\$" 'NR==1 || $9 ~ re'
  exit 1
fi

install -d -o root -g wheel -m 755 "$BIN_DIR" "$ETC_DIR" "$ETC_DIR/rules" "$ETC_DIR/panel"
install -d -o root -g wheel -m 700 "$VAR_DIR"
rm -f "$VAR_DIR/safe-mode.json" # 重新安装 = 重新启用（清掉之前的安全模式）
install -o root -g wheel -m 755 "$SRC_BIN" "$BIN_DIR/sing-box"
install -o root -g wheel -m 600 "$SRC/config.json" "$ETC_DIR/config.json"
install -o root -g wheel -m 644 "$SRC"/rules/*.srs "$ETC_DIR/rules/"
install -o root -g wheel -m 644 "$SRC"/panel/* "$ETC_DIR/panel/"
# 「我的规则」文件只补缺的：已经在面板里加过的规则不会被覆盖
for f in "$SRC"/rules/user-*.json; do
  [ -e "$f" ] && [ ! -e "$ETC_DIR/rules/$(basename "$f")" ] && install -o root -g wheel -m 644 "$f" "$ETC_DIR/rules/"
done
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
NAME=$NAME LABEL=$LABEL "$(dirname "$0")/helper-service.sh"

# 断网保护：装完确认经 sing-box 能上网；不通而绕过它能通（是 sing-box 的问题），就撤回，电脑回到原来的网络
probe() { [ "$(curl -skI -o /dev/null -m 6 --noproxy '*' -w '%{http_code}' "$@")" != 000 ]; }
net_ok() { for u in https://www.taobao.com https://www.baidu.com https://www.qq.com; do probe "$u" && return 0; done; return 1; }
direct_ok() {
  local ifc; ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "$ifc" ] || return 1
  for u in 'http://[2400:3200::1]/' 'http://[2402:4e00::]/' http://220.181.111.1/ http://110.242.68.66/; do probe --interface "$ifc" "$u" && return 0; done
  return 1
}
ok=
for _ in 1 2 3 4 5 6; do sleep 4; net_ok && { ok=1; break; }; done
if [ -z "$ok" ] && direct_ok; then
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  echo "装上后经 sing-box 上不了网（绕过它是通的），已自动撤回：sing-box 已停止，网络恢复原样。" >&2
  echo "最后的日志：" >&2; tail -20 "$VAR_DIR/sing-box.log" >&2 || true
  echo "常见原因：不在校园网（没有 IPv6，模式二连不上服务器），或别的代理软件还开着 TUN。" >&2
  exit 1
fi
if [ -n "$ok" ]; then
  echo "自检通过：经 sing-box 能正常上网。"
  # 再等本地助手查一次免流服务器（模式二）：连不上时它会自动改走「不用服务器」
  HP=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('traffic_port',9091))" "$ETC_DIR/panel/groups.json" 2>/dev/null || echo 9091)
  for _ in $(seq 1 15); do
    H=$(curl -s -m 3 "http://127.0.0.1:$HP/health" || true)
    echo "$H" | grep -q '"server_checked": true' && break
    sleep 3
  done
  echo "$H" | grep -q '"server_fallback": {' && echo "注意：当前网络连不上免流服务器，已自动改走「不用服务器」（经服务器的流量改为直连，IPv4 计费）。回到能连上服务器的网络后会自动切回。"
else
  echo "自检：网络本身不通（不是 sing-box 的问题），先不处理。"
fi
tail -5 "$VAR_DIR/sing-box.log" 2>/dev/null || true
echo "已安装。面板 http://127.0.0.1:9090/ui"
echo "以后改了订阅或设置：mac/update.sh（不用 sudo）；卸载：sudo $(dirname "$0")/uninstall.sh"
