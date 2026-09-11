# UDP 实验环境（TCP/IP 详解 第11章）

用 Docker 搭一个三节点小网络，把 UDP 这一章的每个知识点都变成**可以亲眼看到的现象**。
不是"读一遍协议"，而是让你抓包、看计数器、亲手把网络搞坏，再观察后果。

---

## 1. 拓扑：为什么不是两台 Ubuntu

课本讲 UDP 时会反复提到"分片"和"路径 MTU"，而这两件事**在直连的两台机器之间做不出来**，
因为主机只知道自己的网卡 MTU，不知道路径中间还有更窄的链路。

所以这里用**三台**：

```
     client                    router                     server
  172.31.10.10            172.31.10.1                  172.31.11.1
        |                 172.31.11.2                       |
        | eth0                 eth0 | eth1                 | eth0
        +----[ udplab-net-near ]----+ +----[ udplab-net-far ]----+
             172.31.10.0/24                 172.31.11.0/24
                                        router eth1 MTU = 1400  ← 唯一的窄链路
```

- **client 与 server 不在同一子网**，所以流量**必须**经过 router 转发；
- **router eth1 的 MTU 被改成 1400**，模拟 PPPoE / GRE / IPsec 隧道这类窄链路；
- 于是就有了课本里的经典场景：一端能发 1500，路径中间只能过 1400。

| 角色 | 容器名 | 地址 | 作用 |
|---|---|---|---|
| client | `udplab-client` | 172.31.10.10 | 发送方，跑 `udplab.py` |
| router | `udplab-router` | 172.31.10.1 / 172.31.11.2 | 转发 + 分片 + 回 ICMP 差错 |
| server | `udplab-server` | 172.31.11.1 | 接收方，跑 `udpecho.py` / `tcpecho.py` |

---

## 2. 快速开始

```bash
cd udp-lab

# 1) 搭建环境（构建镜像 + 建网络 + 起容器 + 配路由 + 自检）
bash scripts/00-setup.sh

# 2) 看单节实验（推荐边看边想）
bash scripts/10-udp-header.sh        # UDP 首部与校验和
bash scripts/20-port-unreachable.sh  # ICMP 端口不可达
bash scripts/30-fragmentation.sh     # IP 分片
bash scripts/40-pmtud.sh             # 路径 MTU 发现与黑洞
bash scripts/50-stats.sh             # 端口、缓冲区、统计计数器
bash scripts/60-boundary.sh          # 报文边界、无重传、无流控

# 3) 或者一次跑完全部（不暂停，事后读日志）
bash scripts/run-all.sh

# 4) 销毁环境（只删本实验资源）
bash scripts/99-teardown.sh
```

看结果：

```bash
ls logs/        # 每节的完整过程日志，可直接当笔记读
ls capture/     # 抓包文件（.pcap 可用 Wireshark 打开，.txt 是文本版）
```

环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `PAUSE=1` | 0 | 每小节后暂停，按回车继续（适合边看边学） |
| `SKIP_SETUP=1` | 0 | run-all 时跳过重新搭建环境 |
| `REBUILD=1` | 0 | 强制重建实验镜像 |

---

## 3. 每节在验证什么

### 10 — UDP 首部与校验和

| 现象 | 对应课本结论 |
|---|---|
| 打印出 8 字节首部每个字节的二进制 | 四个字段各 16 位 |
| 逐项手算伪首部 + 首部 + 数据的反码和 | 校验和覆盖范围含**伪首部** |
| 校验和写错 → 接收方**静默丢弃** | 校验只用于"发现"，不用于"通知" |
| 校验和填 0 → 接收方照收 | IPv4 中校验和可选（IPv6 强制） |
| 算出 0 要写 0xFFFF | 0 有特殊含义：发送方未计算 |

### 20 — ICMP 端口不可达

| 现象 | 对应课本结论 |
|---|---|
| 抓到 `ICMP type 3 code 3` | 差错由 **IP/ICMP 层**产生，UDP 自己不发差错 |
| 解码出错报文里**内嵌的原报文前 8 字节**，正好是 UDP 首部（源端口/目的端口） | 为什么只带 8 字节 |
| **未 connect** 的 socket 收不到该差错 | 差错关联不可靠 |
| **已 connect** 的 socket 得到 `ECONNREFUSED` | 内核能唯一对应时才翻译成错误 |

### 30 — IP 分片

