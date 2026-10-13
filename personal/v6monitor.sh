#!/bin/bash
# 每次运行记录一行：校园网出国 IPv6 的 ICMP / TCP 是否可达（绑定 en0，绕开 TUN；每次只有几 KB）。
# 由 LaunchAgent com.nk.neu-v6-monitor 每 30 分钟调用；日志 out/v6monitor.log
LOG="$(cd "$(dirname "$0")" && pwd)/out/v6monitor.log"
N6=2001:db8::2
IF=en0

tcp() {  # 输出连接耗时 ms，失败输出 X
  local t
  t=$(curl -6 -s --noproxy '*' --interface "$IF" --connect-timeout 6 -m 8 -k -o /dev/null -w '%{time_connect}' "$1" 2>/dev/null)
  awk -v t="$t" 'BEGIN { if (t+0 > 0) printf "%d", t*1000; else printf "X" }'
}

ping_ms=$(ping6 -c 3 -B "$IF" "$N6" 2>/dev/null | awk -F/ '/round-trip/ {printf "%d", $5}')
printf '%s  ping6:%s  netcup-tcp:%s  cloudflare-tcp:%s  清华-tcp:%s\n' \
  "$(date '+%F %H:%M')" "${ping_ms:-X}" \
  "$(tcp "https://[$N6]:443/")" \
  "$(tcp https://www.cloudflare.com/cdn-cgi/trace)" \
  "$(tcp https://mirrors.tuna.tsinghua.edu.cn/)" >> "$LOG"
