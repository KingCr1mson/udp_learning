#!/usr/bin/env bash
# ============================================================================
#  60-boundary.sh —— 报文边界、无流控、无重传
#
#  本节回答一个核心问题：UDP 到底把哪些责任推给了应用层？
#    ① 报文边界：UDP 保留，TCP 不保留（粘包问题的根源）
#    ② 可靠性：UDP 无确认无重传，TCP 有重传
#    ③ 发送语义：sendto 成功 ≠ 对端收到
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_topology
log_init "$LOG_DIR/60-boundary.log"

h1 "6. 报文边界、无流控、无重传"

# ------------------------------------------------ 6.1 UDP vs TCP 边界 ----
h2 "6.1 实验 A：报文边界（UDP 保留 vs TCP 字节流）"
info "准备接收端：UDP 监听 $PORT_BOUNDARY、TCP 监听 8081"
udp_listen "$C_SERVER" "$PORT_BOUNDARY" 30 "--no-echo"
tcp_listen "$C_SERVER" 8081 30
info "client 执行边界对比实验："
cex "$C_CLIENT" python3 /lab/tools/probe.py boundary \
  --host "$SERVER_IP" --sport "$PORT_BOUNDARY" \
  --udpport "$PORT_BOUNDARY" --tcpport 8081
log ""
info "server 端 UDP 接收日志："
udp_listen_log "$C_SERVER" "$PORT_BOUNDARY" 8
log ""
info "server 端 TCP 接收日志（注意 recv 的次数和每次的字节数）："
tcp_listen_log "$C_SERVER" 8081 12
note "UDP：一次 sendto 对应一次 recvfrom，长度完全保持。"
note "TCP：recv 的边界与 send 的边界毫无关系 —— 这就是“粘包/拆包”的来源。"
note "所以 UDP 应用可以“一个数据报 = 一条消息”，TCP 应用必须自己定边界。"
pause

# --------------------------------------------- 6.2 无重传对比实验 -------
h2 "6.2 实验 B：丢包时 UDP 无重传，TCP 会重传"
info "在 router 上对去往 server:$PORT_ECHO 的 UDP 报文做 1/3 概率丢包："
cex "$C_ROUTER" iptables -I FORWARD -p udp --dport "$PORT_ECHO" \
  -m statistic --mode random --probability 0.33 -j DROP
cex "$C_ROUTER" iptables -L FORWARD -n -v --line-numbers | head -4

info "server 起回显服务（把收到的报文原样回给 client）："
udp_listen "$C_SERVER" "$PORT_ECHO" 40

log ""
info "client 连发 10 个带序号的 UDP 报文，然后统计哪些序号没有回来："
cex "$C_CLIENT" python3 /lab/tools/udpecho.py client \
  --dst "$SERVER_IP" --port "$PORT_ECHO" --count 10 --delay 0.2 --wait 4
log ""
info "server 实际收到了哪几个序号（对比一下就看出丢了哪些）："
log "  server 收到的序号："
docker exec "$C_SERVER" bash -c "grep -o 'SEQ-[0-9]*' /tmp/echo-$PORT_ECHO.log | tr '\n' ' '; echo"

log ""
info "现在把 UDP 的丢包规则换成对 TCP 同端口丢包（1/3 概率），看 TCP 的表现："
cex "$C_ROUTER" iptables -I FORWARD -p tcp --dport 8080 \
  -m statistic --mode random --probability 0.33 -j DROP
tcp_listen "$C_SERVER" 8080 45
info "先记录 TCP 重传计数器基线（client 侧）："
docker exec "$C_CLIENT" netstat -s 2>/dev/null | grep -iE 'retrans|segments retrans' | sed 's/^/    /'

# 这里的 python 脚本用 cs（base64 直传）送进容器执行。
# 曾经踩过的坑：写成 cex "$C" python3 - <<PY 时 stdin 被 cex 占用，
# python3 - 读不到脚本，会静默什么都不做（日志里只剩一行 $ python3 -）。
cs "$C_CLIENT" 'cat > /tmp/tcpcli.py <<PYEOF
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
t0 = time.time()
try:
    s = socket.create_connection((host, port), timeout=15)
except OSError as e:
    print("    连接失败:", e, flush=True); sys.exit(1)
for i in range(1, 11):
    s.sendall(("TCP-SEQ-%03d\n" % i).encode())
    time.sleep(0.2)
