#!/usr/bin/env python3
"""The host side of the namespace spike: everything the fire might try to reach.

Usage: host.py LOG_DIR DEST_PORT ATTACKER_PORT HOST_IP ABSTRACT_NAME AGENT_SOCKET UNDECLARED_SOCKET

Each listener logs every line it receives to LOG_DIR/<name>.log, so the
harness judges each route by what actually arrived.
"""

import os
import socket
import sys
import threading
from pathlib import Path

LOGS = Path(sys.argv[1])


def record(name: str, data: bytes) -> None:
    with (LOGS / f"{name}.log").open("ab") as f:
        f.write(data if data.endswith(b"\n") else data + b"\n")


def serve_stream(listener: socket.socket, name: str, echo: bool) -> None:
    listener.listen()
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=handle, args=(conn, name, echo), daemon=True).start()


def handle(conn: socket.socket, name: str, echo: bool) -> None:
    with conn, conn.makefile("rwb") as stream:
        for line in stream:
            record(name, line)
            if echo:
                stream.write(line)
                stream.flush()


def tcp(host: str, port: int) -> socket.socket:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    return s


def unix(address: str) -> socket.socket:
    s = socket.socket(socket.AF_UNIX)
    s.bind(address)
    return s


def serve_udp(host: str, port: int, name: str) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((host, port))
    while True:
        record(name, s.recvfrom(4096)[0])


def main() -> None:
    dport, aport = int(sys.argv[2]), int(sys.argv[3])
    host_ip, abstract, agent, undeclared = sys.argv[4:8]
    streams = [
        (tcp("127.0.0.1", dport), "dest", True),
        (tcp("127.0.0.2", aport), "attacker", False),
        (unix("\0" + abstract), "abstract", False),
        (unix(agent), "agent", True),
        (unix(undeclared), "undeclared", False),
    ]
    if host_ip:
        streams.append((tcp(host_ip, aport), "attacker", False))
    for listener, name, echo in streams:
        threading.Thread(target=serve_stream, args=(listener, name, echo), daemon=True).start()
    threading.Thread(target=serve_udp, args=("127.0.0.1", dport, "udp"), daemon=True).start()
    print("ready", flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    os.umask(0o077)
    main()
