#!/usr/bin/env bash
# ============================================================================
#  run-all.sh —— 依次执行全部实验并汇总
#
#  默认非交互（不暂停），适合无人值守跑完、事后看日志。
#  想边跑边看并手动暂停：  PAUSE=1 scripts/run-all.sh
#  已经建好环境不想重建：  SKIP_SETUP=1 scripts/run-all.sh
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export PAUSE="${PAUSE:-0}"
SUMMARY="$LOG_DIR/SUMMARY.txt"

TOTAL_START=$(date +%s)

h1 "UDP 实验全套执行"
log "开始时间: $(date -Is)"
log "工作目录: $LAB_DIR"
log "PAUSE=$PAUSE   SKIP_SETUP=${SKIP_SETUP:-0}"
log ""
log "将依次执行："
log "  00-setup.sh           建拓扑（client / router / server，窄链路 MTU $MTU_FAR）"
log "  10-udp-header.sh      UDP 首部、伪首部、校验和"
log "  20-port-unreachable.sh ICMP 端口不可达"
log "  30-fragmentation.sh   IP 分片"
log "  40-pmtud.sh           路径 MTU 发现与 PMTUD 黑洞"
log "  50-stats.sh           端口、缓冲区、统计计数器"
log "  60-boundary.sh        报文边界、无重传、无流控"

declare -a RESULTS=()

run_step() {
  local script="$1" name="$2"
  local start end rc
  printf '\n\n'
  printf '%s@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%s\n' \
    "$C_B$C_MAG" "$C_RST"
  printf '%s@@ 运行 %s%s\n' "$C_B$C_MAG" "$name" "$C_RST"
  printf '%s@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%s\n' \
    "$C_B$C_MAG" "$C_RST"
  start=$(date +%s)
  if bash "$script"; then
    rc=0
  else
    rc=$?
  fi
  end=$(date +%s)
  local dur=$((end - start))
  if [ "$rc" -eq 0 ]; then
    ok "$name 完成（耗时 ${dur}s）"
    RESULTS+=("OK    ${name}  ${dur}s")
  else
    err "$name 失败（退出码 $rc，耗时 ${dur}s）"
    RESULTS+=("FAIL  ${name}  rc=$rc  ${dur}s")
  fi
}

if [ "${SKIP_SETUP:-0}" != "1" ]; then
  run_step "$LAB_DIR/scripts/00-setup.sh" "00-setup"
else
  info "按要求跳过环境搭建"
fi

run_step "$LAB_DIR/scripts/10-udp-header.sh"       "10-udp-header"
run_step "$LAB_DIR/scripts/20-port-unreachable.sh" "20-port-unreachable"
run_step "$LAB_DIR/scripts/30-fragmentation.sh"    "30-fragmentation"
run_step "$LAB_DIR/scripts/40-pmtud.sh"            "40-pmtud"
run_step "$LAB_DIR/scripts/50-stats.sh"            "50-stats"
run_step "$LAB_DIR/scripts/60-boundary.sh"         "60-boundary"

TOTAL_END=$(date +%s)

# ------------------------------------------------------------- 汇总输出 ---
{
  echo
  echo "======================================================================"
  echo " UDP 实验汇总报告"
  echo "======================================================================"
  echo "开始: $(date -d @"$TOTAL_START" -Is 2>/dev/null || date -Is)"
  echo "结束: $(date -Is)"
  echo "总耗时: $((TOTAL_END - TOTAL_START)) 秒"
  echo
  echo "---- 各步骤结果 ----"
  for r in "${RESULTS[@]}"; do echo "  $r"; done
  echo
  echo "---- 生成的学习材料 ----"
  echo "日志（每节的完整过程，可直接当笔记看）："
  for f in "$LOG_DIR"/*.log; do
    [ -f "$f" ] && printf '  %-46s %6s 行\n' "logs/$(basename "$f")" "$(wc -l < "$f")"
  done
  echo
  echo "抓包文件（可用 Wireshark 打开 pcap，或看同名 .txt 文本版）："
  if compgen -G "$CAP_DIR/*.pcap" > /dev/null; then
    for f in "$CAP_DIR"/*.pcap; do
      printf '  %-46s %6s 字节\n' "capture/$(basename "$f")" "$(stat -c%s "$f")"
    done
  else
    echo "  （无）"
  fi
  echo
  echo "---- 建议的下一步 ----"
  echo "  1. 通读 logs/SUMMARY.txt 与各节日志"
  echo "  2. 用 Wireshark 打开 capture/*.pcap，重点看："
  echo "       - UDP 首部四个字段（含校验和验证）"
  echo "       - ICMP type3 code3 / code4，以及内嵌的原报文前 8 字节"
  echo "       - IP 分片：MF 标志与 fragment offset 的递增"
  echo "  3. 自己动手改 tools/udplab.py 里的数字，重跑某一节观察差异"
  echo "  4. 销毁环境: scripts/99-teardown.sh"
  echo "======================================================================"
} | tee "$SUMMARY"

h1 "全部完成"
ok "汇总报告: logs/SUMMARY.txt"
log "查看日志:  ls -l $LOG_DIR"
log "查看抓包:  ls -l $CAP_DIR"
log "销毁环境:  scripts/99-teardown.sh"
