#!/bin/bash
# 纯 IPv6 直连测 Netcup 带宽（iperf3），全程不碰 v4。用法：sudo ./speedtest-v6.sh
# 流程：VPS 临时放行 tcp/5201（只放行本机 /64）→ 暂停 TUN 服务 → ping6 + iperf3 上下行 → 恢复服务、删规则、关 iperf3
# 结果写到 out/speedtest-v6.txt。可调：DUR=10 PAR=8
set -u
LABEL=com.nk.neu-v6-router
PLIST=/Library/LaunchDaemons/$LABEL.plist
N6=2001:db8::2
PORT=5201
DUR=${DUR:-10}
PAR=${PAR:-8}
KEY=/Users/${SUDO_USER:-nk}/.ssh/netcup-key
OUT="$(cd "$(dirname "$0")" && pwd)/out/speedtest-v6.txt"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

# 以普通用户身份 ssh（用他的 known_hosts），走 v6 地址
vps() { sudo -u "${SUDO_USER:-nk}" ssh -o ConnectTimeout=10 -o HostKeyAlias=203.0.113.20 -o IdentitiesOnly=yes -i "$KEY" "user@$N6" "$@"; }

IPERF=$(sudo -u "${SUDO_USER:-nk}" bash -lc 'command -v iperf3' || true)
[ -n "$IPERF" ] || { echo "本机缺 iperf3，先运行：brew install iperf3"; exit 1; }

SRC=$(ifconfig en0 | awk '/inet6 2/ && /secured/ && !/temporary/ {print $2; exit}')
[ -n "$SRC" ] || { echo "en0 没有全局 IPv6（不在校园网？）"; exit 1; }
NET="$(echo "$SRC" | cut -d: -f1-4)::/64"
RULE="-I PUBLIC-INPUT 1 -p tcp --dport $PORT -s $NET -j RETURN"

cleanup() {
  launchctl bootstrap system "$PLIST" 2>/dev/null; sleep 3
  echo "服务已恢复：$(launchctl print system/$LABEL 2>/dev/null | grep -m1 'state')"
  [ -n "${PREPPED:-}" ] && vps "sudo ip6tables ${RULE/-I PUBLIC-INPUT 1/-D PUBLIC-INPUT}; sudo pkill -x iperf3" && echo "VPS 临时规则已删、iperf3 已关"
  chown "${SUDO_USER:-root}" "$OUT" 2>/dev/null
}
trap cleanup EXIT

PREPPED=1
echo "准备 VPS（装 iperf3 / 临时放行 $NET → :${PORT}）..."
vps "command -v iperf3 >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null; \
     sudo ip6tables $RULE && (sudo nohup timeout 600 iperf3 -s -6 -p $PORT </dev/null >/dev/null 2>&1 &) ; sleep 1; pgrep -x iperf3 >/dev/null && echo server-ok" \
  | grep -q server-ok || { echo "VPS 端 iperf3 启动失败"; exit 1; }


run() { # $1=标题 其余=iperf3 参数
  local t=$1; shift
  echo "-- $t"
  sudo -u "${SUDO_USER:-nk}" "$IPERF" -6 -c "$N6" -p $PORT -B "$SRC" -t "$DUR" -O 2 -f m "$@" 2>&1 \
    | grep -E 'sender|receiver|error' | grep -E 'SUM|error|^\[ *[0-9]+\]' | tail -2
}

{
  echo "== $(date '+%F %T')  本机 $SRC → Netcup $N6  (DUR=${DUR}s PAR=$PAR)"
  launchctl bootout system/$LABEL 2>/dev/null; sleep 3
  echo "utun 路由残留: $(netstat -rn -f inet6 | grep -c 'fdfe:dcba')  去往 VPS 的出口: $(route -n get -inet6 $N6 | awk '/interface/{print $2}')"
  echo "-- ping6"; ping6 -c 10 -i 0.3 "$N6" 2>&1 | tail -2
  run "下载 单线程"            -R
  run "下载 ${PAR} 线程"        -R -P "$PAR"
  run "上传 单线程"
  run "上传 ${PAR} 线程"        -P "$PAR"
} 2>&1 | tee "$OUT"
