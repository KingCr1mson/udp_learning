#!/usr/bin/env bash
# ============================================================================
#  10-udp-header.sh —— UDP 首部、伪首部与校验和
#
#  本章第一个重点：UDP 首部只有 8 字节，四个字段各 16 位。
#  本脚本用三种方式让你"看见"它：
#    ① 自己在容器里手算校验和（含伪首部）
#    ② 抓下内核真正发出的字节流并逐字段解析
#    ③ 用 tcpdump -X 做十六进制转储
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_topology
log_init "$LOG_DIR/10-udp-header.log"

h1 "1. UDP 首部与校验和"

# ------------------------------------------------------- 1.1 先看静态事实 ---
h2 "1.1 静态事实：端口、长度字段的取值范围"
log "本实验用到的端口："
log "  正常监听端口 PORT_ECHO     = $PORT_ECHO"
log "  故意空置端口 PORT_CLOSED   = $PORT_CLOSED"
log ""
info "知名端口（IANA 分配的 0-1023）示例："
log "  53   DNS      67/68 DHCP     69   TFTP"
log "  123  NTP      161   SNMP      514  syslog"
note "UDP 长度字段 16 位 => 单个 UDP 报文最大 65535 字节（首部+数据）。"
note "它是冗余的（IP 首部已有总长度），保留是为了 UDP 能自描述。"

# --------------------------------------------- 1.2 手算校验和（重点） -----
h2 "1.2 手算 UDP 校验和（本章最常考的计算）"
info "在 client 容器里运行 udplab.py csum："
cex "$C_CLIENT" python3 /lab/tools/udplab.py csum \
  --src "$CLIENT_IP" --dst "$SERVER_IP" --sport 4660 --dport 22136 \
  --payload ABCDEF
pause

# ------------------------------------------- 1.3 抓真实发出的字节流 -------
h2 "1.3 抓内核真正发出的字节流，逐字段解析"
info "先在 server 上开一个 UDP 监听（用 nc），并抓包："
udp_listen "$C_SERVER" "$PORT_ECHO" 30
cap_start "$C_SERVER" eth0 "udp port $PORT_ECHO" "10-header"
sleep 1

info "client 发送一个 9 字节载荷的 UDP 报文，同时抓本地发出的包："
cex "$C_CLIENT" python3 /lab/tools/udplab.py dump \
  --src "$CLIENT_IP" --dst "$SERVER_IP" --sport 40000 --dport "$PORT_ECHO" \
  --payload "HELLO-UDP"

sleep 1
cap_stop "$C_SERVER" "10-header"
log ""
info "server 收到的内容（nc 写出的原始数据）："
udp_listen_log "$C_SERVER" "$PORT_ECHO" 10

log ""
info "抓包文本（注意 UDP 行的 length 与 cksum 字段）："
grep -E 'UDP|IP ' "$CAP_DIR/10-header.txt" 2>/dev/null | head -20 || \
  cat "$CAP_DIR/10-header.txt" 2>/dev/null | head -20

h2 "1.4 校验和错误会怎样？"
info "发送一个校验和故意写错的报文（客户端用 raw socket 自拼首部）："
udp_listen "$C_SERVER" "$PORT_ECHO" 12
cex "$C_CLIENT" python3 /lab/tools/udplab.py sendraw \
  --src "$CLIENT_IP" --dst "$SERVER_IP" --sport 40002 --dport "$PORT_ECHO" \
  --size 16 --bad-checksum
sleep 1
log ""
info "server 是否收到？"
udp_listen_log "$C_SERVER" "$PORT_ECHO" 10
info "上面若没有 '收到' 行，说明校验和错误的报文被内核静默丢弃了"
note "接收方校验失败会静默丢弃 —— UDP 不产生任何差错报文，也不通知发送方。"
note "所以“UDP 有校验和”只意味着能发现损坏，不意味着会告诉你。"

h2 "1.5 校验和填 0 = 未计算（IPv4 允许）"
udp_listen "$C_SERVER" "$PORT_ECHO" 12
cex "$C_CLIENT" python3 /lab/tools/udplab.py sendraw \
  --src "$CLIENT_IP" --dst "$SERVER_IP" --sport 40003 --dport "$PORT_ECHO" \
  --size 16 --no-checksum
sleep 1
info "server 收到情况："
udp_listen_log "$C_SERVER" "$PORT_ECHO" 10
note "校验和为 0 时接收方按“发送方没有计算”处理，直接放行 —— 数据损坏无法发现。"
note "IPv6 中 UDP 校验和是强制的，因为 IPv6 首部自己也没有校验和。"

h2 "1.6 用 tcpdump -X 看十六进制转储"
cap_start "$C_SERVER" eth0 "udp port $PORT_ECHO" "10-hexdump"
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_ECHO" --size 20 --df 0
sleep 1
cap_stop "$C_SERVER" "10-hexdump"
log ""
info "抓包文本（-X 风格的关键片段）："
docker exec "$C_SERVER" tcpdump -nn -X -c 1 -r /lab/cap/10-hexdump.pcap 2>/dev/null \
  | sed 's/^/  /' || true

# ----------------------------------------------------------- 1.7 小结 -----
h1 "小结：UDP 首部"
log "  ┌────────────────┬──────────┬────────────────────────────────────┐"
log "  │ 字段           │ 长度     │ 要点                               │"
log "  ├────────────────┼──────────┼────────────────────────────────────┤"
log "  │ 源端口         │ 16 位    │ 可为 0（不需要回程应答时）         │"
log "  │ 目的端口       │ 16 位    │ 无效则回 ICMP 端口不可达           │"
log "  │ UDP 长度       │ 16 位    │ 首部+数据；最小 8，最大 65535      │"
log "  │ UDP 校验和     │ 16 位    │ 覆盖伪首部+首部+数据；0=未计算     │"
log "  └────────────────┴──────────┴────────────────────────────────────┘"
log ""
note "校验和为什么要有伪首部：IP 层不校验自己的载荷，把 IP 地址纳入校验，"
note "才能在地址被损坏时发现（否则报文可能送到错误的主机）。"
note "IPv4 可选 / IPv6 强制；算出 0 要写 0xFFFF。"
log ""
log "日志: logs/10-udp-header.log"
log "抓包: capture/10-header.pcap, capture/10-hexdump.pcap"
