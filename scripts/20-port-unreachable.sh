#!/usr/bin/env bash
# ============================================================================
#  20-port-unreachable.sh —— ICMP 端口不可达
#
#  目标：理解三件事
#    ① 这个 ICMP 差错报文是 IP/ICMP 层产生的，不是 UDP 层产生的
#    ② ICMP 差错只带回原报文的前 8 字节 —— 刚好是 UDP 首部，
#       所以接收方"勉强"能靠端口号把它关联回某个 socket
#    ③ 这种关联很不可靠：未 connect 的 socket 往往直接丢弃该差错
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_topology
log_init "$LOG_DIR/20-port-unreachable.log"

h1 "2. ICMP 端口不可达（Type 3 / Code 3）"

# --------------------------------------------- 2.1 server 上无进程监听 ---
h2 "2.1 向一个没有任何进程监听的端口发 UDP"
info "先在 client 上抓 ICMP，再向 server:$PORT_CLOSED 发一个 UDP 报文："
cap_start "$C_CLIENT" eth0 "icmp" "20-port-unreach-client"
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_CLOSED" --size 24 --df 0
sleep 2
cap_stop "$C_CLIENT" "20-port-unreach-client"
log ""
info "client 本机抓到的 ICMP："
cat "$CAP_DIR/20-port-unreach-client.txt" 2>/dev/null | sed 's/^/  /' || \
  warn "抓包为空"

# ------------------------------------------ 2.2 解码 ICMP 报文内部结构 ---
h2 "2.2 解码 ICMP 差错报文内部结构"
info "用 raw socket 监听并解析（注意内嵌的原报文前 8 字节 = UDP 首部）："
( cex "$C_CLIENT" python3 /lab/tools/udplab.py icmpwatch --timeout 6 & ) 2>/dev/null
sleep 1
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_CLOSED" --size 24 --df 0
sleep 7
note "ICMP 差错报文格式：8 字节 ICMP 首部 + 原始 IP 首部 + 原始数据前 8 字节"
note "为什么是 8 字节？因为 UDP 首部就是 8 字节 —— 刚好够取出端口号"
note "如果原报文是 TCP，前 8 字节是源端口+目的端口+序号，也够用"
pause

# ------------------------------------ 2.3 未 connect 的 socket 收不到 ----
h2 "2.3 关键对比：未 connect 的 UDP socket 收不到这个差错"
info "在 client 下发一个报文到不存在的端口，然后立刻尝试 recvfrom："
cex "$C_CLIENT" bash -c '
python3 - <<PY
import socket, struct, time, errno
dst=("'"$SERVER_IP"'", '"$PORT_CLOSED"')

# --- 情况 A：未 connect ---
a = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
a.bind(("'"$CLIENT_IP"'", 45000))
a.settimeout(2)
a.sendto(b"A"*16, dst)
print("A) 未 connect 的 socket 已发送")
time.sleep(1)
try:
    d,addr = a.recvfrom(2048)
    print("   recvfrom 收到:", d[:20], "来自", addr)
except OSError as e:
    print(f"   recvfrom 失败: [{e.errno}] {e.strerror}")
print("   -> 大多数实现里，未 connect 的 socket 会直接丢弃 ICMP 差错，")
print("      应用只能靠自己的超时机制判断（TFTP 就是这样）。")

# --- 情况 B：已 connect ---
b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
b.bind(("'"$CLIENT_IP"'", 45001))
b.connect(dst)          # 只绑定对端，不发包
b.settimeout(2)
print()
print("B) 已 connect 的 socket")
b.send(b"B"*16)
time.sleep(1)
try:
    d,addr = b.recvfrom(2048)
    print("   recvfrom 收到:", d[:20])
except OSError as e:
    name = errno.errorcode.get(e.errno, "?")
    print(f"   recvfrom 失败: [{e.errno}] {name} {e.strerror}")
    if e.errno == errno.ECONNREFUSED:
        print("   -> ECONNREFUSED！内核把 ICMP 端口不可达翻译成了这个错误，")
        print("      因为它知道这个 socket 只跟那一个对端说话，能唯一对应。")
PY'
pause

# ------------------------------------------------ 2.4 路由器自己的端口 ----
h2 "2.4 差错可以由路径上任意一台主机产生"
info "这次发到【路由器】上一个空置端口，看是否也回端口不可达："
cap_start "$C_CLIENT" eth0 "icmp" "20-router-unreach"
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$ROUTER_IP_NEAR" --dport "$PORT_CLOSED" --size 24 --df 0
sleep 2
cap_stop "$C_CLIENT" "20-router-unreach"
cat "$CAP_DIR/20-router-unreach.txt" 2>/dev/null | sed 's/^/  /' || true
note "任何收到 UDP 报文的主机，只要端口没进程监听，都会回这个 ICMP。"
note "所以“收到端口不可达”只说明那台主机活着且端口空着。"

# ------------------------------------------- 2.5 ICMP 差错产生规则 ------
h2 "2.5 ICMP 差错报文的重要规则（顺带记住）"
log "  · 不为 ICMP 差错报文本身再产生差错（避免无限循环）"
log "  · 不为分片的非第一片产生差错（没有端口信息）"
log "  · 不为目的地址是广播/多播的报文产生差错"
log "  · 不为源地址不是单播的报文产生差错"
log ""
note "所以【在广播/多播上做 UDP 探测收不到任何错误反馈】——这也解释了"
note "为什么 DHCP、mDNS 这类协议必须靠超时而不是靠差错报文。"

h1 "小结"
log "  1) UDP 自己不产生任何差错报文；差错来自 IP/ICMP 层"
log "  2) ICMP 差错携带原报文前 8 字节，刚好够定位 UDP 端口"
log "  3) 关联是否成功取决于 socket 状态（connect 与否）和系统选项"
log "  4) 差错关联天生不可靠（一次 VS 多次请求无法区分）"
log ""
log "日志: logs/20-port-unreachable.log"
log "抓包: capture/20-port-unreach-client.pcap"
