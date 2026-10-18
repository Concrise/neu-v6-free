#!/bin/bash
# 首次安装（或重装）为 LaunchDaemon。用法：./install.sh [sing-box 路径]（会提示 sudo 密码）
# 默认用 v2rayN 自带的 sing-box；安装前先在 v2rayN 里停止核心并退出 FlClash
set -euo pipefail
cd "$(dirname "$0")"
[ -f core/cli.js ] || git -c protocol.file.allow=always submodule update --init core
BIN=${1:-"$HOME/Library/Application Support/v2rayN/bin/sing_box/sing-box"}
node core/cli.js -c profile.yaml -c config.local.yaml -p mac -o out
sudo NAME=neu-v6-router LABEL=com.nk.neu-v6-router core/mac/install.sh "$BIN" out/mac
