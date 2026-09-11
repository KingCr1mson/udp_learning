#!/usr/bin/env bash
# ============================================================================
#  99-teardown.sh —— 销毁实验环境
#
#  只删除本实验创建的资源（都以 ${PREFIX}- 开头），
#  不会碰你机器上其他 docker 容器 / 镜像 / 网络。
# ============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
log_init "$LOG_DIR/99-teardown.log"

h1 "销毁 UDP 实验环境"

# 先清掉实验过程中可能留下的 iptables 规则（容器删了就没了，这里只是干净起见）
h2 "1. 清理容器内的 iptables 规则"
for c in "$C_ROUTER" "$C_CLIENT" "$C_SERVER"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker exec "$c" bash -c '
      iptables -F FORWARD 2>/dev/null
      iptables -F OUTPUT 2>/dev/null
      iptables -t mangle -F FORWARD 2>/dev/null
      echo "  已清空 '"$c"' 的 iptables 规则"
    ' 2>/dev/null || true
  fi
done

h2 "2. 停止并删除容器"
for c in "$C_CLIENT" "$C_ROUTER" "$C_SERVER"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker rm -f "$c" >/dev/null 2>&1 && ok "已删除容器 $c"
  else
    info "容器 $c 不存在，跳过"
  fi
done

h2 "3. 删除网络"
for n in "$NET_NEAR" "$NET_FAR"; do
  if docker network inspect "$n" >/dev/null 2>&1; then
    docker network rm "$n" >/dev/null 2>&1 && ok "已删除网络 $n"
  else
    info "网络 $n 不存在，跳过"
  fi
done

h2 "4. 保留内容（学习材料不删）"
log "  镜像      $IMG          （用 IMG_DEL=1 一起删）"
log "  日志      $LOG_DIR/"
log "  抓包      $CAP_DIR/"
if [ "${IMG_DEL:-0}" = "1" ]; then
  docker rmi "$IMG" >/dev/null 2>&1 && ok "已删除镜像 $IMG"
fi

h2 "5. 剩余相关资源检查"
log "容器："
docker ps -a --filter "name=${PREFIX}" --format '  {{.Names}}  {{.Status}}' || true
log "网络："
docker network ls --filter "name=${PREFIX}" --format '  {{.Name}}' || true

h1 "完成"
log "重新搭建： scripts/00-setup.sh"
