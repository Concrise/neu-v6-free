# 复制为 servers.local.sh 并填写（servers.local.sh 不入库）。测速 / 诊断 / 监测脚本会读取它
HK_V6=2001:db8::1                        # 港机 IPv6
HK_USER=ubuntu HK_KEY=hk-key             # 港机 SSH 用户与 ~/.ssh 下的私钥文件名
NC_V4=203.0.113.20                       # Netcup IPv4（known_hosts 里按它记的）
NC_V6=2001:db8::2
NC_USER=user NC_KEY=netcup-key           # Netcup SSH 用户与私钥文件名
NC_FW_CHAIN=PUBLIC-INPUT                 # Netcup ip6tables 放行用的链
NC_PORTS="443 8443"                      # Netcup 上用来测 v6 TCP 可达的端口（第一个给 v6monitor）
SSH_PORT=22
