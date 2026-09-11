#!/usr/bin/env bash
# ============================================================================
#  40-pmtud.sh —— 路径 MTU 发现（PMTUD）与 PMTUD 黑洞
#
#  上一节最后留的问题：DF=1 时路由器只能丢包并回 ICMP。
#  本节把这条链路走完整：
#
#    发 DF=1 的包  →  撞到窄链路  →  路由器丢包并回 ICMP(含 Next-Hop MTU)
#         ↑                                              |
#         └────────── 发送方缩小包重发 ←─────────────────┘
#
#  然后把 ICMP 封掉，演示最经典的实战故障：PMTUD 黑洞
#  （小包通、大包死、没有明确报错）
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_topology
log_init "$LOG_DIR/40-pmtud.log"

h1 "4. 路径 MTU 发现（PMTUD）"

# ------------------------------------------------------ 4.1 观察初始值 ----
h2 "4.1 出发前：主机只知道自己的网卡 MTU"
info "client 的出口 MTU 与 PMTU 情况："
cex "$C_CLIENT" ip -br link show eth0
cex "$C_CLIENT" ip route get "$SERVER_IP"
cex "$C_CLIENT" bash -c 'sysctl net.ipv4.ip_no_pmtu_disc 2>/dev/null; \
  echo "ip_no_pmtu_disc=0 表示允许 PMTUD（默认）"'
cex "$C_CLIENT" bash -c 'cat /proc/sys/net/ipv4/route/mtu_expires 2>/dev/null | \
  sed "s/^/PMTU缓存有效期(秒): /"'
note "此时 client 只知道 eth0 是 $MTU_NEAR，它【不知道】路径中间有 1400 的窄链路。"
pause

# ------------------------------------------------ 4.2 触发一次 PMTUD -----
h2 "4.2 触发 PMTUD：撞墙 -> 收 ICMP -> 缩小重发"
info "步骤 1：先发一个【刚好能不超 $MTU_NEAR】的报文（payload 1472），DF=1"
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_CLOSED" --size 1472 --df 1
sleep 1

log ""
info "步骤 2：一边监听 ICMP，一边发一个超过 $MTU_FAR 的报文（payload 1400），DF=1"
cap_clear "$C_CLIENT"
cap_start "$C_CLIENT" eth0 "icmp" "40-pmtud-icmp"
( cex "$C_CLIENT" python3 /lab/tools/udplab.py icmpwatch --timeout 6 \
    > /tmp/pmtud-icmpwatch.txt 2>&1 & ) 2>/dev/null
sleep 1
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_CLOSED" --size 1400 --df 1
sleep 6
cap_stop "$C_CLIENT" "40-pmtud-icmp"

log ""
info "client 上解码到的 ICMP（注意 Next-Hop MTU 字段）："
cat /tmp/pmtud-icmpwatch.txt 2>/dev/null | sed 's/^/  /'
log ""
info "抓包文本："
grep -E 'ICMP|IP ' "$CAP_DIR/40-pmtud-icmp.txt" 2>/dev/null | sed 's/^/  /' | head -20

log ""
info "步骤 3：看 client 的 PMTU 缓存是否被更新（mtu 字段）"
cex "$C_CLIENT" ip route get "$SERVER_IP"
note "如果 route get 的输出里出现 mtu $MTU_FAR（或更小），说明 PMTUD 生效："
note "client 已把这条路径的 MTU 降到窄链路的大小，后续包会自动变小。"

log ""
info "步骤 4：再用同样大小重发，这次应该成功（路由器不再丢弃）"
udp_listen "$C_SERVER" "$PORT_ECHO" 15
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_ECHO" --size 1400 --df 0
sleep 2
info "server 应用层收到："
udp_listen_log "$C_SERVER" "$PORT_ECHO" 6
pause

# ------------------------------------------------ 4.3 用 ping 找临界值 ---
h2 "4.3 用 ping 二分找临界值（最实用的排查手法）"
info "ping -M do 就是设置 DF=1，逐步加大直到失败："
cex "$C_CLIENT" bash -c '
for s in 1300 1372 1373 1400 1472; do
  if ping -c 1 -W 2 -M do -s $s '"$SERVER_IP"' >/dev/null 2>&1; then
    printf "  -s %-5s (IP总长 %-5s)  通过 ✅\n" "$s" "$((s+28))"
  else
    printf "  -s %-5s (IP总长 %-5s)  失败 ❌  <- 超过路径 MTU\n" "$s" "$((s+28))"
  fi
done'
note "临界点在 1372/1373 之间：1372+28 = 1400 = 窄链路 MTU。"
note "ping 的 -s 是 ICMP 载荷，加 8 字节 ICMP 首部再加 20 字节 IP 首部，"
note "所以与 UDP 的换算一致：载荷上限 = MTU - 28。"

