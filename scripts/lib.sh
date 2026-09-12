#!/usr/bin/env bash
# ============================================================================
#  lib.sh —— UDP 实验公共库
#
#  仅被其他脚本 source，不单独执行。
#
#  【设计约定 —— 都是踩坑总结的，改代码请遵守】
#
#  1. 引号
#     往容器里塞复杂 shell 逻辑时，绝不用
#         docker exec "$c" bash -c "...."
#     这种"双引号里再嵌双引号"的写法。它在多行续行 + 嵌套引号时极易崩，
#     更糟的是 bash -n 有时检查不出来，只在运行时静默变形。
#     统一做法：写成 helper 函数（见 cs / kill_bg / udp_listen ...），
#     用单引号包脚本、用位置参数传值：
#         docker exec -i "$c" bash -s -- "$a" "$b" <<'EOS'
#         ...
#         EOS
#
#  2. pkill 自匹配
#     pkill -f udpecho 会匹配到执行它的那个 shell 自己（其命令行里就含
#     "udpecho"），把父 shell 一起杀掉 —— 表现为"脚本莫名中断"。
#     必须写成 pkill -f "[u]dpecho" 这种正则技巧。
#
#  3. 抓包
#     同样不能用 pkill -f tcpdump 收尾，改为写 PID 文件 + 按 PID kill。
#
#  4. 后台服务
#     用 docker exec -d 启动，且启动脚本先写进容器再执行，
#     避免 docker exec -d "... &" 里的 $! 被外层提前展开。
# ============================================================================

set -u

# ---------------------------------------------------------------- 路径 ----
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$LAB_DIR/logs"
CAP_DIR="$LAB_DIR/capture"
mkdir -p "$LOG_DIR" "$CAP_DIR"

# docker 配置只使用用户级默认目录 ~/.docker（即不覆盖 DOCKER_CONFIG，
# 由 docker 自己取默认值）。
# 【为何不放进工作目录】：buildx 会在配置目录里写锁文件、builder 状态和
# 机器相关的绝对路径；一旦落在仓库内就会被 git 跟踪，污染项目。

# ---------------------------------------------------------------- 拓扑 ----
PREFIX="udplab"
NET_NEAR="${PREFIX}-net-near"    # 近端链路 172.31.10.0/24
NET_FAR="${PREFIX}-net-far"      # 远端链路 172.31.11.0/24（卡口在 router eth1）
IMG="${PREFIX}:24.04"

C_CLIENT="${PREFIX}-client"
C_ROUTER="${PREFIX}-router"
C_SERVER="${PREFIX}-server"

# 地址规划（三条约束，都是踩坑得来的）：
#   ① 地址必须落在本链路子网内（docker 会校验 --ip）
#   ② 避开 docker 网桥自身/网关占用的地址
#   ③ 容器地址必须用 docker 分配的那个；事后手工再加一个地址会被 docker
#      在 nft 的 ip raw 表里插 DROP 规则顶掉
# 另外：真正用于【转发】的远端地址 ROUTER_FAR_FWD 故意不用 docker 台账地址，
# 因为那条 raw 反欺骗规则会拦掉"经路由器转发而来"的包（setup 里还会删除它们）。
CLIENT_IP="172.31.10.10"
ROUTER_IP_NEAR="172.31.10.1"
ROUTER_FAR_FWD="172.31.11.2"     # 手工添加，docker 不感知
ROUTER_IP_FAR="172.31.11.100"    # docker 分配的（保留做对照）
SERVER_IP="172.31.11.1"
SERVER_NET="$(python3 -c "import ipaddress;print(ipaddress.ip_network('$SERVER_IP/24',strict=False))")"

MTU_NEAR=1500
MTU_FAR=1400                     # ← 唯一的窄链路，分片/PMTUD 都由它触发

# 常用端口
PORT_ECHO=9999                   # 正常监听的 UDP 端口
PORT_CLOSED=9998                 # 故意无人监听
PORT_BOUNDARY=9997
PORT_ACK=9996

# ---------------------------------------------------------------- 颜色 ----
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_MAG=$'\033[35m'
else
  C_RST=; C_B=; C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_MAG=
fi

