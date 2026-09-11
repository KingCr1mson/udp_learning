# UDP 学习实验镜像
#
# 目标：一个装了「观察网络所需全部工具」的 Ubuntu，
#       用来做 TCP/IP 详解 第11章 UDP 的所有验证实验。
#
# 镜像里为什么要装这些：
#   iproute2  -> ip / ss      看接口 MTU、路由表、socket 队列
#   tcpdump   -> 抓包         看 UDP 首部、ICMP 差错、IP 分片
#   netcat    -> nc           快速制造 UDP 流量（端口不可达实验）
#   socat     -> 备用 UDP 工具
#   iptables  -> 制造 PMTUD 黑洞（丢弃 ICMP）
#   iputils-ping -> ping -M do / -M dont   触发分片与 PMTUD 的最小工具
#   procps    -> netstat -su  看 UDP 统计计数器
#   python3   -> 手工构造带伪首部的 UDP 报文、计算校验和
#   dnsutils  -> dig          观察真实 UDP 应用（DNS 走 53/udp）
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      iproute2 \
      ethtool \
      iputils-ping \
      tcpdump \
      netcat-openbsd \
      socat \
      iptables \
      procps \
      net-tools \
      python3 \
      dnsutils \
      ca-certificates \
      bash \
      coreutils \
      kmod \
 && rm -rf /var/lib/apt/lists/*

# 版本自检：记录进镜像层，构建日志里就能看到工具版本
RUN set -x \
 && ip -V \
 && ping -V \
 && tcpdump --version 2>&1 | head -1 \
 && ss -V \
 && python3 -V

WORKDIR /lab
CMD ["sleep", "infinity"]
