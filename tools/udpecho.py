#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
udpecho.py —— UDP 回显服务 / 客户端（在容器内运行）

  server   监听并把每个数据报原样回显（打印收到的序号）
  client   发 N 个带序号的报文，统计【哪些序号没有回来】

用法：
  python3 udpecho.py server --port 9999 --timeout 40
  python3 udpecho.py client --dst 172.31.11.1 --port 9999 --count 10 --delay 0.2
"""

import argparse
import socket
import sys
import time

try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass


def server(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if args.rcvbuf:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
    s.bind((args.bind, args.port))
    s.settimeout(1.0)
    print(f"[server] UDP 回显已启动 {args.bind}:{args.port}  "
          f"(最长运行 {args.timeout}s)", flush=True)
    print(f"[server] SO_RCVBUF = "
          f"{s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)}", flush=True)
    t0 = time.time()
    n = 0
    while time.time() - t0 < args.timeout:
        try:
            data, addr = s.recvfrom(65535)
        except socket.timeout:
            continue
        n += 1
        txt = data.decode(errors="replace").strip()
        print(f"[server] #{n:<4} 收到 {len(data):>5} 字节 来自 {addr[0]}:{addr[1]}"
              f"  内容={txt[:40]!r}", flush=True)
        if not args.no_echo:
            try:
                s.sendto(data, addr)
            except OSError as e:
                print(f"[server] 回显失败: {e}", flush=True)
    print(f"[server] 结束，共收到 {n} 个数据报", flush=True)
    return 0


def client(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", args.sport))
    s.settimeout(args.timeout)
    seqs = list(range(1, args.count + 1))
    print(f"[client] 向 {args.dst}:{args.port} 连发 {args.count} 个报文，"
          f"间隔 {args.delay}s", flush=True)
    t0 = time.time()
    for i in seqs:
        msg = f"SEQ-{i:03d}|" + "D" * args.pad
        s.sendto(msg.encode(), (args.dst, args.port))
        print(f"[client] {time.time()-t0:7.3f}s  发出 SEQ-{i:03d} "
              f"({len(msg)} 字节)", flush=True)
        time.sleep(args.delay)

    print(f"[client] 等待回显 {args.wait}s ……", flush=True)
    got = set()
    deadline = time.time() + args.wait
    while time.time() < deadline:
        try:
            data, addr = s.recvfrom(65535)
        except socket.timeout:
            break
        txt = data.decode(errors="replace")
        try:
            seq = int(txt.split("|")[0].split("-")[1])
            got.add(seq)
        except Exception:
            pass
        print(f"[client] {time.time()-t0:7.3f}s  收到回显 "
              f"{txt.split('|')[0]}  共 {len(got)}/{args.count}", flush=True)
    s.close()

    lost = [i for i in seqs if i not in got]
    print()
    print(f"[client] ==== 结果 ====", flush=True)
    print(f"[client] 发出 {len(seqs)} 个，收到 {len(got)} 个，丢失 {len(lost)} 个",
          flush=True)
    if lost:
        print(f"[client] 丢失的序号: {lost}", flush=True)
        print("[client] ★ 这些序号就是真的丢了：UDP 不会重传，"
              "应用必须自己超时重发", flush=True)
    else:
        print("[client] 本次没有丢包（可加大 --count 或降低 --delay 再试）",
              flush=True)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("server")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--rcvbuf", type=int, default=0)
    p.add_argument("--no-echo", action="store_true")
    p.set_defaults(func=server)

    p = sub.add_parser("client")
    p.add_argument("--dst", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--sport", type=int, default=0)
    p.add_argument("--count", type=int, default=10)
    p.add_argument("--delay", type=float, default=0.2)
    p.add_argument("--wait", type=float, default=3.0)
    p.add_argument("--timeout", type=float, default=1.0)
    p.add_argument("--pad", type=int, default=0)
    p.set_defaults(func=client)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
