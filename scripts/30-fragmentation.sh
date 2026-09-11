#!/usr/bin/env bash
# ============================================================================
#  30-fragmentation.sh —— IP 分片（本章最容易被误解的一节）
#
#  必须建立的核心认知：
#    ① 分片是【IP 层】干的，不是 UDP 干的
#    ② 中间路由器分片，只有【最终目的主机】重组
#    ③ 任一分片丢失 => 整个数据报丢弃（UDP 无法"部分交付"）
#    ④ 分片靠 IP 首部的三个字段：标识 / 标志(MF,DF) / 片偏移
#    ⑤ 片偏移以 8 字节为单位 => 除最后一片外每片数据长度必须是 8 的倍数
#
#  本实验的窄链路：router 的 eth1，MTU = 1400
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_topology
log_init "$LOG_DIR/30-fragmentation.log"

h1 "3. IP 分片"

# --------------------------------------------------------- 3.1 背景数字 ---
h2 "3.1 先把数字算清楚"
log "  client eth0 MTU            = $MTU_NEAR"
log "  router eth1 MTU（瓶颈）    = $MTU_FAR"
log ""
log "  从 $MTU_NEAR 出发一个包，到 router eth1 时会按 $MTU_FAR 重新切分。"
log ""
info "关键换算（IPv4，无选项）："
log "  一个 IP 包最多承载的数据 = MTU - 20(IP首部)"
log "  其中 UDP 报文          = MTU - 20"
log "  其中 UDP 载荷          = MTU - 20 - 8 = MTU - 28"
log ""
log "  在 MTU=$MTU_FAR 的窄链路上："
log "    单个 IP 包最大        = $MTU_FAR"
log "    UDP 报文最大          = $((MTU_FAR - 20))"
log "    UDP 载荷最大          = $((MTU_FAR - 28))   <- 超过它就会分片"
note "记住 $((MTU_FAR - 28)) 这个数：它是这条路径上“不分片的最大 UDP 载荷”。"

info "在 client 上验证这个边界（ping 用 ICMP，但 MTU 计算方式完全相同）："
cex "$C_CLIENT" bash -c "echo '--- 载荷 $((MTU_FAR-28)) 字节（= $MTU_FAR 的 IP 包），DF=1 ---'; \
  ping -c 1 -W 2 -M do -s $((MTU_FAR-28)) $SERVER_IP; \
  echo; echo '--- 载荷 $((MTU_FAR-27)) 字节（比瓶颈大 1 字节），DF=1 ---'; \
  ping -c 1 -W 2 -M do -s $((MTU_FAR-27)) $SERVER_IP" || true
note "第二条第 1 个字节就超了，路由器直接回 ICMP 并告诉你它的 MTU。"
pause

# ------------------------------------------- 3.2 分批观察：从小到大 ------
h2 "3.2 逐个尺寸观察分片结果（DF=0，允许分片）"
cex "$C_SERVER" bash -c "pkill -f '[n]c -u -l' 2>/dev/null; sleep 0.3; echo cleaned"

for size in 100 $((MTU_FAR - 28)) $((MTU_FAR - 20)) 1472 2000 4000; do
  sep
  log ""
  info "载荷 ${size} 字节：预期 IP 总长 = $((size + 28)) 字节"
  if [ "$size" -le $((MTU_FAR - 28)) ]; then
    log "     => 小于 $((MTU_FAR-28))，可以整包通过，不分片"
  else
    need=$(( size + 28 ))
    n=$(( (need + MTU_FAR - 1) / MTU_FAR ))
    log "     => 大于 $((MTU_FAR-28))，在 router eth1 上会被切成约 ${n} 片"
  fi

  cap_clear "$C_SERVER"
  cap_start "$C_SERVER" eth0 "udp or (ip[6:2] & 0x1fff != 0)" "30-frag-$size"
  # 在 server 上开监听，确认重组后的完整报文能到达应用层
  udp_listen "$C_SERVER" "$PORT_ECHO" 12
  cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
    --dst "$SERVER_IP" --dport "$PORT_ECHO" --size "$size" --df 0
  sleep 2
  cap_stop "$C_SERVER" "30-frag-$size"
  log ""
  info "server 抓到的包（注意 IP 行的 flags 和 offset 字段）："
  grep -E 'ethertype IPv4' "$CAP_DIR/30-frag-$size.txt" 2>/dev/null \
    | sed 's/^/  /' | head -20 || warn "无输出"
  log ""
  info "server 应用层收到几条报文（分片已在终点 IP 层重组，应用只看到 1 条）："
  docker exec "$C_SERVER" bash -c "grep -c '收到' /tmp/echo-$PORT_ECHO.log 2>/dev/null || echo 0' | sed 's/^/    收到报文数: /"
