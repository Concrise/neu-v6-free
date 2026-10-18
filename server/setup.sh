#!/bin/bash
# 模式二服务器一键部署：在 Debian / Ubuntu 的双栈 VPS 上装 sing-box，开 Reality / AnyTLS / Hysteria2 / TUIC 四个入站（都监听 ::）。
# 用法（root）：
#   bash setup.sh              首次部署；再次运行不会换密码，只重新输出节点信息
#   bash setup.sh --show       只输出节点信息
#   bash setup.sh --uninstall  停止并删除本脚本生成的配置（不卸载 sing-box 软件包）
# 可选环境变量：
#   SB_VERSION=1.14.2          sing-box 版本
#   PORTS="41443 41444 41445 41446"   Reality(tcp) AnyTLS(tcp) Hysteria2(udp) TUIC(udp) 的端口；默认随机高位端口
#   REALITY_SNI=www.microsoft.com     Reality 伪装的网站（需支持 TLS 1.3）
#   LABEL="我的服务器"          生成的客户端设置里的服务器名
#   V4=… V6=…                  手动指定公网地址（NAT 机器或自动检测不准时）
#   CONF_DIR=/etc/sing-box  NO_SERVICE=1   测试用：换配置目录、不碰 systemd 服务（不会影响机器上已有的 sing-box）
# 本脚本不改防火墙，只提示需要放行的端口。
set -euo pipefail

SB_VERSION=${SB_VERSION:-1.14.2}
REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
LABEL=${LABEL:-我的服务器}
CONF_DIR=${CONF_DIR:-/etc/sing-box}
STATE=$CONF_DIR/neu-v6-free.state    # 生成的凭据与端口（JSON，600），重跑时沿用；不能叫 .json：sing-box -C 会把目录里所有 .json 当配置读
CONFIG=$CONF_DIR/config.json
OUT=${OUT:-/root/neu-v6-nodes.yaml}  # 给客户端用的设置片段

die() { echo "错误：$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 root 运行（sudo bash setup.sh）"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now sing-box 2>/dev/null || true
  rm -f "$CONFIG" "$STATE" "$OUT"; rm -rf "$CONF_DIR/neu-v6-cert"
  echo "已停止 sing-box 并删除本脚本生成的配置。卸载软件包：apt-get remove sing-box"
  exit 0
fi

# ---------- 公网地址 ----------
pub_ip() { # $1 = 4 / 6
  local ip
  for u in https://api64.ipify.org https://ip.sb https://ifconfig.co; do
    ip=$(curl -"$1" -fsS -m 8 "$u" 2>/dev/null || true)
    [ -n "$ip" ] && { echo "$ip"; return; }
  done
}
V4=${V4:-$(pub_ip 4)}; V6=${V6:-$(pub_ip 6)}
[ -n "$V4" ] || die "没检测到公网 IPv4（模式二需要服务器出 v4）"
if [ -z "$V6" ]; then
  V6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/temporary|deprecated/ {sub(/\/.*/,"",$2); print $2; exit}')
  [ -n "$V6" ] || die "没检测到 IPv6。模式二要求服务器有公网 IPv6（校园网 v6 才能连上来）"
  echo "提示：IPv6 出站测不通，按网卡地址 $V6 处理；请确认云平台已给这台机器分配并放行 IPv6"
fi

# ---------- 安装 sing-box ----------
if [ "${1:-}" != "--show" ]; then
  command -v apt-get >/dev/null || die "只支持 Debian / Ubuntu（apt）"
  case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) die "不支持的架构 $(uname -m)" ;; esac
  if ! command -v sing-box >/dev/null || [ "$(sing-box version 2>/dev/null | awk 'NR==1{print $3}')" != "$SB_VERSION" ]; then
    echo "安装 sing-box $SB_VERSION ($ARCH)..."
    T=$(mktemp -d /tmp/sb.XXXXXX)
    curl -fsSL -m 300 -o "$T/sb.deb" \
      "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/sing-box_${SB_VERSION}_linux_$ARCH.deb" \
      || { rm -rf "$T"; die "下载 sing-box 失败（GitHub 不通时可手动下载 deb 后 apt install ./sing-box*.deb，再重跑本脚本）"; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$T/sb.deb" >/dev/null
    rm -rf "$T"
  fi
  command -v openssl >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null
fi
command -v sing-box >/dev/null || die "sing-box 未安装，先不带 --show 运行一次"
command -v python3 >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null

# ---------- 生成凭据（已有则沿用） ----------
[ "${1:-}" = "--show" ] && [ ! -f "$STATE" ] && die "还没部署过，先不带 --show 运行"
mkdir -p "$CONF_DIR/neu-v6-cert"
if [ ! -f "$STATE" ]; then
  [ -f "$CONFIG" ] && cp -a "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d-%H%M%S)" && echo "已备份原有 $CONFIG"
  KP=$(sing-box generate reality-keypair)
  PRIV=$(echo "$KP" | awk '/PrivateKey/{print $2}'); PUB=$(echo "$KP" | awk '/PublicKey/{print $2}')
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -keyout "$CONF_DIR/neu-v6-cert/key.pem" -out "$CONF_DIR/neu-v6-cert/cert.pem" \
    -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" 2>/dev/null
  PRIV="$PRIV" PUB="$PUB" PORTS="${PORTS:-}" REALITY_SNI="$REALITY_SNI" python3 - "$STATE" <<'PY'
import json, os, random, secrets, sys, uuid
ports = [int(p) for p in os.environ["PORTS"].split()] if os.environ["PORTS"] else random.sample(range(20000, 60000), 4)
assert len(ports) == 4, "PORTS 需要 4 个端口"
s = dict(ports=dict(reality=ports[0], anytls=ports[1], hy2=ports[2], tuic=ports[3]),
         reality_sni=os.environ["REALITY_SNI"], reality_priv=os.environ["PRIV"], reality_pub=os.environ["PUB"],
         short_id=secrets.token_hex(8), vless_uuid=str(uuid.uuid4()), anytls_pass=secrets.token_urlsafe(18),
         hy2_pass=secrets.token_urlsafe(18), tuic_uuid=str(uuid.uuid4()), tuic_pass=secrets.token_urlsafe(18))
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(s, indent=2).encode()); os.close(fd)
PY
  echo "已生成新的凭据与端口"
