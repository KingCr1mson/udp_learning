#!/usr/bin/env bash
# ============================================================================
#  50-stats.sh —— 端口、缓冲区与 UDP 统计计数器
#
#  前面几节讲的是"协议长什么样"，本节讲"UDP 在真实系统里怎么坏"。
#  这是把课本知识变成排查能力的一节：
#    SS_ESTABLISHED / InCsumErrors / RcvbufErrors / NoPorts
#  这几个计数器的名字，就是你在生产环境定位 UDP 问题时要敲的命令。
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_topology
log_init "$LOG_DIR/50-stats.log"

h1 "5. 端口、缓冲区与统计计数器"

# --------------------------------------------------- 5.1 临时端口范围 ----
h2 "5.1 端口范围与临时端口分配"
for c in "$C_CLIENT" "$C_SERVER"; do
  printf '\n  [%s]\n' "$c"
  docker exec "$c" cat /proc/sys/net/ipv4/ip_local_port_range | \
    awk '{printf "    临时端口范围: %s - %s\n", $1, $2}'
done
log ""
log "  端口划分："
log "    0     - 1023  知名端口（需 root，IANA 分配）"
log "    1024  - 49151 已注册端口"
log "    49152 - 65535 临时端口（客户端发起连接时随机分配）"
log ""
info "观察一次 UDP 发送用了哪个临时端口（反复执行，看它是随机的）："
for i in 1 2 3; do
  docker exec "$C_CLIENT" python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"x", ("172.31.11.1", 9998))
print("    本次使用的源端口:", s.getsockname()[1])
s.close()
PY
done
note "端口是分用的依据：同一台主机上多个进程靠端口区分。"
note "完整标识一条 UDP“连接”需要四元组：(源IP,源端口,目的IP,目的端口)。"
pause

# --------------------------------------------------- 5.2 看 socket 状态 --
h2 "5.2 用 ss 观察 UDP socket"
info "先起一个 UDP 监听（用自带的回显服务，日志可读）："
udp_listen "$C_SERVER" "$PORT_ECHO" 40
cex "$C_SERVER" ss -uanp
log ""
note "注意：udpecho 由 docker exec -d 启动，父进程退出后它变成孤儿进程，"
note "但 socket 依然存在 —— 这也是 UDP 的特点：没有连接状态要维护。"
log ""
info "对比 TCP：TCP 监听是 LISTEN，已建立连接是 ESTABLISHED，有状态机；"
info "UDP socket 只有 UNCONN（未连接）或 ESTAB（connect 过的）两种。"
info "在 client 上做一个 connect 过的 UDP socket 看看："
cex "$C_CLIENT" python3 -c "
import socket, subprocess, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(('$SERVER_IP', $PORT_ECHO))
s.send(b'hello')
print('    client 侧 ss 输出：')
print(subprocess.run(['ss','-uanp'], capture_output=True, text=True).stdout)
time.sleep(1)
s.close()
"
pause

# ------------------------------------------------- 5.3 统计计数器基线 ----
h2 "5.3 先记录统计计数器基线"
udpstats() {
  local c="$1"
  # 注意：这里必须用 python3 -c 而不是 heredoc。如果写成
  #   docker exec "$c" python3 - <<'PY' ... PY
  # 当它被 $(...) 捕获时会因为 stdin 被占用而读不到脚本，静默输出空。
  docker exec "$c" python3 -c "
row = {}
lines = open('/proc/net/snmp').read().splitlines()
for i, l in enumerate(lines):
    if l.startswith('Udp:') and lines[i+1].startswith('Udp:'):
        row = dict(zip(l.split()[1:], lines[i+1].split()[1:]))
        break
for k in ['InDatagrams','NoPorts','InErrors','OutDatagrams','RcvbufErrors','SndbufErrors','InCsumErrors']:
    if k in row:
        print('    %-16s = %s' % (k, row[k]))
"
}

log "  [server] /proc/net/snmp 的 Udp 段："
udpstats "$C_SERVER"
log ""
log "  [client] /proc/net/snmp 的 Udp 段："
udpstats "$C_CLIENT"
log ""
info "netstat -su 的等价输出（server）："
cex "$C_SERVER" netstat -su | sed -n '/^Udp:/,/^$/p'
note "这些计数器就是排查 UDP 问题的入口："
note "  InDatagrams 收到的报文数      NoPorts 因端口无人监听而丢弃"
note "  InErrors 各种接收错误         RcvbufErrors 接收缓冲区满导致的丢弃"
note "  InCsumErrors 校验和错误       OutDatagrams 发出的报文数"
pause

# ------------------------------------------------ 5.4 端口不可达计数 ----
h2 "5.4 计数器实验一：端口不可达"
info "发 20 个报文到一个没人监听的端口，看 NoPorts 是否增加："
cex "$C_CLIENT" python3 /lab/tools/udplab.py flood \
  --dst "$SERVER_IP" --dport "$PORT_CLOSED" --count 20 --size 64