log ""
info "看内核是怎么报错的（错误原因写在 ICMP 里）："
cex "$C_CLIENT" ping -c 1 -W 2 -M do -s 1472 "$SERVER_IP" || true
note "如果输出 'Frag needed and DF set (mtu = 1400)' —— PMTUD 工作正常。"
note "如果输出的是【超时无响应】而不是上面那句 —— 那就要怀疑黑洞了（下一节）。"
pause

# ------------------------------------------------ 4.4 制造 PMTUD 黑洞 ---
h2 "4.4 制造 PMTUD 黑洞：把 ICMP 封掉会怎样"
note "关键知识点：PMTU 缓存是按【目的地址】独立保存的。"
note "  对一个用过的目的地址，缓存里已记着 $MTU_FAR，内核会在本地就把大包"
note "  拦下（EMSGSIZE），根本发不出去 —— 反而看不出黑洞。"
note "  所以下面改用一个【从未访问过】的目的地址，让它重新走一遍 PMTUD。"

DST_FRESH="172.31.11.77"
log ""
info "对照组：ICMP 未被封时，用全新地址发超界包会怎样"
log "  预期：sendto() 成功（内核以为是 $MTU_NEAR），接着收到 ICMP 通知，"
log "        然后 PMTU 缓存被改写成 $MTU_FAR —— 这正是 PMTUD 的工作方式。"
cap_start "$C_CLIENT" eth0 "icmp" "40-blackhole-before"
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$DST_FRESH" --dport "$PORT_ECHO" --size 1416 --df 1
sleep 3
cap_stop "$C_CLIENT" "40-blackhole-before"
log "  client 收到的 ICMP 通知："
grep -E 'ICMP' "$CAP_DIR/40-blackhole-before.txt" 2>/dev/null | sed 's/^/    /' \
  || log "    （没抓到 ICMP）"
log ""
info "探测之后 $DST_FRESH 的 PMTU 缓存："
cex "$C_CLIENT" ip route get "$DST_FRESH"

log ""
info "现在把 ICMP「需要分片」差错封掉（先清旧规则，保证可重复执行）："
cs "$C_ROUTER" 'while iptables -D FORWARD -p icmp --icmp-type 3/4 -j DROP 2>/dev/null; do :; done
while iptables -D OUTPUT -p icmp --icmp-type 3/4 -j DROP 2>/dev/null; do :; done
iptables -I FORWARD -p icmp --icmp-type 3/4 -j DROP
iptables -I OUTPUT  -p icmp --icmp-type 3/4 -j DROP
echo "已封堵 ICMP type3/code4，当前 OUTPUT 规则："
iptables -L OUTPUT -n --line-numbers | head -5'

DST_FRESH2="172.31.11.88"
log ""
info "换另一个同样没用过的地址 $DST_FRESH2，重放刚才那一幕："
log "  预期：sendto() 报【成功】（内核以为是 $MTU_NEAR），"
log "        但包在路由器上被丢弃，那条“请缩小到 $MTU_FAR”的通知再也回不来。"
cap_start "$C_CLIENT" eth0 "icmp" "40-blackhole-after"
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$DST_FRESH2" --dport "$PORT_ECHO" --size 1416 --df 1
sleep 3
cap_stop "$C_CLIENT" "40-blackhole-after"
log "  client 侧抓到的 ICMP："
if grep -q 'ICMP' "$CAP_DIR/40-blackhole-after.txt" 2>/dev/null; then
  grep -E 'ICMP' "$CAP_DIR/40-blackhole-after.txt" | sed 's/^/    /'
else
  log "    （零条 —— 通知被防火墙吞掉了，这就是黑洞）"
fi
log ""
info "再看 client 现在以为的路径 MTU（它还以为能发 $MTU_NEAR，其实最大只有 $MTU_FAR）："
cex "$C_CLIENT" ip route get "$DST_FRESH2"

log ""
info "同时验证小包仍然通（证明链路本身是好的，只有大包死）："
udp_listen "$C_SERVER" "$PORT_ECHO" 15
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_ECHO" --size 100 --df 0
sleep 1
info "小包结果："
udp_listen_log "$C_SERVER" "$PORT_ECHO" 4
log ""
note "这就是 PMTUD 黑洞的完整样子（注意它的隐蔽性）："
note "  1) 小包（不超过 $((MTU_FAR-28)) 字节载荷）完全正常"
note "  2) 大包 sendto() 返回成功，应用以为发出去了"
note "  3) 实际被路由器丢弃，而那条缩小 MTU 的通知永远收不到"
note "  4) 应用只能看到：超时、卡住、没有任何明确报错"
note "  现实成因：防火墙/安全组把全部 ICMP 封了（企业网、云环境极常见）"
log ""
info "清理时用循环删除，避免规则重复累积："
cs "$C_ROUTER" 'while iptables -D FORWARD -p icmp --icmp-type 3/4 -j DROP 2>/dev/null; do :; done
while iptables -D OUTPUT -p icmp --icmp-type 3/4 -j DROP 2>/dev/null; do :; done
echo "残留规则数: $(iptables -S | grep -c "icmp-type 3/4" || true)"'
ok "已恢复（黑洞规则全部清除）"
pause

