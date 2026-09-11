#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
udplab.py —— UDP 实验工具箱（在容器内运行）

它做的是"手工"活：把 UDP 首部一个字节一个字节地摆出来、
自己算伪首部校验和、自己构造报文、自己解码收到的 ICMP 差错。

子命令：
  csum      手算并核对 UDP 校验和（含伪首部）—— 对应课本最常考的计算题
  dump      发一个 UDP 包，用 AF_PACKET 抓下内核真正发出的字节流并逐字段解析
  sendraw   自己拼 IP 首部 + UDP 首部发送（可控 DF 位、校验和、片偏移）
  send      用普通 socket 发 UDP（--df 控制是否置 DF 位）
  recv      收 UDP 并打印来源、长度、内容（看报文边界）
  icmpwatch 监听并解码 ICMP 差错报文（验证"差错来自 IP 层"）
  flood     高速灌包（制造接收缓冲区溢出，观察统计计数器）

用法示例：
  python3 udplab.py csum
  python3 udplab.py dump    --dport 9999 --payload 32
  python3 udplab.py send    --dst 172.31.11.1 --dport 9999 --size 2000 --df 0
  python3 udplab.py recv    --port 9999 --count 5 --rcvbuf 8192
"""

import argparse
import os
import socket
import struct
import sys
import time

# ---------------------------------------------------------------- 常量 ----
IPPROTO_UDP_NUM = 17
AF_PACKET = getattr(socket, "AF_PACKET", 17)

# Python 的 socket 模块在部分版本/平台上并不导出这两个常量，
# 但它们在 Linux 上一直是这几个数值，所以做一次兜底。
# 这正是"手工实验"的价值：常量找不到时，可以直接查内核头文件确认。
_SOL_IP = socket.IPPROTO_IP
IP_MTU_DISCOVER = getattr(socket, "IP_MTU_DISCOVER", 10)
IP_PMTUDISC_DONT = getattr(socket, "IP_PMTUDISC_DONT", 0)
IP_PMTUDISC_DO = getattr(socket, "IP_PMTUDISC_DO", 2)
IP_PMTUDISC_PROBE = getattr(socket, "IP_PMTUDISC_PROBE", 3)
IP_MTU = getattr(socket, "IP_MTU", 14)

# 让 print 立刻输出，便于在日志里按时间顺序观察
try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass


# ============================================================ 校验和核心 ===
def ones_complement_sum(data: bytes) -> int:
    """1 的补码（反码）求和：每 16 位相加，进位回卷加到最低位。"""
    if len(data) % 2:
        data += b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    while total >> 16:                      # end-around carry
        total = (total & 0xFFFF) + (total >> 16)
    return total & 0xFFFF


def udp_checksum(src_ip: str, dst_ip: str, udp_segment: bytes,
                 protocol: int = IPPROTO_UDP_NUM) -> int:
    """
    计算 UDP 校验和。

    注意这里的"伪首部"（pseudo-header）：
        +--------+--------+--------+--------+
        |          源 IP 地址 (32位)         |
        +--------+--------+--------+--------+
        |        目的 IP 地址 (32位)         |
        +--------+--------+--------+--------+
        |  零    | 协议号 |    UDP 长度      |
        +--------+--------+--------+--------+
    伪首部只参与计算，不会被真正发到线路上。
    它存在的意义：IP 层不校验自己的载荷，把地址纳入校验后，
    地址被损坏时接收方能发现（否则报文可能被投递到错误主机）。
    """
    pseudo = struct.pack("!4s4sBBH",
                         socket.inet_aton(src_ip),
                         socket.inet_aton(dst_ip),
                         0,
                         protocol,
                         len(udp_segment))
    total = ones_complement_sum(pseudo + udp_segment)
    csum = (~total) & 0xFFFF
    # IPv4 下 UDP 校验和算出 0 要写成 0xFFFF：
    # 因为 0 有特殊含义（表示发送方没有计算校验和）
    return csum if csum != 0 else 0xFFFF


def build_udp(src_ip, dst_ip, sport, dport, payload: bytes,
              checksum: bool = True, bad_checksum: bool = False) -> bytes:
    """构造一个完整的 UDP 报文（不含 IP 首部）。"""
    length = 8 + len(payload)
    hdr_zero = struct.pack("!HHHH", sport, dport, length, 0)
    if not checksum:
        csum = 0
    else:
        csum = udp_checksum(src_ip, dst_ip, hdr_zero + payload)
        if bad_checksum:
            csum ^= 0xFFFF          # 故意写错，用来验证接收方会丢弃
    return struct.pack("!HHHH", sport, dport, length, csum) + payload


def build_ip(src_ip, dst_ip, payload: bytes, df: bool = True,
             proto: int = IPPROTO_UDP_NUM, frag_off: int = 0,
             ident: int = 0x1234, ttl: int = 64) -> bytes:
    """构造 IPv4 首部（20 字节，无选项）。frag_off 单位是 8 字节。"""
    total_len = 20 + len(payload)
    flags_off = (frag_off // 8) & 0x1FFF
    if df:
        flags_off |= 0x4000         # DF = Don't Fragment
    ver_ihl = (4 << 4) | 5
    hdr = struct.pack("!BBHHHBBH4s4s",
                      ver_ihl, 0, total_len, ident, flags_off,
                      ttl, proto, 0,
                      socket.inet_aton(src_ip), socket.inet_aton(dst_ip))
    c = (~ones_complement_sum(hdr)) & 0xFFFF
    hdr = hdr[:10] + struct.pack("!H", c) + hdr[12:]
    return hdr + payload


# ============================================================ 子命令实现 ===
def cmd_csum(args):
    """手算 UDP 校验和，并把每一步打印出来。"""
    src = args.src
    dst = args.dst
    payload = args.payload.encode() if args.payload else bytes(range(0x41, 0x47))
    sport, dport = args.sport, args.dport
    length = 8 + len(payload)

    print("=" * 72)
    print("UDP 校验和手工计算演示")
    print("=" * 72)
    print(f"源 IP      : {src}  = {socket.inet_aton(src).hex().upper()}")
    print(f"目的 IP    : {dst}  = {socket.inet_aton(dst).hex().upper()}")
    print(f"协议号     : {IPPROTO_UDP_NUM} (UDP)")
    print(f"UDP 长度   : {length}  = 8(首部) + {len(payload)}(数据)")
    print(f"源端口     : {sport}  = 0x{sport:04X}")
    print(f"目的端口   : {dport}  = 0x{dport:04X}")
    print(f"数据       : {payload.hex(' ').upper()}")
    print()

    pseudo = struct.pack("!4s4sBBH", socket.inet_aton(src),
                         socket.inet_aton(dst), 0, IPPROTO_UDP_NUM, length)
    seg_zero = struct.pack("!HHHH", sport, dport, length, 0) + payload

    print("--- 伪首部（12 字节，只参与计算，不会上线）---")
    print(f"  原始字节: {pseudo.hex(' ').upper()}")
    words = struct.unpack("!6H", pseudo)
    labels = ["源IP高16", "源IP低16", "目的IP高16", "目的IP低16", "零+协议", "UDP长度"]
    for lab, w in zip(labels, words):
        print(f"  {lab:<12} 0x{w:04X}")
    print()

    print("--- UDP 首部（校验和字段先置 0）---")
    print(f"  原始字节: {seg_zero[:8].hex(' ').upper()}")
    print(f"  源端口=0x{sport:04X}  目的端口=0x{dport:04X}  "
          f"长度=0x{length:04X}  校验和=0x0000")
    print()

    print("--- 逐项相加（1 的补码加法，进位回卷）---")
    allw = struct.unpack("!%dH" % (len(pseudo + seg_zero) // 2),
                         pseudo + seg_zero)
    acc = 0
    for w in allw:
        acc += w
        while acc >> 16:
            acc = (acc & 0xFFFF) + (acc >> 16)
        print(f"  + 0x{w:04X}  ->  0x{acc:04X}")
    print()
    print(f"  求和结果            : 0x{acc:04X}")
    print(f"  取反（~acc & 0xFFFF）: 0x{(~acc) & 0xFFFF:04X}   <- 写入校验和字段")
    print()

    final = udp_checksum(src, dst, seg_zero)
    print(f"--- 验证 ---")
    print(f"  函数算出的校验和    : 0x{final:04X}")
    # 验证方法：把【已填好校验和】的报文再按 1 的补码求和，结果应为 0xFFFF。
    # 注意：有些教材写"结果为 0"，那是先把和取反再判断的写法；
    #       本实现不取反，所以正确值是 0xFFFF。两种写法等价，别被绕晕。
    seg_final = struct.pack("!HHHH", sport, dport, length, final) + payload
    verify = ones_complement_sum(pseudo + seg_final)
    print(f"  接收方重算(含校验和): 0x{verify:04X}  (期望 0xFFFF)")
    print(f"  若再取反得到        : 0x{(~verify) & 0xFFFF:04X}  (期望 0x0000)")
    print(f"  结论: {'校验和正确，接收方会接受' if verify == 0xFFFF else '校验和错误'}")
    print()
    print("★ 记住三点：")
    print("  1) 覆盖范围 = 伪首部 + UDP首部 + 数据；IP 首部本身不参与")
    print("  2) IPv4 中校验和可选（填 0 = 没算），IPv6 中强制")
    print("  3) 算出 0 要发 0xFFFF，因为 0 表示'未计算'")


def cmd_dump(args):
    """
    用 AF_PACKET 在发出前抓下内核生成的字节流，逐字段解析。
    这是"看见课本上那张首部图"的最直接方式。
    """
    sport = args.sport
    dport = args.dport
    payload = (args.payload.encode() if isinstance(args.payload, str)
               else args.payload) or b"HELLO-UDP"
    local_ip = args.src

    print("=" * 72)
    print("UDP 首部逐字段解析（抓的是内核真正发出的字节）")
    print("=" * 72)

    sock = socket.socket(AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    sock.bind(("eth0", 0))
    sock.settimeout(3)

    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx.bind((local_ip, sport))
    print(f"$ send {local_ip}:{sport} -> {args.dst}:{dport}  "
          f"payload={len(payload)} 字节")
    tx.sendto(payload, (args.dst, dport))

    frame = None
    deadline = time.time() + 3
    while time.time() < deadline:
        try:
            data = sock.recv(65535)
        except socket.timeout:
            break
        # 跳过以太网头，找 IPv4
        if len(data) > 34 and data[12:14] == b"\x08\x00":
            ip = data[14:]
            if ip[9] == IPPROTO_UDP_NUM and ip[16:20] == socket.inet_aton(args.dst):
                frame = ip
                break
    sock.close()
    tx.close()

    if frame is None:
        print("未抓到（可能被容器网络过滤），跳过")
        return 1

    ihl = (frame[0] & 0x0F) * 4
    total_len = struct.unpack("!H", frame[2:4])[0]
    ident, flags_off = struct.unpack("!HH", frame[4:8])
    df = bool(flags_off & 0x4000)
    mf = bool(flags_off & 0x2000)
    ttl = frame[8]
    ip_csum = struct.unpack("!H", frame[10:12])[0]
    udp = frame[ihl:total_len]

    print()
    print("--- IP 首部（%d 字节）---" % ihl)
    print(f"  版本/IHL      : {frame[0] >> 4} / {ihl//4}  ({ihl} 字节)")
    print(f"  总长度        : {total_len}")
    print(f"  标识          : 0x{ident:04X}")
    print(f"  DF / MF       : DF={int(df)}  MF={int(mf)}   <- DF=1 表示禁止分片")
    print(f"  片偏移        : {(flags_off & 0x1FFF) * 8} 字节")
    print(f"  TTL           : {ttl}")
    print(f"  协议          : {frame[9]}  (17=UDP)  <- 伪首部里也用到这个值")
    print(f"  首部校验和    : 0x{ip_csum:04X}")
    print(f"  源 IP         : {socket.inet_ntoa(frame[12:16])}")
    print(f"  目的 IP       : {socket.inet_ntoa(frame[16:20])}")

    usport, udport, ulen, ucsum = struct.unpack("!HHHH", udp[:8])
    print()
    print("--- UDP 首部（固定 8 字节）---")
    print(f"  字节 0-1  源端口   : {usport:<6} (0x{usport:04X})")
    print(f"  字节 2-3  目的端口 : {udport:<6} (0x{udport:04X})")
    print(f"  字节 4-5  UDP长度  : {ulen:<6} (0x{ulen:04X})"
          f"   = 8 + {ulen-8} 字节数据")
    print(f"  字节 6-7  校验和   : 0x{ucsum:04X}")
    print()
    print("  首部原始字节 (hex) : " + udp[:8].hex(" ").upper())
    print("  首部原始字节 (bin) :")
    for i in range(8):
        print(f"    byte[{i}] = 0x{udp[i]:02X} = 0b{udp[i]:08b}")
    print()
    print("--- 点划线示意（对应课本 Figure 11.2）---")
    print("   0      7 8     15 16    23 24    31")
    print("  +--------+--------+--------+--------+")
    print(f"  |   源端口 {usport:<5}|  目的端口 {udport:<4}|")
    print("  +--------+--------+--------+--------+")
    print(f"  |  UDP长度 {ulen:<5}|  校验和 0x{ucsum:04X}|")
    print("  +--------+--------+--------+--------+")
    print(f"  |            数据（{ulen-8} 字节）            |")
    print("  +-----------------------------------+")

    print()
    print("--- 校验和核对 ---")
    seg = udp[:ulen]
    calc = udp_checksum(args.src, args.dst, seg)
    print(f"  报文里的校验和: 0x{ucsum:04X}")
    print(f"  本地重算      : 0x{calc:04X}")
    print(f"  结论: {'一致 ✅' if calc == ucsum else '不一致 ❌ (可能被网卡卸载改了)'}")
    print()
    print(f"--- 数据部分（hex + ASCII）---")
    data = udp[8:ulen]
    print("  " + data.hex(" ").upper())
    print("  " + "".join(chr(b) if 32 <= b < 127 else "." for b in data))
    return 0


def cmd_send(args):
    """普通 socket 发 UDP，用 IP_MTU_DISCOVER 控制 DF 位。"""
    payload = bytes([0x41 + (i % 26) for i in range(args.size)])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.src:
        s.bind((args.src, args.sport))
    val = IP_PMTUDISC_DO if args.df else IP_PMTUDISC_DONT
    try:
        s.setsockopt(_SOL_IP, IP_MTU_DISCOVER, val)
        print(f"(已设置 IP_MTU_DISCOVER={val}: "
              f"{'DF=1 禁止分片' if args.df else 'DF=0 允许分片'})")
    except OSError as e:
        print(f"(警告: 无法设置 IP_MTU_DISCOVER: {e})")
    if args.pmtudisc_probe:
        try:
            s.setsockopt(_SOL_IP, IP_MTU_DISCOVER, IP_PMTUDISC_PROBE)
            print("(已启用 IP_PMTUDISC_PROBE: 按已知PMTU设DF，用于探测)")
        except OSError:
            pass

    # 查一下内核认定的到该目的地的 MTU（PMTU 缓存的体现）
    try:
        s.connect((args.dst, args.dport))
        print(f"内核认定的路径 MTU = {s.getsockopt(_SOL_IP, IP_MTU)}")
        s.connect(("0.0.0.0", 0))     # 解除连接，保持"未连接"语义
    except OSError:
        pass

    udp_len = 8 + args.size
    ip_len = 20 + udp_len
    print(f"发送: payload={args.size}  UDP总长={udp_len}  IP总长={ip_len}  "
          f"DF={'1 (禁止分片)' if args.df else '0 (允许分片)'}")
    try:
        n = s.sendto(payload, (args.dst, args.dport))
        print(f"sendto() 成功，返回 {n}")
    except OSError as e:
        print(f"sendto() 失败: [{e.errno}] {e.strerror}  <- "
              f"EMSGSIZE(90) 说明本地出口 MTU 不够")
    finally:
        s.close()
    return 0


def cmd_sendraw(args):
    """自己拼 IP+UDP 发送，完全控制 DF/校验和/片偏移。"""
    payload = bytes([0x61 + (i % 26) for i in range(args.size)])
    sport = args.sport
    dport = args.dport
    udp_seg = build_udp(args.src, args.dst, sport, dport, payload,
                        checksum=(not args.no_checksum),
                        bad_checksum=args.bad_checksum)
    ip_pkt = build_ip(args.src, args.dst, udp_seg, df=bool(args.df),
                      frag_off=args.frag_off, ident=args.ident)
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
    print(f"RAW 发送: {args.src}:{sport} -> {args.dst}:{dport}")
    print(f"  payload={args.size}  UDP总长={8+args.size}  "
          f"IP总长={20+8+args.size}")
    print(f"  DF={args.df}  片偏移={args.frag_off}字节  标识=0x{args.ident:04X}")
    if args.no_checksum:
        print("  UDP 校验和: 0x0000  <- 表示“发送方未计算”（IPv4 允许）")
    elif args.bad_checksum:
        print("  UDP 校验和: 故意写错 (与正确值相差 0xFFFF)")
    else:
        csum = struct.unpack("!H", udp_seg[6:8])[0]
        print(f"  UDP 校验和: 0x{csum:04X}  <- 含伪首部计算得出")
    print(f"  IP 首部 hex: {ip_pkt[:20].hex(' ').upper()}")
    print(f"  UDP 首部 hex: {udp_seg[:8].hex(' ').upper()}")
    try:
        s.sendto(ip_pkt, (args.dst, 0))
        print("  已发出")
    except OSError as e:
        print(f"  发送失败: {e}")
    finally:
        s.close()
    return 0


def cmd_recv(args):
    """接收并打印每个数据报，用来观察报文边界与缓冲区。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.rcvbuf:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
        got = s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        print(f"SO_RCVBUF 请求 {args.rcvbuf} -> 内核实际给 {got} "
              f"(内核会翻倍并做下限约束)")
    s.bind((args.bind, args.port))
    print(f"监听 UDP {args.bind}:{args.port}  期望 {args.count} 个报文"
          f"  接收缓冲区 {args.bufsize} 字节")
    print("-" * 72)
    got = 0
    t0 = time.time()
    s.settimeout(args.timeout)
    while got < args.count:
        try:
            data, addr = s.recvfrom(args.bufsize)
        except socket.timeout:
            print(f"[{time.time()-t0:8.3f}s] 超时，未再收到数据"
                  f"（已收 {got}/{args.count}）")
            break
        got += 1
        head = data[:args.show].hex(" ").upper()
        tail = " ..." if len(data) > args.show else ""
        print(f"[{time.time()-t0:8.3f}s] #{got:<4} 来自 {addr[0]}:{addr[1]}  "
              f"长度={len(data):<6} 数据={head}{tail}")
    print("-" * 72)
    print(f"共收到 {got} 个报文，耗时 {time.time()-t0:.3f}s")
    print("★ 注意：每次 recvfrom 的上限正好是发送方一次 sendto 的大小，")
    print("  UDP 保留报文边界，不会合并也不会切分（TCP 是字节流，会粘包）。")
    return 0


