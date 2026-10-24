#!/bin/bash
# 国内常用站冒烟测试：用 out/mac/config.json 起一个临时 sing-box（端口 18808，不开 TUN，不影响已安装的服务），
# 逐个访问并列出 状态码 / 耗时 / 实际出口。改完配置、./update.sh 之前跑一遍。用法：./test-sites.sh [站点...]
# 说明：经代理端口访问时目标是域名，相当于 TUN 下「只有 v4」的情况；知乎、百度地图对 curl 本来就返回 403，不算故障
set -u
cd "$(dirname "$0")"
SB=/usr/local/libexec/neu-v6-router/sing-box
T=$(mktemp -d /tmp/neu-sites.XXXXXX); trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
[ -f out/mac/config.json ] || node ../cli.js -c profile.yaml -c config.local.yaml -p mac -o out >/dev/null
python3 - "$T" <<'PY'
import json, os, sys
T = sys.argv[1]; c = json.load(open("out/mac/config.json"))
c["inbounds"] = [dict(i, listen_port=18808) for i in c["inbounds"] if i["tag"] == "main"]
c["route"]["rules"] = [r for r in c["route"]["rules"] if "inbound" not in r]
for r in c["route"]["rule_set"]:  # 用刚生成的规则集，新加的规则集可能还没装到系统目录
    if r.get("type") == "local": r["path"] = os.path.abspath(os.path.join("out/mac/rules", os.path.basename(r["path"])))
c["experimental"] = {"cache_file": {"enabled": True, "path": T + "/cache.db", "store_fakeip": True}}
c["log"] = {"level": "info", "timestamp": True}
json.dump(c, open(T + "/c.json", "w"))
PY
"$SB" run -c "$T/c.json" -D "$T" >"$T/log" 2>&1 & PID=$!; sleep 4
SITES=${*:-"res.wx.qq.com/open/js/jweixin-1.6.0.js open.weixin.qq.com login.taobao.com www.alipay.com passport.jd.com www.12306.cn kyfw.12306.cn www.icbc.com.cn www.ccb.com www.boc.cn www.cmbchina.com pan.baidu.com www.baidu.com www.bilibili.com www.douyin.com www.xiaohongshu.com www.cnki.net kns.cnki.net www.neu.edu.cn music.163.com www.qq.com www.meituan.com www.ctrip.com www.csdn.net www.weibo.com www.iqiyi.com www.163.com www.mi.com www.huawei.com www.chsi.com.cn"}
for u in $SITES; do
  r=$(curl -s -o /dev/null -m 12 -L --max-redirs 3 -A "Mozilla/5.0" -x http://127.0.0.1:18808 -w "%{http_code} %{time_total}s" "https://$u" 2>/dev/null)
  h=${u%%/*}; out=$(sed -E 's/\x1b\[[0-9;]*m//g' "$T/log" | grep -F "$h" | grep -o -E "outbound/[a-z0-9]+\[[^]]*\]" | tail -1 | sed -E 's/outbound\/[a-z0-9]+\[(.*)\]/\1/')
  case "$r" in 2*|3*) mark="  ";; *) mark="✗ ";; esac
  printf "%s%-22s %-16s %s\n" "$mark" "$h" "$r" "$out"
done
