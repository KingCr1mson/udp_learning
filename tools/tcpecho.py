#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tcpecho.py —— 极简 TCP 回显服务，用于和 UDP 做对照实验。"""
import argparse, socket, sys, time
try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass

ap = argparse.ArgumentParser()
ap.add_argument("--bind", default="0.0.0.0")
ap.add_argument("--port", type=int, required=True)
ap.add_argument("--timeout", type=float, default=40)
a = ap.parse_args()

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((a.bind, a.port))
srv.listen(4)
srv.settimeout(a.timeout)
print(f"[tcpecho] 监听 {a.bind}:{a.port}（最长 {a.timeout}s）", flush=True)
try:
    conn, addr = srv.accept()
except socket.timeout:
    print("[tcpecho] 没有连接，退出", flush=True)
    sys.exit(0)
print(f"[tcpecho] 连接来自 {addr[0]}:{addr[1]}", flush=True)
conn.settimeout(a.timeout)
t0 = time.time()
n = 0
try:
    while True:
        data = conn.recv(4096)
        if not data:
            break
        n += 1
        for line in data.decode(errors="replace").splitlines():
            print(f"[tcpecho] {time.time()-t0:7.3f}s  收到: {line}", flush=True)
        conn.sendall(data)
except socket.timeout:
    print("[tcpecho] 超时，关闭", flush=True)
except ConnectionResetError:
    print("[tcpecho] 对端重置连接（客户端正常关闭时也会出现，无害）", flush=True)
conn.close()
print(f"[tcpecho] 结束，共收到 {n} 次 recv", flush=True)
