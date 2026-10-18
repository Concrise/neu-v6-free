#!/bin/bash
# 纯 IPv6 直连测 Azure 香港（azure-hk）网络质量：丢包/抖动 + TCP 带宽 + UDP 定速丢包。用法：sudo ./speedtest-hk.sh
# 目的：判断 TCP 入口（Reality/AnyTLS）是否够用，还是需要 UDP（Hy2/TUIC）。
# 流程：港机 nftables 临时放行本机 /64 → :5201 → 暂停 TUN 服务 → 测试 → 恢复服务、删规则、关 iperf3
# 结果写到 out/speedtest-hk.txt。可调：DUR=5 DL_MB=50 UDP_RATES="30 60 100" PAR=0（>0 才测多线程下载）
# 注意：下载测试是港机发数据，耗港机出站额度。默认封顶约 150MB：TCP 下载 50MB + UDP 下载 (30+60+100)Mbps×4s≈95MB。
set -u
LABEL=com.nk.neu-v6-router
PLIST=/Library/LaunchDaemons/$LABEL.plist
H6=2001:db8::1
PORT=5201
DUR=${DUR:-5}        # 上传与 ping 以外各项的时长（秒）；上传不耗港机出站额度
DL_MB=${DL_MB:-50}   # TCP 下载按数据量封顶，不按时长，线路再快也不会多耗
UDP_DUR=${UDP_DUR:-4}
PAR=${PAR:-0}
UDP_RATES=${UDP_RATES:-"30 60 100"}
U=${SUDO_USER:-nk}
KEY=/Users/$U/.ssh/azure-hk
OUT="$(cd "$(dirname "$0")" && pwd)/out/speedtest-hk.txt"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }

# 以普通用户身份 ssh，走 v6 地址（TUN 停掉后 v4 会走计费线路）
hk() { sudo -u "$U" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$KEY" -p 22 "ubuntu@$H6" "$@"; }

IPERF=$(sudo -u "$U" bash -lc 'command -v iperf3' || true)
[ -n "$IPERF" ] || { echo "本机缺 iperf3，先运行：brew install iperf3"; exit 1; }

SRC=$(ifconfig en0 | awk '/inet6 2/ && /secured/ && !/temporary/ {print $2; exit}')
[ -n "$SRC" ] || { echo "en0 没有全局 IPv6（不在校园网？）"; exit 1; }
NET="$(echo "$SRC" | cut -d: -f1-4)::/64"

cleanup() {
  launchctl bootstrap system "$PLIST" 2>/dev/null; sleep 3
  echo "服务已恢复：$(launchctl print system/$LABEL 2>/dev/null | grep -m1 'state')"
  [ -n "${PREPPED:-}" ] && hk 'for h in $(sudo nft -a list chain inet filter input | awk "/iperf-tmp/{print \$NF}"); do sudo nft delete rule inet filter input handle $h; done; sudo pkill -x iperf3; true' \
    && echo "港机临时规则已删、iperf3 已关"
  chown "$U" "$OUT" 2>/dev/null
}
trap cleanup EXIT

echo "准备港机（临时放行 $NET → :${PORT}，iperf3 最多运行 10 分钟）..."
PREPPED=1
hk "sudo nft insert rule inet filter input ip6 saddr $NET meta l4proto { tcp, udp } th dport $PORT accept comment iperf-tmp && \
    (sudo nohup timeout 600 iperf3 -s -p $PORT </dev/null >/dev/null 2>&1 &) ; sleep 1; pgrep -x iperf3 >/dev/null && echo server-ok" \
  | grep -q server-ok || { echo "港机 iperf3 启动失败"; exit 1; }

ip3() { sudo -u "$U" "$IPERF" -6 -c "$H6" -p $PORT -B "$SRC" -f m "$@" 2>&1; }

tcp() { # $1=标题 其余=iperf3 参数；输出 发送端/接收端速率与重传
  local t=$1; shift
  echo "-- $t"
  ip3 "$@" | grep -E 'sender|receiver|error' | grep -E 'SUM|error|^\[ *[0-9]+\]' | tail -2
}

udp() { # $1=标题 $2=速率Mbps 其余=iperf3 参数；输出 实收速率、抖动、丢包
  local t=$1 r=$2; shift 2
  echo "-- $t ${r}Mbps"
  ip3 -t "$UDP_DUR" -u -b "${r}M" -l 1200 "$@" | grep -E 'receiver|error' | tail -1
}

{
  echo "== $(date '+%F %T')  本机 $SRC → 港机 $H6  (下载封顶 ${DL_MB}MB，UDP ${UDP_RATES} Mbps×${UDP_DUR}s)"
  launchctl bootout system/$LABEL 2>/dev/null; sleep 3
  echo "去往港机的出口: $(route -n get -inet6 $H6 | awk '/interface/{print $2}')（应为 en0）"
  echo "-- ping6 100 个包（看丢包与抖动 std-dev）"; ping6 -c 100 -i 0.2 "$H6" 2>&1 | tail -2
  tcp "TCP 下载 单线程（${DL_MB}MB）" -R -n "${DL_MB}M"
  [ "$PAR" -gt 0 ] && tcp "TCP 下载 ${PAR} 线程（${DL_MB}MB）" -R -P "$PAR" -n "${DL_MB}M"
  tcp "TCP 上传 单线程" -t "$DUR" -O 1
  for r in $UDP_RATES; do udp "UDP 下载" "$r" -R; done
  udp "UDP 上传" 30
  cat <<'TXT'

怎么看：
- ping 丢包 <1%、std-dev 小 → 线路干净，TCP 入口一般够用。
- TCP 单线程下载接近 UDP 下载里「丢包很低」那一档的速率 → TCP 够用，Reality/AnyTLS 即可。
- TCP 明显低于 UDP、重传（Retr 列）很多，或 UDP 在低速率就开始丢包 → 丢包多的线路，Hy2（Brutal）/TUIC 会快很多。
TXT
} 2>&1 | tee "$OUT"
