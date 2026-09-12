#!/usr/bin/env bash
# ============================================================================
#  00-setup.sh —— 搭建 UDP 实验拓扑
#
#  拓扑（比"两台 Ubuntu"多一台路由器，这样才能演示分片与路径 MTU 发现）：
#
#        client                         router                        server
#     172.31.10.10                  172.31.11.1                   172.31.11.1
#          |                         172.31.12.1                        |
#          |  eth0                      eth0   eth1                     |  eth0
#          +------[ net-near ]----------+          +-----[ net-far ]-----+
#                 MTU 1500                            MTU 1400  ← 唯一的窄链路
#
#  为什么要三台：
#    * 两台直连做不出"路径 MTU 变小"，因为主机只知道自己网卡的 MTU；
#    * 第三台当路由器，才能制造「一端 1500、另一端 1400」的真实场景，
#      从而亲眼看到 IP 分片、ICMP "Frag needed"、以及 PMTU 缓存缩水。
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
log_init "$LOG_DIR/00-setup.log"

h1 "UDP 实验环境搭建"

# ---------------------------------------------------------------- 0. 前置 ---
h2 "0. 前置检查"
command -v docker >/dev/null || { err "docker 未安装"; exit 1; }
docker info >/dev/null 2>&1 || { err "docker 守护进程不可用"; exit 1; }
ok "docker 可用: $(docker version --format '{{.Server.Version}}')"
log ""
log "拓扑常量："
log "  client = $C_CLIENT  ($CLIENT_IP)"
log "  router = $C_ROUTER  ($ROUTER_IP_NEAR / $ROUTER_IP_FAR)"
log "  server = $C_SERVER  ($SERVER_IP)"
log "  近端链路 = $NET_NEAR  MTU $MTU_NEAR"
log "  远端链路 = $NET_FAR   MTU $MTU_FAR   <-- 瓶颈"
note "记住这个数字：$MTU_FAR。本章所有“包太大”的实验都由它触发。"

# ------------------------------------------------------------ 1. 构建镜像 ---
h2 "1. 构建实验镜像 $IMG"
log "docker 配置目录：~/.docker（docker 默认，未做任何覆盖）"
if [ "${REBUILD:-0}" = "1" ] || ! docker image inspect "$IMG" >/dev/null 2>&1; then
  # 先切到项目根目录再用相对路径构建，日志里就不会写死宿主机的绝对路径
  if ! ( cd "$LAB_DIR" && run docker build -t "$IMG" -f image/Dockerfile image ); then
    err "镜像构建失败，后续步骤无法继续"
    err "常见原因：apt 源不可达（需要外网），或 ~/.docker 不可写"
    exit 1
  fi
  ok "镜像构建完成"
else
  ok "镜像已存在（需要重建请用 REBUILD=1 $0）"
fi
# 关键：build 的退出码不等于镜像存在，必须显式校验
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  err "镜像 $IMG 并不存在 —— 构建没有真正成功，停止"
  exit 1
fi
log ""
log "镜像内工具版本："
docker run --rm "$IMG" bash -c 'ip -V; ping -V; tcpdump --version 2>&1|head -1; ss -V; python3 -V'

# -------------------------------------------------------- 2. 清理旧环境 ---
h2 "2. 清理同名旧资源（保证可重复执行）"
for c in "$C_CLIENT" "$C_ROUTER" "$C_SERVER"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    run docker rm -f "$c" >/dev/null
    log "  已删除旧容器 $c"
  fi
done
for n in "$NET_NEAR" "$NET_FAR"; do
  if docker network inspect "$n" >/dev/null 2>&1; then
    run docker network rm "$n" >/dev/null 2>&1 || true
    log "  已删除旧网络 $n"
  fi
done
ok "清理完成"

# ------------------------------------------------------------ 3. 建网络 ---
h2 "3. 创建两条链路（MTU 不同）"
# 注意：docker network create 的 MTU 通过 driver-opt 传递
if ! run docker network create -d bridge \
  -o "com.docker.network.driver.mtu=$MTU_NEAR" \
  --subnet 172.31.10.0/24 --gateway 172.31.10.254 \
  "$NET_NEAR"; then
  err "创建网络 $NET_NEAR 失败"; exit 1