| 现象 | 对应课本结论 |
|---|---|
| 载荷 ≤ 1372 整包通过；1373 起出现 `offset 1376` 的第二片 | 片偏移**以 8 字节为单位** |
| 第一片 `flags [+]`(MF=1)，最后一片 `flags []`(MF=0) | MF 表示"后面还有" |
| 第二片显示 `ip-proto-17`，没有端口号 | **只有第一片带 UDP 首部** → NAT/防火墙不友好 |
| 载荷 4000 被切成 3 片 | 每片都要带 20 字节 IP 首部 → 带宽浪费 |
| 抓包看到多片，但 server 应用层只收到 **1 条**完整报文 | 重组只在**最终目的主机**的 IP 层发生 |
| 200 个 100 字节包 vs 200 个 4000 字节包，链路上包数差异巨大 | 大包 = 更多独立丢包机会 |

### 40 — 路径 MTU 发现与黑洞

| 现象 | 对应课本结论 |
|---|---|
| `ping -M do -s 1372` 通过，`-s 1373` 失败 | 临界值 = MTU − 28 |
| 收到 `ICMP ... need to frag (mtu 1400)` | 路由器把下一跳 MTU 告诉发送方 |
| `ip route get` 出现 `mtu 1400` | PMTU **缓存**按目的地址记录 |
| 换一个**没用过**的目的地址，`sendto()` 成功但包被丢弃 | 新目的地址没有缓存 → 必须重新探测 |
| 封掉 ICMP 后，client 侧抓到 **0 条** ICMP | **PMTUD 黑洞**：小包通、大包死、无报错 |
| `tcp_mtu_probing` / `TCPMSS --clamp-mss-to-pmtu` | TCP 有兜底，UDP 完全没有 |

### 50 — 端口、缓冲区、统计计数器

| 现象 | 对应课本结论 |
|---|---|
| `ip_local_port_range` 32768–60999 | 临时端口范围 |
| `ss -uanp` 只有 UNCONN / ESTAB | UDP 无连接状态机 |
| 发到空端口 20 个 → `NoPorts +20` | 端口无人监听的丢弃计数 |
| 灌包 20000 个 → `RcvbufErrors` 从 0 涨到 9000+ | **UDP 最真实的丢包原因**，且发送方毫无感知 |
| 校验和写错 → `InCsumErrors +1` | 校验失败计数 |

### 60 — 报文边界、无重传、无流控

| 现象 | 对应课本结论 |
|---|---|
| UDP：3 次 sendto → 3 次 recvfrom，长度 5/3/2000 完全保持 | UDP **保留报文边界** |
| TCP：`recv(100)` 拿到的分段与 send 边界毫无关系 | TCP 是字节流 → **粘包问题的根源** |
| 路由器丢 1/3 包时，UDP 序号出现空缺且永不重传 | UDP 无确认无重传 |
| 同样丢包下，TCP 10 条全到，`segments retransmitted` 增加 | TCP 内核负责可靠投递 |

---

## 4. 目录结构

```
udp-lab/
├── README.md                  ← 本文档
├── image/Dockerfile           实验镜像（Ubuntu 24.04 + 网络工具）
├── scripts/
│   ├── lib.sh                 公共库：日志、容器封装、抓包、服务管理
│   ├── 00-setup.sh            搭建与自检
│   ├── 10-udp-header.sh       ...
│   ├── 60-boundary.sh
│   ├── run-all.sh             全部跑一遍并生成汇总
│   └── 99-teardown.sh         销毁
├── tools/
│   ├── udplab.py              核心工具：csum/dump/send/sendraw/recv/icmpwatch/flood
│   ├── udpecho.py             UDP 回显服务 + 带序号客户端（看丢包）
│   ├── tcpecho.py             TCP 回显服务（对照）
│   └── probe.py               边界与可靠性对比探针
├── logs/                      运行日志（每节一个 .log + SUMMARY.txt）
└── capture/                   抓包（.pcap + 同名 .txt 文本版）
```

`tools/` 以只读方式挂载进容器（`/lab/tools`），所以在宿主机改完脚本即可生效，不用重建镜像。

---

## 5. 自带的诊断工具（`udplab.py`）

```bash
# 手算并核对 UDP 校验和（含伪首部，逐步打印）
python3 /lab/tools/udplab.py csum --payload ABCDEF

# 抓下内核真正发出的字节流并逐字段解析（含点划线图）
python3 /lab/tools/udplab.py dump --dst 172.31.11.1 --dport 9999

# 普通 socket 发送，可控 DF 位
python3 /lab/tools/udplab.py send --dst 172.31.11.1 --dport 9999 --size 2000 --df 1

# 自己拼 IP+UDP 首部发送，可故意写错校验和 / 不写校验和
python3 /lab/tools/udplab.py sendraw --src 172.31.10.10 --dst 172.31.11.1 \
        --sport 40100 --dport 9999 --size 16 --bad-checksum

# 监听并解码 ICMP 差错（会打印内嵌的原报文 UDP 首部）
python3 /lab/tools/udplab.py icmpwatch --timeout 8

# 高速灌包（制造缓冲区溢出）
python3 /lab/tools/udplab.py flood --dst 172.31.11.1 --dport 9999 --count 20000 --size 1024
```