def cmd_icmpwatch(args):
    """
    直接在 client 上监听 ICMP，解码差错报文。
    用来证明：ICMP 差错是 IP 层产生的，里面带着原报文的前 8 字节（即 UDP 首部）。
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    s.settimeout(args.timeout)
    types = {0: "Echo Reply", 3: "Destination Unreachable", 4: "Source Quench",
             5: "Redirect", 11: "Time Exceeded", 12: "Parameter Problem"}
    codes3 = {0: "net unreachable", 1: "host unreachable",
              2: "protocol unreachable", 3: "PORT UNREACHABLE",
              4: "FRAGMENTATION NEEDED (DF set)", 5: "source route failed"}
    print(f"监听 ICMP {args.timeout}s ……")
    print("-" * 72)
    n = 0
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        try:
            data, addr = s.recvfrom(65535)
        except socket.timeout:
            break
        iph = data[0]
        ihl = (iph & 0x0F) * 4
        icmp = data[ihl:]
        if len(icmp) < 8:
            continue
        t, c = icmp[0], icmp[1]
        n += 1
        print(f"#{n} 来自 {addr[0]}  ICMP type={t} code={c} "
              f"({types.get(t,'?')})")
        if t == 3:
            print(f"     code 含义: {codes3.get(c, '?')}")
        if t == 3 and c == 4:
            nhm = struct.unpack("!H", icmp[6:8])[0]
            print(f"     ★ Next-Hop MTU = {nhm}   <- 路由器告诉我可用的 MTU")
        # 差错报文里嵌着"惹祸的那个包"
        inner = icmp[8:]
        if len(inner) >= 20:
            ii = (inner[0] & 0x0F) * 4
            total = struct.unpack("!H", inner[2:4])[0]
            ident, fo = struct.unpack("!HH", inner[4:8])
            proto = inner[9]
            src = socket.inet_ntoa(inner[12:16])
            dst = socket.inet_ntoa(inner[16:20])
            print(f"     内嵌原包: {src} -> {dst}  proto={proto} "
                  f"总长={total} 标识=0x{ident:04X} "
                  f"DF={int(bool(fo & 0x4000))}")
            # 前 8 字节数据 = UDP 首部，用它才能把差错关联回某个 socket
            payload8 = inner[ii:ii + 8]
            if proto == IPPROTO_UDP_NUM and len(payload8) == 8:
                sp, dp, ln, cs = struct.unpack("!HHHH", payload8)
                print(f"     内嵌 UDP 首部(仅前8字节): 源端口={sp} "
                      f"目的端口={dp} 长度={ln} 校验和=0x{cs:04X}")
                print(f"     ★ 这就是为什么 ICMP 差错只带前 8 字节："
                      f"刚好够定位端口")
        print()
    if n == 0:
        print("没有收到 ICMP（可能被丢弃或未触发）")
    return 0


def cmd_flood(args):
    """高速灌包，制造接收缓冲区溢出。"""
    payload = b"X" * args.size
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.sndbuf:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, args.sndbuf)
    print(f"向 {args.dst}:{args.dport} 连发 {args.count} 个 "
          f"{args.size} 字节报文，间隔 {args.interval}s")
    sent = 0
    t0 = time.time()
    for i in range(args.count):
        try:
            s.sendto(payload, (args.dst, args.dport))
            sent += 1
        except OSError as e:
            print(f"  第 {i} 个失败: {e}")
            break
        if args.interval:
            time.sleep(args.interval)
    dt = time.time() - t0
    print(f"已发送 {sent} 个（{sent*len(payload)} 字节），耗时 {dt:.3f}s，"
          f"约 {sent/dt:.0f} 包/秒")
    s.close()
    return 0


# ================================================================ 入口 ====
def main():
    ap = argparse.ArgumentParser(description="UDP 实验工具箱")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("csum", help="手算 UDP 校验和（含伪首部）")
    p.add_argument("--src", default="172.31.10.10")
    p.add_argument("--dst", default="172.31.11.1")
    p.add_argument("--sport", type=int, default=0x1234)
    p.add_argument("--dport", type=int, default=0x5678)
    p.add_argument("--payload", default="ABCDEF")
    p.set_defaults(func=cmd_csum)

    p = sub.add_parser("dump", help="抓取内核发出的 UDP 包并逐字节解析")
    p.add_argument("--src", default="172.31.10.10")
    p.add_argument("--dst", default="172.31.11.1")
    p.add_argument("--sport", type=int, default=40000)
    p.add_argument("--dport", type=int, default=9999)
    p.add_argument("--payload", default="HELLO-UDP")
    p.set_defaults(func=cmd_dump)

    p = sub.add_parser("send", help="普通 socket 发 UDP（可控 DF）")
    p.add_argument("--src", default=None)
    p.add_argument("--dst", required=True)
    p.add_argument("--sport", type=int, default=0)
    p.add_argument("--dport", type=int, default=9999)
    p.add_argument("--size", type=int, default=100)
    p.add_argument("--df", type=int, default=1, help="1=置DF位 0=允许分片")
    p.add_argument("--pmtudisc-probe", action="store_true")
    p.set_defaults(func=cmd_send)

    p = sub.add_parser("sendraw", help="自拼 IP+UDP 发送（可控校验和）")
    p.add_argument("--src", required=True)
    p.add_argument("--dst", required=True)
    p.add_argument("--sport", type=int, default=40001)
    p.add_argument("--dport", type=int, default=9999)
    p.add_argument("--size", type=int, default=32)
    p.add_argument("--df", type=int, default=1)
    p.add_argument("--frag-off", type=int, default=0)
    p.add_argument("--ident", type=lambda x: int(x, 0), default=0x1234)
    p.add_argument("--no-checksum", action="store_true")
    p.add_argument("--bad-checksum", action="store_true")
    p.set_defaults(func=cmd_sendraw)

    p = sub.add_parser("recv", help="收 UDP 并打印边界")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--count", type=int, default=5)
    p.add_argument("--show", type=int, default=48)
    p.add_argument("--bufsize", type=int, default=2048)
    p.add_argument("--rcvbuf", type=int, default=0)
    p.add_argument("--timeout", type=float, default=5.0)
    p.set_defaults(func=cmd_recv)

    p = sub.add_parser("icmpwatch", help="解码 ICMP 差错报文")
    p.add_argument("--timeout", type=float, default=8.0)
    p.set_defaults(func=cmd_icmpwatch)

    p = sub.add_parser("flood", help="高速灌包")
    p.add_argument("--dst", required=True)
    p.add_argument("--dport", type=int, required=True)
    p.add_argument("--count", type=int, default=5000)
    p.add_argument("--size", type=int, default=1024)
    p.add_argument("--interval", type=float, default=0.0)
    p.add_argument("--sndbuf", type=int, default=0)
    p.set_defaults(func=cmd_flood)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