fi
# 远端链路的地址分配要避开 docker 网桥自己占用的地址：
#   docker 会在网桥上占用该子网的 .1/.2 等地址，
#   所以 router 用 .100（实测 .1 会报 "Address already in use"）
if ! run docker network create -d bridge \
  -o "com.docker.network.driver.mtu=$MTU_FAR" \
  --subnet 172.31.11.0/24 --gateway 172.31.11.6 \
  "$NET_FAR"; then
  err "创建网络 $NET_FAR 失败"; exit 1
fi
log ""
log "实际生效的 MTU（用 docker network inspect 反查）："
for n in "$NET_NEAR" "$NET_FAR"; do
  printf '  %-22s MTU=%s\n' "$n" \
    "$(docker network inspect -f '{{index .Options "com.docker.network.driver.mtu"}}' "$n")"
done

# ------------------------------------------------------------ 4. 起容器 ---
h2 "4. 启动容器"
# client：只接近端链路
run docker run -d --name "$C_CLIENT" --hostname client \
  --network "$NET_NEAR" --ip "$CLIENT_IP" \
  --cap-add NET_RAW --cap-add NET_ADMIN \
  -v "$LAB_DIR/tools:/lab/tools:ro" \
  "$IMG"

# server：只接远端链路，地址直接用 docker 分配的那个（必须如此，见 lib.sh 的说明）
run docker run -d --name "$C_SERVER" --hostname server \
  --network "$NET_FAR" --ip "$SERVER_IP" \
  --cap-add NET_RAW --cap-add NET_ADMIN \
  -v "$LAB_DIR/tools:/lab/tools:ro" \
  "$IMG"
sleep 1

# router：同时接两条链路
run docker run -d --name "$C_ROUTER" --hostname router \
  --network "$NET_NEAR" --ip "$ROUTER_IP_NEAR" \
  --cap-add NET_RAW --cap-add NET_ADMIN --cap-add NET_BIND_SERVICE \
  -v "$LAB_DIR/tools:/lab/tools:ro" \
  "$IMG"
if ! run docker network connect --ip "$ROUTER_IP_FAR" "$NET_FAR" "$C_ROUTER"; then
  err "把 router 接入 $NET_FAR 失败"; exit 1
fi
sleep 2

# 关键：docker run 失败（例如镜像不存在）在上面是看不到的，这里统一校验
missing=0
for c in "$C_CLIENT" "$C_ROUTER" "$C_SERVER"; do
  state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "missing")
  if [ "$state" != "true" ]; then
    err "容器 $c 未处于运行状态（$state）"
    docker logs --tail 20 "$c" 2>&1 | sed 's/^/    /' || true
    missing=1
  fi
done
if [ "$missing" = "1" ]; then
  err "容器启动失败，停止搭建"; exit 1
fi
ok "三个容器已启动并处于运行状态"

# ------------------------------------------- 4.5 地址规划自检（重要） ---
h2 "4.5 地址规划自检：容器地址必须落在所属链路的子网内"
# docker 会对 --ip 做校验（no configured subnet contains IP address ...），
# 这一类错误在实验里很常见，所以启动后立刻自查一遍。
subnet_of() {
  docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$1" \
    | awk '{print $1}'
}
NEAR_SUBNET=$(subnet_of "$NET_NEAR")
FAR_SUBNET=$(subnet_of "$NET_FAR")
log "  $NET_NEAR 子网 = $NEAR_SUBNET"
log "  $NET_FAR  子网 = $FAR_SUBNET"
ip_in_subnet() {
  python3 - "$1" "$2" <<'PYX'
import ipaddress, sys
ip, net = sys.argv[1], sys.argv[2]
sys.exit(0 if ipaddress.ip_address(ip) in ipaddress.ip_network(net, strict=False) else 1)
PYX
}
check_ip() {
  local c="$1" ip="$2" net="$3" iface="$4"
  if ip_in_subnet "$ip" "$net"; then
    printf '  %-16s %-15s 属于 %-20s ✅ (%s)\n' "$c" "$ip" "$net" "$iface"
  else
    err "$c 的地址 $ip 不在 $net 内 —— 拓扑配置有误，请修 scripts/lib.sh"
    return 1
  fi
}
bad=0
check_ip "$C_CLIENT" "$CLIENT_IP"      "$NEAR_SUBNET" "eth0" || bad=1
check_ip "$C_ROUTER" "$ROUTER_IP_NEAR" "$NEAR_SUBNET" "eth0" || bad=1
check_ip "$C_ROUTER" "$ROUTER_FAR_FWD" "$FAR_SUBNET"  "eth1(转发地址)" || bad=1
check_ip "$C_SERVER" "$SERVER_IP" "$FAR_SUBNET" "eth0" || bad=1
# 关键检查：client 与 server 必须【不在同一子网】，否则流量不走 router，
# 就没有"路径 MTU"这回事了
if ip_in_subnet "$SERVER_IP" "$NEAR_SUBNET"; then
  err "server 与 client 在同一子网，流量不会经过 router，实验结论会失真"
  bad=1
