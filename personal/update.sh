#!/bin/bash
# 重新拉订阅生成配置，并热更新到已安装的服务。用法：./update.sh（会提示 sudo 密码）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
python3 "$ROOT/gen.py"
sudo install -d -o root -g wheel -m 755 /usr/local/etc/neu-v6-router/rules
sudo install -o root -g wheel -m 644 "$ROOT"/out/rules/*.srs /usr/local/etc/neu-v6-router/rules/
sudo install -d -o root -g wheel -m 755 /usr/local/etc/neu-v6-router/panel
sudo install -o root -g wheel -m 644 "$ROOT"/out/panel/* /usr/local/etc/neu-v6-router/panel/
sudo /usr/local/libexec/neu-v6-router/sing-box check -c "$ROOT/out/sing-box.json"
sudo install -o root -g wheel -m 600 "$ROOT/out/sing-box.json" /usr/local/etc/neu-v6-router/config.json
sudo launchctl kickstart -k system/com.nk.neu-v6-router
echo "已更新并重启服务"