sleep 2
log ""
log "  [server] 变化后："
udpstats "$C_SERVER"
note "server 的 NoPorts 应该增加 —— 每个到达空置端口的报文都计入这个计数器。"
note "注意：server 收到报文并尝试投递，发现没有 socket 才丢弃；"
note "它回不回 ICMP 还取决于 ICMP 限速和是否有其他规则。"
pause

# --------------------------------------------- 5.5 接收缓冲区溢出 -------
h2 "5.5 计数器实验二：接收缓冲区溢出（UDP 最真实的丢包原因）"
info "起一个只设了很小 SO_RCVBUF 的接收端（内核还会翻倍并有下限，注意观察）："
udp_listen "$C_SERVER" "$PORT_ECHO" 30 "--rcvbuf 8192"
udp_listen_log "$C_SERVER" "$PORT_ECHO" 3
log ""
info "记录基线："
udpstats "$C_SERVER"
log ""
info "client 以最快速度连发 20000 个 1024 字节报文："
cex "$C_CLIENT" python3 /lab/tools/udplab.py flood \
  --dst "$SERVER_IP" --dport "$PORT_ECHO" --count 20000 --size 1024
sleep 3
log ""
log "  [server] 灌包之后："
udpstats "$C_SERVER"
log ""
printf '  server 端应用实际收到（对比 20000）: '
docker exec "$C_SERVER" bash -c "grep -c 收到 /tmp/echo-$PORT_ECHO.log 2>/dev/null || echo 0"
printf '  其中被内核记到 RcvbufErrors 的丢包数见上面的计数器\n' 
log ""
note "这是 UDP 在生产环境里最常见的丢包原因："
note "  应用来不及收 + 接收缓冲区太小 => 内核直接丢弃，"
note "  这些丢包连 ICMP 都没有，发送方【完全不知道】。"
note "  排查思路：netstat -su 的 RcvbufErrors 增长 + ss -uanm 看 Recv-Q。"
log ""
info "查看 socket 队列（Recv-Q 表示已到达但应用还没取走的字节数）："
cex "$C_SERVER" ss -uanm
pause

# ------------------------------------------------- 5.6 校验和错误 -------
h2 "5.6 计数器实验三：校验和错误"
info "发送一个校验和故意写错的报文，观察 InCsumErrors："
udp_listen "$C_SERVER" "$PORT_ECHO" 15
cex "$C_CLIENT" python3 /lab/tools/udplab.py sendraw \
  --src "$CLIENT_IP" --dst "$SERVER_IP" --sport 40010 --dport "$PORT_ECHO" \
  --size 32 --bad-checksum
sleep 2
udpstats "$C_SERVER"
note "InCsumErrors 增加 = 收到了报文但校验失败被丢弃。"
note "如果这个数很大，通常是网卡卸载、中间设备改包、或对端实现有 bug。"

# ---------------------------------------------- 5.7 发送缓冲区与丢包 ----
h2 "5.7 参考：内核可调参数"
log "  ┌────────────────────────────────────────┬──────────────────────────────┐"
log "  │ 参数                                   │ 含义                         │"
log "  ├────────────────────────────────────────┼──────────────────────────────┤"
log "  │ net.core.rmem_default / rmem_max       │ 接收缓冲区默认/最大值        │"
log "  │ net.core.wmem_default / wmem_max       │ 发送缓冲区默认/最大值        │"
log "  │ net.ipv4.udp_mem                       │ UDP 全局内存压力阈值         │"
log "  │ net.ipv4.udp_rmem_min / udp_wmem_min   │ 每个 socket 的最小保留内存   │"
log "  │ net.ipv4.ip_local_port_range           │ 临时端口范围                 │"
log "  │ net.ipv4.icmp_ratelimit / ratemask     │ ICMP 差错报文限速（本实验已关）│"
log "  └────────────────────────────────────────┴──────────────────────────────┘"
log ""
info "查看 udp_mem（三个数字：低水位 / 压力水位 / 硬上限，单位是页）："
cex "$C_SERVER" sysctl net.ipv4.udp_mem 2>/dev/null || true
cex "$C_SERVER" sysctl net.core.rmem_max net.core.rmem_default 2>/dev/null || true

h1 "小结：从协议到排查"
log "  · 端口是分用依据；四元组标识一条 UDP 会话"
log "  · UDP socket 无状态：UNCONN / ESTAB 两种，没有 TCP 那套状态机"
log "  · 三种典型静默丢包及其计数器："
log "      端口无人监听  ->  Udp NoPorts      （可能伴随 ICMP 端口不可达）"
log "      缓冲区满      ->  Udp RcvbufErrors （完全没有反馈）"
log "      校验和错误    ->  Udp InCsumErrors"
log "  · 排查三件套：netstat -su / ss -uanm / ip -s link"
log ""
log "日志: logs/50-stats.log"