else
  printf '  %-16s %-15s 与 client 不同子网 ✅ (必须经 router 转发)\n' \
    "$C_SERVER" "$SERVER_IP"
fi
# 自检：docker 的 raw 表反欺骗规则（本实验最隐蔽的坑）
# 只要服务器地址在 docker 台账里，就会有一条
#   iifname != "<远端网桥>" ip daddr <server> drop
# 它会拦住"经路由器转发而来"的包，但【不拦】从本网桥直达的包。
# 所以本实验特意让转发走非台账地址（$ROUTER_FAR_FWD），这里做一次确认。
log ""
info "docker 反欺骗规则现状（raw 表，只对 docker 台账地址生效）："
iptables -t raw -S PREROUTING 2>/dev/null | grep -E -- '172\.31\.' | sed 's/^/    /' || \
  nft list table ip raw 2>/dev/null | grep -E '172\.31\.' | sed 's/^/    /' || true
log "    说明：上面针对 $SERVER_IP 的规则只影响从别的网桥进来的包；"
log "    本实验的转发地址是 $ROUTER_FAR_FWD（不在 docker 台账中），不会被拦。"
# 再看一眼计数器，确认我们关心的方向确实是 0
for c in "$C_CLIENT" "$C_SERVER"; do
  printf '  %s 的 docker 台账地址 = %s\n' "$c" \
    "$(docker network inspect -f '{{range .Containers}}{{if eq .Name "'"$c"'"}}{{.IPv4Address}}{{end}}{{end}}' "$NET_NEAR" "$NET_FAR" 2>/dev/null | tr -d ' ')"
done
if [ "$bad" = "1" ]; then
  err "地址规划自检未通过，停止搭建"; exit 1
fi
ok "地址规划自检通过"

# ------------------------------------------------------------ 5. 配路由 ---
h2 "5. 配置接口地址与静态路由"

# --- client ---
cex "$C_CLIENT" ip addr add "$CLIENT_IP/24" dev eth0 2>/dev/null || true
cex "$C_CLIENT" ip link set eth0 up
cex "$C_CLIENT" ip route replace default via "$ROUTER_IP_NEAR"
cex "$C_CLIENT" ip route replace "$SERVER_NET" via "$ROUTER_IP_NEAR"
# 清掉历史遗留的错路由（重复执行 setuo 时可能残留）
cex "$C_CLIENT" bash -c 'for n in 172.31.20.0/24 172.31.12.0/24; do
    ip route del "$n" 2>/dev/null && echo "  已清理历史错路由 $n" || true
  done' 

# --- server ---
cex "$C_SERVER" ip link set eth0 up
# 自愈：删掉除 docker 分配地址之外的多余地址。
#   手工加的第二地址会被 docker 在 raw/PREROUTING 里 DROP，
#   留着只会让"ping 不通"这种诡异现象出现，所以这里主动清理。
cex "$C_SERVER" bash -c '
  want="'"$SERVER_IP"'"
  for a in $(ip -4 -o addr show dev eth0 | awk "{print \$4}" | cut -d/ -f1); do
    if [ "$a" != "$want" ]; then
      echo "  移除多余地址 $a（会被 docker raw 表 DROP）"
      ip addr del "$a/24" dev eth0 || true
    fi
  done
  ip -4 -o addr show dev eth0
'
cex "$C_SERVER" ip route replace default via "$ROUTER_FAR_FWD"