fi

# ---------- 写 sing-box 配置（每次按凭据重写，可修复被改坏的配置） ----------
if [ "${1:-}" != "--show" ]; then
  python3 - "$STATE" "$CONFIG" "$CONF_DIR" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); P = s["ports"]; D = sys.argv[3]
cert = {"certificate_path": f"{D}/neu-v6-cert/cert.pem", "key_path": f"{D}/neu-v6-cert/key.pem"}
cfg = {
  "log": {"level": "warn", "timestamp": True},
  "dns": {"servers": [{"type": "local", "tag": "local"}], "strategy": "prefer_ipv4"},
  "inbounds": [
    {"type": "vless", "tag": "reality", "listen": "::", "listen_port": P["reality"],
     "users": [{"uuid": s["vless_uuid"], "flow": "xtls-rprx-vision"}],
     "tls": {"enabled": True, "server_name": s["reality_sni"],
             "reality": {"enabled": True, "handshake": {"server": s["reality_sni"], "server_port": 443},
                         "private_key": s["reality_priv"], "short_id": [s["short_id"]]}}},
    {"type": "anytls", "tag": "anytls", "listen": "::", "listen_port": P["anytls"],
     "users": [{"name": "neu", "password": s["anytls_pass"]}], "tls": {"enabled": True, "server_name": "www.bing.com", **cert}},
    # ignore_client_bandwidth=false：客户端设了 Brutal 带宽时按它发包
    {"type": "hysteria2", "tag": "hy2", "listen": "::", "listen_port": P["hy2"],
     "users": [{"password": s["hy2_pass"]}], "ignore_client_bandwidth": False,
     "tls": {"enabled": True, "alpn": ["h3"], **cert}},
    {"type": "tuic", "tag": "tuic", "listen": "::", "listen_port": P["tuic"],
     "users": [{"uuid": s["tuic_uuid"], "password": s["tuic_pass"]}], "congestion_control": "bbr",
     "tls": {"enabled": True, "alpn": ["h3"], **cert}},
  ],
  # 出站优先 v4：模式二的意义就是「v6 进、v4 出」
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"rules": [{"action": "sniff"}], "final": "direct",
            "default_domain_resolver": {"server": "local", "strategy": "prefer_ipv4"}},
}
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
  chown -R root:sing-box "$CONF_DIR" 2>/dev/null || true
  chmod 750 "$CONF_DIR" "$CONF_DIR/neu-v6-cert"; chmod 640 "$CONFIG" "$CONF_DIR"/neu-v6-cert/*.pem; chmod 600 "$STATE"
  sing-box check -C "$CONF_DIR" || die "sing-box 配置检查失败"
  if [ -n "${NO_SERVICE:-}" ]; then echo "NO_SERVICE：跳过服务启动，手动运行 sing-box run -C $CONF_DIR"; else
  systemctl enable sing-box >/dev/null 2>&1
  systemctl restart sing-box
  sleep 2
  systemctl is-active -q sing-box || { journalctl -u sing-box -n 20 --no-pager; die "sing-box 启动失败"; }
  fi
  # 开 BBR（没开的话）：对 TCP 入口（Reality/AnyTLS）的速度影响很大
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != bbr ] && modprobe tcp_bbr 2>/dev/null; then
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > /etc/sysctl.d/90-neu-v6-bbr.conf
    sysctl -q -p /etc/sysctl.d/90-neu-v6-bbr.conf && echo "已开启 BBR"
  fi
fi

# ---------- 输出客户端设置 ----------
V4="$V4" V6="$V6" LABEL="$LABEL" python3 - "$STATE" "$OUT" <<'PY'
import json, os, sys
s = json.load(open(sys.argv[1])); P = s["ports"]; v4, v6, label = os.environ["V4"], os.environ["V6"], os.environ["LABEL"]
q = lambda x: json.dumps(x, ensure_ascii=False)
lines = [
  "# 粘贴到客户端 config.yaml（或网页生成器）。含密码，不要公开。",
  "entry_servers:",
  f"  {q(v4)}: {{ v6: {q(v6)}, label: {q(label)} }}",
  "entry_default: vless   # 「免流服务器」默认用 Reality（TCP）；丢包多的线路可改 hysteria2",
  "nodes:",
  f"  - {{ name: {q(label + '-Reality')}, type: vless, server: {q(v4)}, port: {P['reality']}, uuid: {q(s['vless_uuid'])}, flow: xtls-rprx-vision, network: tcp, tls: true, udp: true, servername: {q(s['reality_sni'])}, client-fingerprint: chrome, reality-opts: {{ public-key: {q(s['reality_pub'])}, short-id: {q(s['short_id'])} }} }}",
  f"  - {{ name: {q(label + '-AnyTLS')}, type: anytls, server: {q(v4)}, port: {P['anytls']}, password: {q(s['anytls_pass'])}, sni: www.bing.com, skip-cert-verify: true, udp: true }}",
  f"  - {{ name: {q(label + '-Hysteria2')}, type: hysteria2, server: {q(v4)}, port: {P['hy2']}, password: {q(s['hy2_pass'])}, sni: www.bing.com, skip-cert-verify: true, alpn: [h3] }}",
  f"  - {{ name: {q(label + '-TUIC')}, type: tuic, server: {q(v4)}, port: {P['tuic']}, uuid: {q(s['tuic_uuid'])}, password: {q(s['tuic_pass'])}, sni: www.bing.com, skip-cert-verify: true, alpn: [h3], congestion-controller: bbr, udp-relay-mode: native }}",
]
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, ("\n".join(lines) + "\n").encode()); os.close(fd)
PY
P=$(python3 -c "import json;p=json.load(open('$STATE'))['ports'];print(p['reality'],p['anytls'],p['hy2'],p['tuic'])")
read -r PR PA PH PT <<<"$P"

echo
echo "================ 客户端设置（已保存到 $OUT） ================"
cat "$OUT"
echo "============================================================="
echo
echo "服务器：IPv4 $V4 / IPv6 $V6"
echo "需要放行的端口（IPv4 与 IPv6 都要）：TCP $PR、$PA；UDP $PH、$PT"
echo "  1) 云平台的安全组 / 防火墙规则"
# 先取完整输出再匹配：pipefail 下 `cmd | grep -q` 会因 grep 提前退出、cmd 收到 SIGPIPE 而判为失败
if command -v ufw >/dev/null && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
  echo "  2) 本机 ufw 已启用，运行：ufw allow $PR/tcp && ufw allow $PA/tcp && ufw allow $PH/udp && ufw allow $PT/udp"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  echo "  2) 本机 firewalld 已启用，运行：for p in $PR/tcp $PA/tcp $PH/udp $PT/udp; do firewall-cmd --permanent --add-port=\$p; done; firewall-cmd --reload"
elif command -v nft >/dev/null && [[ "$(nft list ruleset 2>/dev/null)" == *"policy drop"* ]]; then
  echo "  2) 本机 nftables 有默认拒绝的规则，请在 input 链加：tcp dport { $PR, $PA } accept 和 udp dport { $PH, $PT } accept"
else
  echo "  2) 本机没发现启用中的防火墙，只需处理云平台安全组"
fi
echo
echo "注意：服务器出站流量会算进云平台的流量额度，留意计费。"
