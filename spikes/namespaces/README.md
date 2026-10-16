# Spike: namespaces

Question: once the one-time install grants user namespaces, does a network namespace close the port gap from the fail-closed spike? And do the kill switch and fail-closed results still hold?

Answer: **yes.** The agent's only route out is the egress proxy. Nothing else it tried reached the host, the LAN or the internet. The sandbox still stops on every failure, and there is now a second, independent layer that stops the agent when the supervisor dies.

## Run it

```
sudo bash ../common/install.sh   # once
bash run-spike.sh
```

Takes about 20 s and cleans up after itself. During the run, a listener that only logs is open on the host's LAN address, so the spike can check the agent cannot reach it.

## Design under test

Same systemd service, supervisor and egress proxy (`chimney.py`) as the fail-closed spike (`../common/`). Two things change:

- **The egress proxy is a unix socket** at `PIT_DIR/chimney.sock`, mounted into the sandbox at `/run/firepit/chimney.sock`.
- **The agent runs inside the installed `bwrap`** with new user, mount, network, pid, ipc, uts and cgroup namespaces. It also gets `--disable-userns`, so it cannot make namespaces of its own, `--die-with-parent`, `--new-session`, and `--clearenv`, so nothing is inherited. Its filesystem is: `/usr` and `/etc` read-only, the Python install and spike code read-only, tmpfs at `/tmp` and `/scratch`, the proxy socket, one declared host socket at `/run/firepit/agent.sock`, and a heartbeat dir for the harness.

Landlock and seccomp are not used in this runtime. The namespaces alone are under test.

`host.py` stands up everything the agent might try to reach and logs what actually arrives: the declared destination (TCP echo), a UDP sink, an attacker on `127.0.0.2` and on the LAN address, an abstract unix socket, the declared agent socket, and an undeclared unix socket.

## Results

Kernel 6.17, systemd 255, bubblewrap 0.9.0. Run twice with identical results.

**What the agent can reach**

| Route | Agent's view | Host received |
|---|---|---|
| Egress proxy (declared destination) | 15 ok | 15, with 15 log records |
| Attacker on `127.0.0.2` | refused | 0 (was 15/15 without namespaces) |
| Attacker on host LAN address | network unreachable | 0 |
| Public internet `1.1.1.1:443` | network unreachable | n/a |
| Declared destination directly | refused | 0 |
| UDP to declared destination | "sent" into its own loopback | 0 |
| DNS lookup | no resolver | n/a |
| Host abstract unix socket | refused | 0 |
| Declared host socket (`agent.sock`) | ok | 1 |
| Undeclared host socket | not found | 0 |
| User D-Bus, `docker.sock` | not found | n/a |
| `~/.ssh`, the sandbox's own audit log | not found | n/a |
| Write to `/etc` | read-only filesystem | n/a |
| Write to `/scratch` | ok (tmpfs, gone with the sandbox) | n/a |
| cgroup migration | cgroupfs not mounted | n/a |
| Create a user namespace | refused | n/a |
| Signal a host process | no such process | n/a |
| `systemd-run --user` | failed | n/a |

**Does it still stop**

| Failure | Result |
|---|---|
| Kill switch, supervisor frozen | stopped in 2 to 14 ms, nothing left |
| Supervisor `SIGKILL` | stopped in 19 to 20 ms, nothing left |
| Supervisor `SIGKILL` with systemd told to kill only the main process | agent still stopped, nothing left. The proxy kept running. |
| Egress proxy `SIGKILL` | network cut at once, agent stopped in 0.5 s |

## Findings

1. **The port gap is closed.** The agent's network namespace has only loopback. Its one way out is the proxy socket mounted into it, so the proxy really is the only route. Every crossing that arrived was in the audit log.
2. **Mounting decides what's visible, which also answers local sockets.** An undeclared socket is simply not there. Declaring a socket means mounting it in, and the agent socket worked with nothing else changed. The network namespace also isolates abstract sockets. So the protocol can allow declared local sockets, and the seccomp ban on every unix socket is no longer needed.
3. **Cleaning up the workspace comes free.** `/scratch` is a tmpfs in the sandbox's mount namespace, so it is gone when the sandbox is.
4. **There are now two independent fail-closed layers.** With systemd's kill switched off, the agent still died with the supervisor. `--die-with-parent` kills the namespace's init, and the kernel then kills everything in that PID namespace. A broken unit configuration no longer leaves the agent running.
5. **The egress proxy is not covered by the second layer.** It is the supervisor's child and runs outside `bwrap`. In the `KillMode=process` case it was orphaned. That is harmless with the agent already dead, but the reference runtime should rely on `KillMode=control-group` and keep the proxy tied to the supervisor.
6. **The kill switch is unchanged.** Namespaces live inside the cgroup, so `cgroup.kill` still stops the whole sandbox.
7. **The install is small.** One root-owned copy of `bwrap` and an eight-line AppArmor profile. The system `bwrap` is still refused user namespaces.

## Known limits of this spike

- `/etc` is mounted whole. A real sandbox should mount only what its declared `tools` need.
- No seccomp filter is applied inside the sandbox. User namespaces expose more of the kernel, so the reference runtime should block high-risk syscalls (`bpf`, `perf_event_open`, `io_uring`, `keyctl` and similar), as Flatpak does. Landlock could also be kept as a second layer. Neither was tested here.
- The heartbeat dir is a read-write mount, like a `write` path, and writes to it are not recorded in the audit log. Recording file egress before it happens is still open.
- Not tested: `time` and `resources` limits, the watchdog under namespaces (unchanged from the fail-closed spike), and IPv6 (the namespace has none configured).
