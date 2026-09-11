#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
probe.py —— UDP 行为对比探针（在容器内运行）

包含两个实验：
  boundary   报文边界：UDP 保留边界 vs TCP 是字节流
  reliability UDP 无重传 / TCP 有重传（配合宿主机上的 iptables 丢包）

用法：
  python3 probe.py boundary    --host 172.31.11.1 --sport 9997 --tcpport 8081
  python3 probe.py reliability --host 172.31.11.1 --udpport 9999 --tcpport 8080 \
                               --count 10 --delay 0.3
"""

import argparse
import socket
import sys
import time

try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass


def boundary(args):
    """报文边界实验：发送方一次 send，接收方一次 recv 会拿到多少。"""
    host = args.host
    print("=" * 72)
    print("实验 A：UDP 保留报文边界，TCP 是字节流")
    print("=" * 72)

    # ---------------- UDP ----------------
    print()
    print("【UDP】连续 3 次 sendto：5 字节、3 字节、2000 字节")
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(("0.0.0.0", args.sport))
    time.sleep(0.3)
    for payload in (b"AAAAA", b"BBB", b"C" * 2000):
        u.sendto(payload, (host, args.udpport))
        print(f"  sendto {len(payload):>5} 字节")
    print()
    print("  接收方每次 recvfrom（缓冲区 2048 字节）：")
    time.sleep(0.2)
    u.setblocking(False)
    got = 0
    t0 = time.time()
    while time.time() - t0 < 3 and got < 3:
        try:
            data, addr = u.recvfrom(2048)
        except BlockingIOError:
            time.sleep(0.05)
            continue
        got += 1
        print(f"    #{got} len={len(data):>5}  head={data[:8]!r}")
    u.close()
    print()
    print("  ★ 结论：3 次 send 对应 3 次 recv，长度分别是 5 / 3 / 2000。")
    print("    UDP 一个数据报就是一个完整的应用消息，界面清晰。")
    print("    如果接收缓冲区给得比数据报小（例如 100 字节），")
    print("    多余部分会被【截断丢弃】，而且不会告诉你丢了 —— 见 python 的")
    print("    recvfrom(bufsize) 行为。")

    # ---------------- TCP ----------------
    print()
    print("【TCP】同样连续 3 次 send：5 字节、3 字节、2000 字节")
    t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        t.connect((host, args.tcpport))
    except OSError as e:
        print(f"  TCP 连接失败: {e}（检查 server 上是否开了 nc -l -p {args.tcpport}）")
        return 0
    for payload in (b"AAAAA", b"BBB", b"C" * 2000):
        t.sendall(payload)
        print(f"  send {len(payload):>5} 字节")
    print()
    print("  接收方按 100 字节一块读取，看能不能还原消息边界：")
    time.sleep(0.2)
    t.settimeout(3)
    total = 0
    try:
        while total < 2008:
            chunk = t.recv(100)
            if not chunk:
                break
            total += len(chunk)
            if total <= 300 or total % 500 < 100:
                print(f"    recv(100) -> {len(chunk):>3} 字节  (累计 {total})")
    except socket.timeout:
        pass
    t.close()
    print()
    print("  ★ 结论：TCP 把数据当成连续的字节流，recv 的边界和 send 的边界")
    print("    【没有任何对应关系】：可能粘在一起，也可能被切开。")
    print("    所以基于 TCP 的协议必须自己定义“消息边界”：")
    print("      定长消息 / 长度前缀 / 分隔符（HTTP 用 Content-Length 或 chunked）")
    return 0


def reliability(args):
    """可靠性实验：UDP 丢了就没了，TCP 会重传。"""
    print("=" * 72)
    print("实验 B：UDP 无重传 vs TCP 有重传（需在路由器上对目的端口丢包）")
    print("=" * 72)
    n = args.count
    seq_len = 32

    # ---- UDP ----
    print()
    print(f"【UDP】发送 {n} 个带序号的报文，间隔 {args.delay}s（每个报文独立）")
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for i in range(1, n + 1):
        msg = f"UDP-SEQ-{i:03d}".ljust(seq_len, ".")
        u.sendto(msg.encode(), (args.host, args.udpport))
        print(f"  发出 {msg.strip('.')}")
        time.sleep(args.delay)
    u.close()
    print()
    print("  ★ 结论：sendto 返回成功只代表【内核接受了】，不代表对端收到。")
    print("    UDP 没有确认、没有重传、没有序号 —— 丢了的报文就永远消失了。")
    print("    所以 TFTP/DNS 这类协议必须在应用层自己做超时 + 重传 + 去重。")

    # ---- TCP ----
    print()
    print(f"【TCP】发送 {n} 行文本，间隔 {args.delay}s（内核负责可靠投递）")
    try:
        t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        t.connect((args.host, args.tcpport))
    except OSError as e:
        print(f"  TCP 连接失败: {e}")
        return 0
    t0 = time.time()
    for i in range(1, n + 1):
        line = f"TCP-SEQ-{i:03d}\n"
        try:
            t.sendall(line.encode())
        except OSError as e:
            print(f"  send 失败: {e}")
            break
        print(f"  发出 {line.strip()}   (t={time.time()-t0:.2f}s)")
        time.sleep(args.delay)
    t.close()
    print()
    print("  ★ 结论：即使中间有丢包，TCP 也会重传，序号保证顺序和完整。")
    print("    观察 server 端日志：TCP 的行数应该齐全（可能晚到）；")
    print("    UDP 的序号很可能出现空缺 —— 那就是真的丢了。")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("boundary")
    p.add_argument("--host", required=True)
    p.add_argument("--sport", type=int, default=9997)
    p.add_argument("--udpport", type=int, default=9999)
    p.add_argument("--tcpport", type=int, default=8081)
    p.set_defaults(func=boundary)

    p = sub.add_parser("reliability")
    p.add_argument("--host", required=True)
    p.add_argument("--udpport", type=int, default=9999)
    p.add_argument("--tcpport", type=int, default=8080)
    p.add_argument("--count", type=int, default=10)
    p.add_argument("--delay", type=float, default=0.3)
    p.set_defaults(func=reliability)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