---

## 6. 环境搭建过程中解决的 6 个真实问题（都写进了脚本注释）

这部分本身就是很好的学习材料 —— 它们全是**真实的网络/容器工程坑**：

1. **docker 反欺骗规则拦截跨网桥转发**
   docker 为每个容器地址在宿主 nft 的 `ip raw` 表（优先级高于 NAT）插入
   `iifname != "<本网桥>" ip daddr <容器地址> drop`。
   它只放行同网桥直达的包，于是"经路由器转发"的包被静默丢弃：
   表现为 **ping 路由器通、ping 对面主机不通，且抓包什么都看不到**。
   没有任何官方开关可关，只能显式删除（`scripts/lib.sh: remove_antspoof`）。

2. **手工加的第二个 IP 会被 docker 顶掉**
   容器里手工 `ip addr add` 的地址不在 docker 台账里，docker 会为它插 DROP 规则。
   所以 server 的地址必须用 `docker run --ip` 指定的那个。

3. **`pkill -f udpecho` 会杀死自己**
   执行它的 shell 命令行里就含 `udpecho` 字样，于是父 shell 一起被杀，
   脚本"莫名中断、后面什么都不执行"。必须写 `pkill -f "[u]dpecho"`。

4. **`docker exec -i ... bash -s <<EOF` 会和外层 heredoc 抢 stdin**
   想送脚本进容器时，bash 从 stdin 读"要执行的脚本"，而脚本内容也在 stdin，
   两者互相抢：实测结果是脚本被当成命令执行、或被静默吞掉。
   **解法：把脚本 base64 当参数传**（`scripts/lib.sh: cs / cs_script`）。

5. **多层引号里的 `$!` 会被提前展开**
   `docker exec -d "$c" bash -c "... & echo \$! > pid"` 中 `$!` 展开时机不对，
   PID 文件写不出来、抓包静默失败。现在统一改成"先写启动脚本进容器，再执行"。

6. **`pkill -f tcpdump` 同理自杀**
   所以抓包改为写 PID 文件 + 按 PID 精确终止。

另外两个值得记一笔的：

- **`/proc/sys/net/ipv4/route/flush` 只读**：PMTU 缓存清不掉。
  解法是利用"PMTU 缓存**按目的地址**独立"这一特性，换一个没用过的目的地址来重现首次探测。
- **heredoc 里的 `PYEOF` 会提前结束文件**：`tools/udpecho.py` 当初就是这样被截断的，
  结果缺了 `if __name__ == "__main__"`，直接运行时什么都不做。写文件请用编辑器工具。

---

## 7. 建议的学习顺序

1. 先读第 11 章正文，建立概念；
2. 跑 `10` → `20`，把**首部**和**差错报文**这两件"看得见"的事先落实；
3. 跑 `30` → `40`，重点理解**分片是 IP 层的事**、以及 PMTUD 与 ICMP 的依赖关系；
4. 跑 `50`，把协议知识转成**排查能力**（记住那几个计数器名字）；
5. 跑 `60`，回到 UDP 的设计哲学：它把哪些责任推给了应用层；
6. 最后用 Wireshark 打开 `capture/*.pcap` 自己复看一遍，比读十遍书有用。

---

## 8. 常见问题

**Q：`00-setup.sh` 拉镜像失败？**
本实验只依赖 `docker` 和能拉取 Ubuntu 镜像的网络，与 dsh 的插件系统无关。

**Q：脚本报 `No such file or directory: /lab/run-xxx.sh`？**
说明容器里 `/lab` 或脚本生成失败，先确认容器在跑：`docker ps | grep udplab`。

**Q：抓包文件为空？**
脚本现在会把 tcpdump 自己的报错打出来。最常见原因是过滤表达式没匹配到流量。

**Q：想改拓扑（比如把窄链路改成 1200）？**
改 `scripts/lib.sh` 里的 `MTU_FAR`，然后 `REBUILD=0 bash scripts/00-setup.sh` 重跑即可。

**Q：宿主机还能正常上网吗？**
本实验只新增两条自定义 bridge 网络和三个容器，并删除 docker 为这些网段添加的
反欺骗规则（`172.31.x` 网段专用，不影响其他网络）。销毁环境用 `99-teardown.sh`。