done
pause

# ------------------------------------ 3.3 DF=1 时不同：被丢弃 + ICMP ------
h2 "3.3 DF=1（禁止分片）时的行为对比"
info "同样发 2000 字节载荷，但这次把 DF 置 1："
( cex "$C_CLIENT" python3 /lab/tools/udplab.py icmpwatch --timeout 5 & ) 2>/dev/null
sleep 1
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_ECHO" --size 2000 --df 1
sleep 6
note "DF=1 时路由器【不能】分片，只能丢弃并回 ICMP 差错（下一节 PMTUD 的主角）。"
note "这正是“路径 MTU 发现”的原理：用 DF 位逼出真实路径 MTU。"
pause

# --------------------------------------------- 3.4 分片的代价与观测 ------
h2 "3.4 分片的代价：字节数放大 + 丢包率放大"
info "先看接口计数器（分片会让“帧数”明显多于“报文数”）："
for c in "$C_CLIENT" "$C_SERVER"; do
  printf '\n  [%s]\n' "$c"
  docker exec "$c" ip -s -s link show eth0 | sed -n '1,20p' | sed 's/^/    /'
done
log ""
info "定量对比：分别用 100 字节和 4000 字节载荷各发 200 个 UDP 报文"
for size in 100 4000; do
  cap_clear "$C_SERVER"
  cap_start "$C_SERVER" eth0 "ip" "30-cost-$size"
  cex "$C_CLIENT" python3 /lab/tools/udplab.py flood \
    --dst "$SERVER_IP" --dport "$PORT_CLOSED" --count 200 --size "$size"
  sleep 2
  cap_stop "$C_SERVER" "30-cost-$size"
  npkt=$(grep -c 'ethertype IPv4' "$CAP_DIR/30-cost-$size.txt" 2>/dev/null || echo 0)
  log "  载荷 $size 字节 × 200 个报文  =>  server 链路上看到 ${npkt} 个 IP 包"
done
log ""
note "载荷越大，一个 UDP 报文被切成的片越多，链路上的包数越多："
note "  · 每片都要带一个 20 字节 IP 首部 => 带宽浪费"
note "  · 每片都是一次独立的丢包机会 => 整包成功率下降"
note "  例：6 片、每片丢包率 1% => 整包成功率 ≈ 0.99^6 ≈ 94%"
log ""
note "还有一个致命点：只有【第一片】带 UDP 首部（端口号），"
note "后续分片没有端口信息 => 防火墙/NAT 很难正确处理，"
note "所以工程上应尽量避免分片：应用层主动控制报文大小。"
pause

# ------------------------------------------------ 3.5 重组只在终点 ------
h2 "3.5 重组只发生在最终目的主机的 IP 层"
info "在【路由器】上抓包，可以看到进来时是大包、出去时已被切开："
cap_clear "$C_ROUTER"
cap_start "$C_ROUTER" eth0 "ip" "30-router-in"
cap_start "$C_ROUTER" eth1 "ip" "30-router-out"
cex "$C_CLIENT" python3 /lab/tools/udplab.py send \
  --dst "$SERVER_IP" --dport "$PORT_ECHO" --size 3000 --df 0
sleep 2
cap_stop "$C_ROUTER" "30-router-in"
cap_stop "$C_ROUTER" "30-router-out"
log ""
info "router 入口 eth0（MTU $MTU_NEAR）看到的："
grep -E 'ethertype IPv4' "$CAP_DIR/30-router-in.txt" 2>/dev/null | sed 's/^/  /' | head -6
log ""
info "router 出口 eth1（MTU $MTU_FAR）看到的："
grep -E 'ethertype IPv4' "$CAP_DIR/30-router-out.txt" 2>/dev/null | sed 's/^/  /' | head -6
note "入口 1 个包，出口变成多片 —— 但路由器【不重组】，只转发。"
note "如果路由器重组，就得为全网的半成品包保存状态，代价无法承受。"

h1 "小结：分片"
log "  · 分片由 IP 层完成（发送主机或中间路由器），UDP 完全无感"
log "  · 重组只在最终目的主机的 IP 层发生，且有超时（典型 30~60 秒）"
log "  · 分片字段：标识(同一数据报共享) / MF / DF / 片偏移(单位 8 字节)"
log "  · 任一片丢失 => 整个数据报被丢弃 => UDP 静默丢包"
log "  · 只有第一片带端口号 => NAT/防火墙不友好"
log "  · 工程结论：应用层主动控制报文大小，不要依赖 IP 分片"
log ""
log "日志: logs/30-fragmentation.log"