time.sleep(1.5)
s.close()
print("    10 条消息发送完毕，耗时 %.2fs（TCP 内部处理了重传）" % (time.time()-t0), flush=True)
PYEOF
python3 /tmp/tcpcli.py "$1" "$2"' "$SERVER_IP" 8080
sleep 2
sleep 2
log ""
info "server 端 TCP 收到的行（应该 10 条齐全）："
printf '  server 收到的 TCP-SEQ 行数: '
docker exec "$C_SERVER" bash -c "grep -c 'TCP-SEQ' /tmp/tcpecho-8080.log 2>/dev/null || echo 0"
printf '  具体序号: '
docker exec "$C_SERVER" bash -c "grep -o 'TCP-SEQ-[0-9]*' /tmp/tcpecho-8080.log | tr '\n' ' '"
echo
log ""
info "再看 TCP 重传计数器（增加了说明确实发生了重传）："
docker exec "$C_CLIENT" netstat -s 2>/dev/null | grep -iE 'retrans|segments retrans' | sed 's/^/    /'

log ""
info "清理丢包规则："
cex "$C_ROUTER" iptables -D FORWARD -p udp --dport "$PORT_ECHO" \
  -m statistic --mode random --probability 0.33 -j DROP
cex "$C_ROUTER" iptables -D FORWARD -p tcp --dport 8080 \
  -m statistic --mode random --probability 0.33 -j DROP
cex "$C_ROUTER" iptables -L FORWARD -n --line-numbers | head -4
ok "已清理"
note "★ 对比结论："
note "  UDP：丢了就永远没了，应用只能自己实现超时+重传+去重+序号"
note "  TCP：内核用序号+确认+重传把丢包藏起来，应用完全无感"
note "  这就是“UDP 是不可靠的”这句话在工程上的全部含义。"
pause

# ------------------------------------------------ 6.3 广播与多播 --------
h2 "6.3 顺带验证：UDP 支持广播，TCP 不支持"
info "Docker 的 bridge 默认不转发广播，这里只在【同一链路内】验证："
info "在 server 上监听 0.0.0.0，从同一网段发一个广播报文 —— "
info "由于本实验的 server 与 client 不在同一网段（中间有 router），"
info "广播不会跨路由器转发，这正是广播的边界所在。改用路由器自身的链路演示："
# 说明：这里要往容器里送一段多行 python，直接塞进 bash -c "..." 很容易被
# 引号/heredoc 搅乱，所以改成"先写脚本文件，再执行它"。
cs "$C_ROUTER" 'cat > /tmp/bcast.py; python3 /tmp/bcast.py' <<'PYEOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    s.sendto(b"UDP-BROADCAST-TEST", ("172.31.11.255", 9990))
    print("    已向 172.31.11.255:9990 发送广播（本网段内）")
except OSError as e:
    print("    广播发送失败:", e)
s.close()
PYEOF
note "广播/多播的关键限制："
note "  · 路由器默认不转发广播（广播域止于路由器）—— 所以 DHCP 必须有中继"
note "  · 不为广播/多播报文产生 ICMP 差错 —— 所以广播探测收不到错误反馈"
note "  · 广播会打断同网段所有主机的 CPU，规模稍大就应该改用多播"
pause

# ------------------------------------------------ 6.4 UDP 适用场景 ------
h2 "6.4 什么样的应用该选 UDP"
log "  ┌──────────────┬──────┬──────────────────────────────────────────┐"
log "  │ 应用         │ 端口 │ 为什么用 UDP                             │"
log "  ├──────────────┼──────┼──────────────────────────────────────────┤"
log "  │ DNS          │ 53   │ 一问一答很短；重传比建连更划算；限制512字节│"
log "  │ DHCP         │67/68 │ 此时主机还没有 IP，无法建立 TCP 连接      │"
log "  │ TFTP         │ 69   │ 协议极简，用于无盘工作站                  │"
log "  │ SNMP         │ 161  │ 单次查询/trap，简单                       │"
log "  │ NTP          │ 123  │ 需要往返时延测量，重传反而有害            │"
log "  │ RTP/音视频   │ 动态 │ 实时性优先，迟到的重传数据没有价值        │"
log "  │ syslog       │ 514  │ 量大，丢一点可接受                        │"
log "  │ QUIC/HTTP3   │ 443  │ 在 UDP 上自建可靠性，避开 TCP 队头阻塞    │"
log "  └──────────────┴──────┴──────────────────────────────────────────┘"
log ""
log "  共同点：短报文 / 简单请求响应 / 广播多播需求 / 需要自己控制可靠性策略"
log "  反之：文件传输、远程登录、HTTP/1.1 与 HTTP/2、SMTP 都用 TCP"

h1 "小结：UDP 的设计哲学"
log "  UDP 只做两件事："
log "    ① 用端口找到进程（复用/分用）"
log "    ② 用校验和发现数据损坏（可选）"
log "  其余一律交给应用层：可靠性、顺序、流量控制、拥塞控制、报文大小管理。"
log ""
log "  “不可靠”不是缺陷，而是为了换取："
log "    · 极低开销（8 字节首部，无状态）"
log "    · 极低延迟（无需握手，无需等确认）"
log "    · 支持广播/多播"
log "    · 应用可以完全掌控自己的重传/拥塞策略（QUIC 就是这么干的）"
log ""
log "日志: logs/60-boundary.log"
