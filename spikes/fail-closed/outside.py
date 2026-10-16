#!/usr/bin/env python3
"""The world outside the pit, for the spike.

Usage: outside.py LOG_DIR DEST_PORT CHIMNEY_PORT

  127.0.0.1:DEST_PORT     TCP echo (the declared destination) and a UDP sink
  127.0.0.2:CHIMNEY_PORT  an attacker listening on the chimney's port number
Every line received is logged, so the harness can compare it with smoke.
"""

import socket
import sys
import threading
from pathlib import Path


def tcp(host: str, port: int, log: Path, echo: bool) -> None:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, port))
    listener.listen()
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=handle, args=(conn, log, echo), daemon=True).start()


def handle(conn: socket.socket, log: Path, echo: bool) -> None:
    with conn, conn.makefile("rwb") as stream:
        for line in stream:
            with log.open("ab") as f:
                f.write(line)
            if echo:
                stream.write(line)
                stream.flush()


def udp(host: str, port: int, log: Path) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((host, port))
    while True:
        data, _ = sock.recvfrom(4096)
        with log.open("ab") as f:
            f.write(data)


def main() -> None:
    logs, dport, cport = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    threading.Thread(target=tcp, args=("127.0.0.1", dport, logs / "echo.log", True), daemon=True).start()
    threading.Thread(target=udp, args=("127.0.0.1", dport, logs / "udp.log"), daemon=True).start()
    threading.Thread(target=tcp, args=("127.0.0.2", cport, logs / "attacker.log", False), daemon=True).start()
    print("ready", flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    main()
