#!/usr/bin/env python3
"""Chimney: the fire's only way out over the network.

Usage: chimney.py SMOKE_FILE LISTEN ALLOWED_DEST [ALLOWED_DEST ...]

LISTEN is a TCP port on 127.0.0.1, or an absolute path for a unix socket.
The fire connects to it and sends one line naming its destination (host:port). Every chunk in either direction is written to smoke
and fsynced before it is forwarded. If smoke cannot be written, the chimney
exits, which drops every connection: nothing crosses unrecorded.
"""

import os
import socket
import sys
import threading
from datetime import datetime

CHUNK = 4096
MAX_DEST_LINE = 256


class Smoke:
    def __init__(self, path: str) -> None:
        self.fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        self.lock = threading.Lock()

    def record(self, direction: str, dest: str, size: int, verdict: str) -> None:
        line = f"{datetime.now().isoformat(timespec='milliseconds')} {direction} chimney.net {dest} {size}B {verdict}\n"
        data = line.encode()
        try:
            with self.lock:
                written = os.write(self.fd, data)
                os.fsync(self.fd)
        except OSError as err:
            self.cut(err.strerror or "write error")
        # A short write leaves a partial record, which is no record at all.
        if written != len(data):
            self.cut(f"short write {written}/{len(data)} B")

    @staticmethod
    def cut(reason: str) -> None:
        print(f"chimney: smoke write failed ({reason}); cutting the chimney", file=sys.stderr, flush=True)
        os._exit(3)


def read_dest(conn: socket.socket) -> str:
    line = b""
    while not line.endswith(b"\n") and len(line) < MAX_DEST_LINE:
        byte = conn.recv(1)
        if not byte:
            return ""
        line += byte
    return line.decode(errors="replace").strip()


def pump(src: socket.socket, dst: socket.socket, smoke: Smoke, direction: str, dest: str) -> None:
    try:
        while chunk := src.recv(CHUNK):
            smoke.record(direction, dest, len(chunk), "allow")
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(conn: socket.socket, smoke: Smoke, allowed: set[str]) -> None:
    dest = read_dest(conn)
    if not dest:
        conn.close()
        return
    if dest not in allowed:
        smoke.record("out", dest, 0, "deny")
        conn.close()
        return
    host, port = dest.rsplit(":", 1)
    try:
        upstream = socket.create_connection((host, int(port)), timeout=2)
    except OSError:
        smoke.record("out", dest, 0, "unreachable")
        conn.close()
        return
    upstream.settimeout(None)
    threading.Thread(target=pump, args=(conn, upstream, smoke, "out", dest), daemon=True).start()
    pump(upstream, conn, smoke, "in", dest)


def listen(address: str) -> socket.socket:
    if address.startswith("/"):
        if os.path.exists(address):
            os.unlink(address)
        listener = socket.socket(socket.AF_UNIX)
        old_umask = os.umask(0o077)
        listener.bind(address)
        os.umask(old_umask)
    else:
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", int(address)))
    listener.listen()
    return listener


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    smoke = Smoke(sys.argv[1])
    listener = listen(sys.argv[2])
    allowed = set(sys.argv[3:])
    print("ready", flush=True)
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=serve, args=(conn, smoke, allowed), daemon=True).start()


if __name__ == "__main__":
    main()
