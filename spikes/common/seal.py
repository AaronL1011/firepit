#!/usr/bin/env python3
"""Seal the current process, then exec the fire.

Usage: seal.py [--connect PORT ...] WRITABLE_DIR [WRITABLE_DIR ...] -- COMMAND [ARGS ...]

Unprivileged, no user namespaces required:
  Landlock  read/execute anywhere, write only beneath WRITABLE_DIRs,
            TCP connect only to the --connect ports, no TCP bind,
            no signals or abstract unix sockets outside the pit.
  seccomp   socket(AF_UNIX) denied, so no host daemon (systemd, D-Bus,
            docker) can be asked to run work outside the pit. UDP, raw
            and packet sockets denied, because Landlock does not cover them.
"""

import ctypes
import os
import sys

SYS_LANDLOCK_CREATE_RULESET = 444
SYS_LANDLOCK_ADD_RULE = 445
SYS_LANDLOCK_RESTRICT_SELF = 446
LANDLOCK_CREATE_RULESET_VERSION = 1
LANDLOCK_RULE_PATH_BENEATH = 1
LANDLOCK_RULE_NET_PORT = 2
PR_SET_NO_NEW_PRIVS = 38

FS_EXECUTE = 1 << 0
FS_WRITE_FILE = 1 << 1
FS_READ_FILE = 1 << 2
FS_READ_DIR = 1 << 3
FS_ALL = (1 << 16) - 1  # every fs right up to IOCTL_DEV (ABI 5)
FS_READ_EXEC = FS_EXECUTE | FS_READ_FILE | FS_READ_DIR

NET_BIND_TCP = 1 << 0
NET_CONNECT_TCP = 1 << 1

SCOPE_ABSTRACT_UNIX_SOCKET = 1 << 0
SCOPE_SIGNAL = 1 << 1
MIN_ABI = 6

AF_UNIX = 1
AF_INET = 2
AF_INET6 = 10
AF_PACKET = 17
SOCK_DGRAM = 2
SOCK_RAW = 3
SOCK_TYPE_MASK = 0xF  # socket() type also carries SOCK_NONBLOCK / SOCK_CLOEXEC
SCMP_ACT_ALLOW = 0x7FFF0000
SCMP_ACT_ERRNO_EACCES = 0x00050000 | 13
SCMP_CMP_EQ = 4
SCMP_CMP_MASKED_EQ = 7

libc = ctypes.CDLL(None, use_errno=True)


class RulesetAttr(ctypes.Structure):
    _fields_ = [
        ("handled_access_fs", ctypes.c_uint64),
        ("handled_access_net", ctypes.c_uint64),
        ("scoped", ctypes.c_uint64),
    ]


class PathBeneathAttr(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("allowed_access", ctypes.c_uint64), ("parent_fd", ctypes.c_int32)]


class NetPortAttr(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("allowed_access", ctypes.c_uint64), ("port", ctypes.c_uint64)]


class ScmpArgCmp(ctypes.Structure):
    _fields_ = [
        ("arg", ctypes.c_uint),
        ("op", ctypes.c_int),
        ("datum_a", ctypes.c_uint64),
        ("datum_b", ctypes.c_uint64),
    ]


def fail(what: str) -> None:
    err = ctypes.get_errno()
    sys.exit(f"seal: {what} failed: {os.strerror(err)}")


def allow_beneath(ruleset_fd: int, path: str, access: int) -> None:
    fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    rule = PathBeneathAttr(access, fd)
    if libc.syscall(SYS_LANDLOCK_ADD_RULE, ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, ctypes.byref(rule), 0) != 0:
        fail(f"landlock_add_rule {path}")
    os.close(fd)


def allow_connect(ruleset_fd: int, port: int) -> None:
    rule = NetPortAttr(NET_CONNECT_TCP, port)
    if libc.syscall(SYS_LANDLOCK_ADD_RULE, ruleset_fd, LANDLOCK_RULE_NET_PORT, ctypes.byref(rule), 0) != 0:
        fail(f"landlock_add_rule port {port}")


def apply_landlock(writable: list[str], connect_ports: list[int]) -> None:
    abi = libc.syscall(SYS_LANDLOCK_CREATE_RULESET, None, 0, LANDLOCK_CREATE_RULESET_VERSION)
    if abi < MIN_ABI:
        sys.exit(f"seal: Landlock ABI {abi} < {MIN_ABI}; refusing to ignite unsealed")
    attr = RulesetAttr(FS_ALL, NET_BIND_TCP | NET_CONNECT_TCP, SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL)
    ruleset_fd = libc.syscall(SYS_LANDLOCK_CREATE_RULESET, ctypes.byref(attr), ctypes.sizeof(attr), 0)
    if ruleset_fd < 0:
        fail("landlock_create_ruleset")
    allow_beneath(ruleset_fd, "/", FS_READ_EXEC)
    allow_beneath(ruleset_fd, "/dev/null", FS_READ_FILE | FS_WRITE_FILE)
    for path in writable:
        allow_beneath(ruleset_fd, path, FS_ALL)
    for port in connect_ports:
        allow_connect(ruleset_fd, port)
    if libc.syscall(SYS_LANDLOCK_RESTRICT_SELF, ruleset_fd, 0) != 0:
        fail("landlock_restrict_self")


def deny_sockets() -> None:
    seccomp = ctypes.CDLL("libseccomp.so.2", use_errno=True)
    seccomp.seccomp_init.restype = ctypes.c_void_p
    ctx = ctypes.c_void_p(seccomp.seccomp_init(SCMP_ACT_ALLOW))
    socket_nr = seccomp.seccomp_syscall_resolve_name(b"socket")

    def deny(*cmps: ScmpArgCmp) -> None:
        array = (ScmpArgCmp * len(cmps))(*cmps)
        if seccomp.seccomp_rule_add_array(ctx, SCMP_ACT_ERRNO_EACCES, socket_nr, len(cmps), array) != 0:
            fail("seccomp_rule_add_array")

    deny(ScmpArgCmp(0, SCMP_CMP_EQ, AF_UNIX, 0))
    deny(ScmpArgCmp(0, SCMP_CMP_EQ, AF_PACKET, 0))
    for family in (AF_INET, AF_INET6):
        for sock_type in (SOCK_DGRAM, SOCK_RAW):
            deny(ScmpArgCmp(0, SCMP_CMP_EQ, family, 0), ScmpArgCmp(1, SCMP_CMP_MASKED_EQ, SOCK_TYPE_MASK, sock_type))
    if seccomp.seccomp_load(ctx) != 0:
        fail("seccomp_load")


def main() -> None:
    if "--" not in sys.argv:
        sys.exit(__doc__)
    split = sys.argv.index("--")
    options, command = sys.argv[1:split], sys.argv[split + 1 :]
    connect_ports: list[int] = []
    writable: list[str] = []
    while options:
        arg = options.pop(0)
        if arg == "--connect":
            connect_ports.append(int(options.pop(0)))
        else:
            writable.append(arg)
    if not command:
        sys.exit(__doc__)
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        fail("prctl(NO_NEW_PRIVS)")
    apply_landlock(writable, connect_ports)
    deny_sockets()
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
