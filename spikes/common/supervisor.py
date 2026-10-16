#!/usr/bin/env python3
"""Supervisor: the main process of the pit's systemd service.

Usage: supervisor.py PIT_ID SMOKE_FILE CHIMNEY_LISTEN ALLOWED_DEST [--smoke-limit BYTES] -- FIRE_COMMAND ...

CHIMNEY_LISTEN is a TCP port on 127.0.0.1 or an absolute unix socket path.
The vessel decides how the fire is isolated; the supervisor only runs its
lifecycle. It starts the chimney, then the fire, then pings the systemd
watchdog until the fire exits. If the chimney dies, the supervisor exits and
the pit goes out with it. If the supervisor dies or stops pinging, systemd
kills every process in the unit.
"""

import os
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
WATCHDOG_INTERVAL = 0.5


def notify(message: str) -> None:
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        sys.exit("supervisor: no NOTIFY_SOCKET; refusing to run outside a watchdogged unit")
    if address.startswith("@"):
        address = "\0" + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.sendto(message.encode(), address)


def fire_env() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if k not in ("NOTIFY_SOCKET", "WATCHDOG_USEC", "WATCHDOG_PID")}


def smoke(path: str, event: str) -> None:
    with open(path, "a") as f:
        f.write(f"{datetime.now().isoformat(timespec='milliseconds')} vessel {event}\n")


def parse_args() -> tuple[list[str], str, list[str]]:
    if "--" not in sys.argv:
        sys.exit(__doc__)
    split = sys.argv.index("--")
    head, fire_cmd = sys.argv[1:split], sys.argv[split + 1 :]
    smoke_limit = ""
    if "--smoke-limit" in head:
        at = head.index("--smoke-limit")
        smoke_limit = head[at + 1]
        del head[at : at + 2]
    if len(head) != 4 or not fire_cmd:
        sys.exit(__doc__)
    return head, smoke_limit, fire_cmd


def main() -> None:
    (pit_id, smoke_path, listen, dest), smoke_limit, fire_cmd = parse_args()

    smoke(smoke_path, f"ignite pit={pit_id}")
    chimney_cmd = [sys.executable, str(HERE / "chimney.py"), smoke_path, listen, dest]
    if smoke_limit:
        chimney_cmd = ["prlimit", f"--fsize={smoke_limit}:{smoke_limit}", "--", *chimney_cmd]
    chimney = subprocess.Popen(chimney_cmd, stdout=subprocess.PIPE, text=True)
    if chimney.stdout is None or chimney.stdout.readline().strip() != "ready":
        sys.exit("supervisor: chimney failed to start; not lighting the fire")
    Path(smoke_path).with_name("chimney.pid").write_text(str(chimney.pid))

    fire = subprocess.Popen(fire_cmd, env={**fire_env(), "CHIMNEY": listen, "DEST": dest, "SMOKE": smoke_path})
    notify("READY=1")
    while True:
        if fire.poll() is not None:
            smoke(smoke_path, f"fire exited status={fire.returncode}")
            return
        # A dead chimney already cuts the network. Ending the pit puts the fire out too.
        if chimney.poll() is not None:
            smoke(smoke_path, f"chimney died status={chimney.returncode}; ending pit")
            sys.exit(1)
        notify("WATCHDOG=1")
        time.sleep(WATCHDOG_INTERVAL)


if __name__ == "__main__":
    main()