# ------------------------------------- 4.5 TCP 有兜底，UDP 没有 --------
h2 "4.5 对比：TCP 有兜底机制，UDP 没有"
info "TCP 在握手时协商 MSS，并且在黑洞场景下有内核探测："
cex "$C_CLIENT" bash -c 'echo -n "tcp_mtu_probing = "; \
  cat /proc/sys/net/ipv4/tcp_mtu_probing; \
  echo "(0=关闭, 1=仅在已启用PMTUD时探测, 2=总是探测)"'
log ""
info "MSS 是怎么算出来的（MTU - 20 IP - 20 TCP = 1460）："
log "  出口 MTU $MTU_NEAR  =>  MSS = $((MTU_NEAR - 40))"
log "  窄链路 MTU $MTU_FAR =>  MSS = $((MTU_FAR - 40))"

log ""
info "演示 MSS Clamping：在 router 上自动把 MSS 压到路径 MTU 允许的值"
cex "$C_ROUTER" iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu
cex "$C_ROUTER" iptables -t mangle -L FORWARD -n --line-numbers | head -5

info "在 server 上开一个 TCP 监听，client 连上去，看协商出来的 MSS："
cex "$C_SERVER" bash -c "pkill -f '[n]c -l -p' 2>/dev/null; \
  nohup timeout 10 nc -l -p 8080 > /dev/null 2>&1 & sleep 0.5; echo ok"
sleep 1
cex "$C_CLIENT" bash -c "timeout 5 nc -v $SERVER_IP 8080 < /dev/null > /dev/null 2>&1; \
  sleep 0.5; ss -tin state established '( dport = :8080 )' | head -6" || true

log ""
info "恢复："
cex "$C_ROUTER" iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu
cex "$C_SERVER" bash -c "pkill -f '[n]c -l -p' 2>/dev/null; echo ok"
note "MSS Clamping 是 VPN/PPPoE 场景最常用的治本办法：让 TCP 一开始就不谈过大的段。"
note "UDP 没有握手、没有 MSS 协商、没有重传，所以对 PMTUD 黑洞【完全没有兜底】——"
note "应用只能自己保守取值（DNS 传统上限 512 字节就是这个原因）。"
pause

# ------------------------------------------------ 4.6 工程实践清单 ------
h2 "4.6 工程上怎么处理（从治本到治标）"
log "  1. 放行必要的 ICMP 差错报文（IPv4 类型3代码4 / IPv6 Type 2）——唯一正确做法"
log "  2. 隧道/VPN 边界做 MSS Clamping，让 TCP 主动协商小段"
log "  3. 在隧道接口上显式设置 MTU，例如: ip link set dev tun0 mtu 1400"
log "  4. 开启内核兜底: sysctl -w net.ipv4.tcp_mtu_probing=1"
log "  5. 应用层保守取值：UDP 载荷 <= 1200~1400；不可控网络按 512 设计"
log ""
info "常见 MTU 对应的 UDP 安全载荷（IPv4）："
log "  ┌──────────────┬────────┬──────────────────┐"
log "  │ 链路 MTU     │ IP头   │ 安全 UDP 载荷    │"
log "  ├──────────────┼────────┼──────────────────┤"
log "  │ 1500 以太网  │ 20     │ 1472             │"
log "  │ 1492 PPPoE   │ 20     │ 1464             │"
log "  │ 1400 隧道    │ 20     │ 1372             │"
log "  │ 1280 IPv6最小│ 40     │ 1232             │"
log "  └──────────────┴────────┴──────────────────┘"

h1 "小结：PMTUD"
log "  · 原理：发 DF=1 的包试探 -> 撞墙收 ICMP(带 Next-Hop MTU) -> 缩小重发"
log "  · 目的：把分片从中间路由器转移到端系统的“提前测量”，端到端避免分片"
log "  · 依赖：ICMP 差错报文必须能回来；被封 => 黑洞（小包通、大包死、无报错）"
log "  · IPv6 中 PMTUD 是强制的（中间路由器一律不分片，没有退路）"
log "  · TCP 有 MSS 协商 + MTU 探测兜底；UDP 什么都没有"
log ""
log "日志: logs/40-pmtud.log"
log "抓包: capture/40-pmtud-icmp.pcap"