# --- router ---
cex "$C_ROUTER" ip addr add "$ROUTER_IP_NEAR/24" dev eth0 2>/dev/null || true
cex "$C_ROUTER" ip addr add "$ROUTER_IP_FAR/24" dev eth1 2>/dev/null || true
cex "$C_ROUTER" ip link set eth0 up
cex "$C_ROUTER" ip link set eth1 up
# 关键：让内核在这块网卡上按 1400 处理（模拟 PPPoE / GRE / IPsec 隧道的窄链路）
cex "$C_ROUTER" ip link set eth1 mtu "$MTU_FAR"
# 加上【转发专用】地址（docker 不感知，因此不会被 raw 表反欺骗规则拦截）
cex "$C_ROUTER" ip addr add "$ROUTER_FAR_FWD/24" dev eth1 2>/dev/null || true
# 开启转发
cex "$C_ROUTER" sysctl -w net.ipv4.ip_forward=1
# 本实验要看到 ICMP 差错，必须关掉 ICMP 限速，否则只回一条就被限流
cex "$C_ROUTER" sysctl -w net.ipv4.icmp_ratelimit=0
cex "$C_ROUTER" sysctl -w net.ipv4.icmp_ratemask=0
ok "路由配置完成"

# ------------------------- 5.5 关闭 docker 反欺骗规则（必须） ---
h2 "5.5 关闭 docker 的反欺骗规则（否则跨网桥转发会被静默丢弃）"
log "  背景：docker 会在宿主 nft 的 ip raw 表里为每个容器地址插入"
log "        'iifname != <本网桥> ip daddr <容器地址> drop'。"
log "        它只放行同网桥直达的包，会把经路由器转发来的包全部丢掉，"
log "        且没有任何官方开关可关 —— 只能显式删除。"
remove_antspoof "172.31."

# -------------------------------------------- 6. 关闭校验和卸载（重要） ---
h2 "6. 关闭网卡校验和卸载（让 tcpdump 看到真实校验和）"
# 虚拟网卡默认把校验和计算交给内核"事后补"，tcpdump 抓到时会显示
# "incorrect" 或 "unverified"。关掉之后，抓包里看到的才是真正的校验和。
for c in "$C_CLIENT" "$C_ROUTER" "$C_SERVER"; do
  log "  [$c]"
  for f in tx rx tso gso gro; do
    docker exec "$c" ethtool -K eth0 "$f" off 2>/dev/null | sed 's/^/    /' || true
  done
  docker exec "$c" ethtool -K eth1 "$f" off 2>/dev/null | sed 's/^/    /' || true
done
ok "已尝试关闭 tx/rx/tso/gso/gro（失败项说明该网卡不支持，可忽略）"

# ------------------------------------------------------------ 7. 自检 ---
h2 "7. 拓扑自检"

log ""
info "客户端路由表："
cex "$C_CLIENT" ip route
log ""
info "各接口 MTU："
for c in "$C_CLIENT" "$C_ROUTER" "$C_SERVER"; do
  printf '  [%s]\n' "$c"
  docker exec "$c" ip -br link | sed 's/^/    /'
done

log ""
info "连通性测试（client -> server 经 router 转发）："
if docker exec "$C_CLIENT" ping -c 2 -W 2 "$SERVER_IP" >/dev/null 2>&1; then
  ok "client -> server 通"
else
  err "client -> server 不通，请检查上面的路由表"
fi

log ""
info "窄链路验证：client 发 1472 字节载荷（=1500-20-8）"
if docker exec "$C_CLIENT" ping -c 1 -W 2 -M do -s $((MTU_FAR - 28)) "$SERVER_IP" >/dev/null 2>&1; then
  ok "MTU $MTU_FAR 的包可以通过 —— 说明路由器 eth1 确实是 $MTU_FAR"
else
  warn "未通过，稍后 $MTU_FAR 相关实验可能结果不同，请检查 'ip -br link' 里 eth1 的 MTU"
fi
log ""
info "PMTU 缓存（注意 mtu 字段，它记录的是“试出来”的路径 MTU）："
cex "$C_CLIENT" ip route get "$SERVER_IP"

h1 "环境就绪"
note "接下来按顺序运行："
log "  scripts/10-udp-header.sh       UDP 首部与校验和"
log "  scripts/20-port-unreachable.sh ICMP 端口不可达"
log "  scripts/30-fragmentation.sh    IP 分片"
log "  scripts/40-pmtud.sh            路径 MTU 发现与黑洞"
log "  scripts/50-stats.sh            端口/缓冲区/统计计数器"
log "  scripts/60-boundary.sh         报文边界、无流控、无重传"
log ""
log "全部一次跑完：  scripts/run-all.sh"
log "查看日志：      ls -l logs/    查看抓包： ls -l capture/"
log "销毁环境：      scripts/99-teardown.sh"