# ---------------------------------------------------------------- 日志 ----
log()  { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

h1() {
  printf '\n%s%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_B$C_MAG" "" "$C_RST"
  printf '%s%s║ %-68s ║%s\n' "$C_B$C_MAG" "" "$1" "$C_RST"
  printf '%s%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_B$C_MAG" "" "$C_RST"
}
h2()   { printf '\n%s%s── %s ──────────────────────────────────────────%s\n' "$C_B$C_BLU" "" "$1" "$C_RST"; }
note() { printf '%s  ★ %s%s\n' "$C_YEL" "$*" "$C_RST"; }
sep()  { printf '%s%s%s\n' "$C_DIM" "----------------------------------------------------------------------" "$C_RST"; }

run() {
  printf '%s$ %s%s\n' "$C_DIM" "$*" "$C_RST"
  "$@"
}

# 在容器里执行命令并打印；失败时明确标出
cex() {
  local c="$1"; shift
  printf '%s[%s]$ %s%s\n' "$C_DIM" "$c" "$*" "$C_RST"
  if ! docker exec "$c" "$@"; then
    printf '%s  ^^^ 上面这条命令在 %s 中执行失败（退出码非 0）%s\n' \
      "$C_YEL" "$c" "$C_RST" >&2
    return 1
  fi
}

# 在容器里跑一段 shell 脚本（同样用 base64 传，避免 stdin 争抢）。
# 脚本里可以随意用多行、引号、heredoc。
#   usage: cs <container> <script-text> [args...]
cs() {
  local c="$1" script="$2"; shift 2
  local b64
  b64=$(printf '%s' "$script" | base64 -w0)
  docker exec "$c" bash -c "echo '$b64' | base64 -d | bash -s -- $*"
}

# 把一段脚本送进容器并执行。
# 【为什么要 base64】：如果写成 docker exec -i ... bash -s <<EOF，那么
# bash 会从 stdin 读“要执行的脚本”，而我们想传的脚本内容也在 stdin 里，
# 两者会互相抢 —— 实测结果是脚本内容被当成命令执行、或干脆被吞掉。
# 用 base64 当参数直接传，完全不碰 stdin，才可靠。
#   usage: cs_script <container> <interpreter> <script-text>
cs_script() {
  local c="$1" interp="$2" text="$3"
  local b64
  b64=$(printf '%s' "$text" | base64 -w0)
  docker exec "$c" bash -c "echo '$b64' | base64 -d | $interp"
}

log_init() {
  local f="$1"
  mkdir -p "$(dirname "$f")"
  : > "$f"
  exec > >(tee -a "$f") 2>&1
  printf '# 日志开始: %s\n# 主机: %s\n# 用户: %s\n\n' \
    "$(date -Is)" "$(hostname)" "$(id -un)"
}

pause() {
  if [ "${PAUSE:-1}" = "1" ] && [ -t 0 ]; then
    printf '\n%s按回车继续...%s' "$C_DIM" "$C_RST"
    read -r _ || true
  fi
}

# ------------------------------------------------------------ 进程管理 ----
# 按"正则技巧"终止容器内后台进程：udpecho -> [u]dpecho
kill_bg() {
  local c="$1" pat="$2"
  local bracket="[${pat:0:1}]${pat:1}"
  docker exec "$c" pkill -f "$bracket" 2>/dev/null || true
  sleep 0.4
}

# server 上起一个 UDP 回显监听（日志固定落在 /tmp/echo-<port>.log）
#   生成脚本时直接内插数值，避免"参数没传进去"这类问题
udp_listen() {
  local c="$1" port="$2" secs="${3:-20}" extra="${4:-}"
  kill_bg "$c" udpecho
  local rc="/lab/run-listen-${port}.sh"
  docker exec "$c" mkdir -p /lab
  docker exec -i "$c" bash -s -- "$rc" <<EOS
rc="\$1"
cat > "\$rc" <<INNER
#!/bin/bash
exec python3 /lab/tools/udpecho.py server --port $port --timeout $secs $extra > /tmp/echo-$port.log 2>&1
INNER
EOS
  docker exec -d "$c" bash "$rc"
  sleep 1.5
  log "  [$c] 已启动 UDP 回显监听 :$port（${secs}s 后自动退出）"
}

udp_listen_log() {
  local c="$1" port="$2" lines="${3:-30}"
  docker exec "$c" bash -c "cat /tmp/echo-$port.log 2>/dev/null | tail -$lines" || true
}

# server 上起一个 TCP 回显服务（对照实验用）
tcp_listen() {
  local c="$1" port="$2" secs="${3:-25}"
  kill_bg "$c" tcpecho
  local rc="/lab/run-tcplisten-${port}.sh"
  docker exec "$c" mkdir -p /lab
  docker exec -i "$c" bash -s -- "$rc" <<EOS
rc="\$1"
cat > "\$rc" <<INNER
#!/bin/bash
exec python3 /lab/tools/tcpecho.py --port $port --timeout $secs > /tmp/tcpecho-$port.log 2>&1
INNER
EOS
  docker exec -d "$c" bash "$rc"
  sleep 1.5
  log "  [$c] 已启动 TCP 回显监听 :$port（${secs}s 后自动退出）"
}

tcp_listen_log() {
  local c="$1" port="$2" lines="${3:-30}"
  docker exec "$c" bash -c "cat /tmp/tcpecho-$port.log 2>/dev/null | tail -$lines" || true
}

# ------------------------------------------------------------ 抓包控制 ----
# 启动脚本里用 PID 文件记录 tcpdump 的进程号，后面按 PID 精确终止。
# 绝不使用 pkill -f tcpdump：它会匹配到执行它的 shell 自己，把父 shell 杀掉。
cap_start() {
  local c="$1" iface="$2" bpf="$3" name="$4"
  docker exec "$c" mkdir -p /lab/cap
  local rc="/lab/run-cap-${name}.sh"
  # 关键：$bpf 必须加单引号。过滤表达式里有括号和 &，不加引号会被 shell
  # 当成语法错误，tcpdump 根本起不来，而 -d 方式启动时错误还看不到。
  docker exec -i "$c" bash -s -- "$rc" <<EOS
rc="\$1"
cat > "\$rc" <<INNER
#!/bin/bash
nohup tcpdump -i $iface -nn -s0 -w /lab/cap/$name.pcap '$bpf' >/tmp/cap-$name.err 2>&1 &
echo \\\$! > /lab/cap/$name.pid
INNER
EOS
  docker exec -d "$c" bash "$rc"
  sleep 1.5
  local pid
  pid=$(docker exec "$c" cat "/lab/cap/${name}.pid" 2>/dev/null || echo "?")
  info "抓包已启动: $c/$iface 过滤='${bpf:-all}' pid=$pid"
}

cap_stop() {
  local c="$1" name="$2"
  # 按 PID 精确终止（绝不能用 pkill -f tcpdump，会把自己这条 shell 杀掉）
  docker exec -i "$c" bash -s -- "$name" >/dev/null 2>&1 <<'EOS' || true
name="$1"
if [ -f "/lab/cap/$name.pid" ]; then
  kill "$(cat /lab/cap/$name.pid)" 2>/dev/null
  sleep 1
  kill -9 "$(cat /lab/cap/$name.pid)" 2>/dev/null
fi
exit 0
EOS
  sleep 0.5
  docker cp "$c:/lab/cap/${name}.pcap" "$CAP_DIR/${name}.pcap" >/dev/null 2>&1 || true
  if [ -s "$CAP_DIR/${name}.pcap" ]; then
    docker exec "$c" tcpdump -nn -vv -e -tttt -r "/lab/cap/${name}.pcap" \
      > "$CAP_DIR/${name}.txt" 2>/dev/null || true
    local n
    n=$(grep -c . "$CAP_DIR/${name}.txt" 2>/dev/null || echo 0)
    ok "抓包已保存: capture/${name}.pcap（${n} 行文本 -> capture/${name}.txt）"
  else
    warn "抓包文件为空: ${name}（检查过滤条件是否匹配到了流量）"
    # 把 tcpdump 自己的报错抛出来，否则这类失败是完全静默的
    local e
    e=$(docker exec "$c" bash -c "cat /tmp/cap-${name}.err 2>/dev/null | head -3" || true)
    [ -n "$e" ] && printf '%s  tcpdump 报错: %s%s\n' "$C_YEL" "$e" "$C_RST"
  fi
}

cap_clear() {
  local c="$1"
  docker exec "$c" bash -c 'rm -f /lab/cap/*.pcap /lab/cap/*.pid' 2>/dev/null || true
}

# ------------------------------------------- 关闭 docker 反欺骗规则 ----
# docker 会为每个"它分配的容器地址"在宿主 nft 的 ip raw 表
# （hook priority raw，优先级高于 conntrack/NAT）里插入：
#     iifname != "<该容器所在网桥>" ip daddr <容器地址> drop
# 它只放行同网桥直达的包，会把【经路由器转发而来】的包全部丢掉。
# 没有任何官方开关可以关闭，只能显式删除。
remove_antspoof() {
  local prefix="${1:-172.31.}"
  command -v nft >/dev/null 2>&1 || { warn "没有 nft 命令，跳过"; return 0; }
  local removed=0 handles h
  handles=$(nft -a list table ip raw 2>/dev/null \
    | awk -v p="$prefix" '$0 ~ p && $0 ~ /drop/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
  for h in $handles; do
    nft delete rule ip raw PREROUTING handle "$h" 2>/dev/null && removed=$((removed+1))
  done
  if [ "$removed" -gt 0 ]; then
    ok "已移除 $removed 条 docker 反欺骗规则（否则跨网桥转发会被静默丢弃）"
  else
    info "没有需要移除的反欺骗规则"
  fi
}

# ------------------------------------------------------------ 环境检查 ----
need_topology() {
  for c in "$C_CLIENT" "$C_ROUTER" "$C_SERVER"; do
    if ! docker inspect "$c" >/dev/null 2>&1; then
      err "容器 $c 不存在，请先运行: scripts/00-setup.sh"
      exit 1
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$c")" != "true" ]; then
      warn "容器 $c 未运行，正在启动..."
      docker start "$c" >/dev/null
      sleep 2
    fi
  done
}
