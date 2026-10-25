#!/bin/bash
# 重新生成 mac 配置并装到已安装的服务上（不用 sudo）。用法：mac/update.sh [传给 cli.js 的参数，如 -c config.yaml]
# 改了订阅、服务器或 config.yaml 才需要它；在面板里切换分组、加「我的规则」都是立即生效的，不用运行。
# 新配置交给本地助手（安装时以 root 装好的后台服务）去检查、安装、重启 sing-box，所以只有第一次安装要 sudo。
# 助手不在（没装好或是旧版本）时才退回用 sudo 安装。环境变量 NAME / LABEL 同 install.sh；OUT 为生成目录（默认 out）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=${NAME:-neu-v6-free}
LABEL=${LABEL:-local.$NAME}
OUT=${OUT:-out}
ETC_DIR=/usr/local/etc/$NAME
node "$ROOT/cli.js" "$@" -p mac -o "$OUT"
SRC=$(cd "$OUT/mac" && pwd)

# 密钥和端口从新配置里读（和已安装的是同一份设置生成的）
read -r SECRET PORT < <(/usr/bin/python3 -c "
import json, sys
c = json.load(open(sys.argv[1])); g = json.load(open(sys.argv[2]))
print(c['experimental']['clash_api'].get('secret') or '-', g.get('traffic_port', 9091))" "$SRC/config.json" "$SRC/panel/groups.json")
BODY=$(/usr/bin/python3 -c "import json, sys; print(json.dumps({'src': sys.argv[1]}))" "$SRC")
RESP=$(mktemp)
trap 'rm -f "$RESP"' EXIT
apply() {
  curl -s -m 180 -o "$RESP" -w '%{http_code}' -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
    -d "$BODY" "http://127.0.0.1:$PORT/apply" || true
}
CODE=$(apply)
# 助手刚升级：旧版助手不认识新增的文件（如面板的 panel/lib），等新版起来再交一遍
if [ "$CODE" = 200 ] && grep -q '"helper_updated": true' "$RESP"; then
  echo "本地助手已升级，等它重启后再装一遍新增的文件……"
  for _ in $(seq 1 30); do sleep 1; curl -s -m 2 "http://127.0.0.1:$PORT/health" | grep -q '"client": true' && break; done
  CODE=$(apply)
fi
case "$CODE" in
  200)
    /usr/bin/python3 -c "
import json, sys
r = json.load(open(sys.argv[1]))
print('已更新并重启服务' if r.get('restarted') else '已更新')
if r.get('helper_updated'): print('本地助手也升级了，几秒后自动重启')
if r.get('server_fallback'): print('注意：当前网络连不上免流服务器，已自动改走「不用服务器」；能连上后会自动切回')" "$RESP"
    exit 0 ;;
  400|500)
    echo "更新失败：$(/usr/bin/python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('error'))" "$RESP")" >&2
    exit 1 ;;
esac

# 助手不在或太旧（没有 /apply）：用 sudo 装，同时把助手升级到新版，下次就不用 sudo 了
echo "本地助手不可用（HTTP ${CODE:-无响应}），这次用 sudo 安装；装好新版助手后，以后更新不再需要 sudo。"
sudo install -o root -g wheel -m 644 "$SRC"/rules/*.srs "$ETC_DIR/rules/"
sudo install -o root -g wheel -m 644 "$SRC"/panel/index.html "$SRC"/panel/groups.json "$ETC_DIR/panel/"
sudo install -d -o root -g wheel -m 755 "$ETC_DIR/panel/lib"
sudo install -o root -g wheel -m 644 "$SRC"/panel/lib/* "$ETC_DIR/panel/lib/"
sudo install -o root -g wheel -m 600 "$SRC/profile.json" "$ETC_DIR/profile.json"
for f in "$SRC"/rules/user-*.json; do
  [ -e "$f" ] && [ ! -e "$ETC_DIR/rules/$(basename "$f")" ] && sudo install -o root -g wheel -m 644 "$f" "$ETC_DIR/rules/"
done
sudo "/usr/local/libexec/$NAME/sing-box" check -c "$SRC/config.json"
sudo install -o root -g wheel -m 600 "$SRC/config.json" "$ETC_DIR/config.json"
sudo launchctl kickstart -k "system/$LABEL"
sudo NAME=$NAME LABEL=$LABEL "$ROOT/mac/helper-service.sh"
echo "已更新并重启服务"
