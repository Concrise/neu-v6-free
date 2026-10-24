#!/bin/bash
# 暂停服务（撤掉 TUN）测校园网出国 IPv6，测完自动恢复服务。用法：sudo ./diag-v6.sh
# 结果写到 out/diag-v6.txt
set -u
LABEL=com.nk.neu-v6-router
PLIST=/Library/LaunchDaemons/$LABEL.plist
OUT="$(cd "$(dirname "$0")" && pwd)/out/diag-v6.txt"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
. "$(cd "$(dirname "$0")" && pwd)/servers.local.sh" || { echo "缺 servers.local.sh（模板 servers.example.sh）"; exit 1; }

restore() { launchctl bootstrap system "$PLIST" 2>/dev/null; sleep 3; echo "服务已恢复：$(launchctl print system/$LABEL 2>/dev/null | grep -m1 'state')"; }
trap restore EXIT

{
  echo "== $(date) 暂停服务后测试"
  launchctl bootout system/$LABEL 2>/dev/null; sleep 3
  echo "utun 路由残留: $(netstat -rn -f inet6 | grep -c 'fdfe:dcba')"
  N6=$NC_V6
  echo "-- ping6 Netcup"; ping6 -c 4 "$N6" 2>&1 | tail -2
  for p in $NC_PORTS; do
    curl -6 -s --noproxy '*' --connect-timeout 6 -m 8 -k -o /dev/null -w "Netcup v6 :$p connect=%{time_connect}s %{errormsg}\n" "https://[$N6]:$p/"
  done
  curl -6 -s --noproxy '*' --connect-timeout 6 -m 8 -o /dev/null -w "Cloudflare v6: %{http_code} %{errormsg}\n" https://www.cloudflare.com/cdn-cgi/trace
  curl -6 -s --noproxy '*' --connect-timeout 6 -m 8 -o /dev/null -w "清华 v6: %{http_code} %{errormsg}\n" https://mirrors.tuna.tsinghua.edu.cn/
} > "$OUT" 2>&1
chown "${SUDO_USER:-root}" "$OUT" 2>/dev/null
cat "$OUT"
