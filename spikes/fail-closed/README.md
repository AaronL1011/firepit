# Spike: Fail-closed

Question: when part of the runtime breaks, does the agent stop, and does anything cross without being recorded in the audit log?

Answer on Linux: **yes, for every failure tested, once two fixes were in.** The sandbox has to run as a systemd service with a watchdog, and the egress proxy must treat a short log write as a failed one. The first run let one crossing through unrecorded. The spike also confirmed a Bounded gap that no-root Linux cannot close: the agent can reach any host on the proxy's port number.

## Run it

```
bash run-spike.sh
```

Same requirements as the kill switch spike, plus `prlimit` (util-linux). No root. Takes about 40 s and cleans up after itself.

## Design under test

The sandbox is a transient systemd user service, `firepit.slice/firepit-<id>.service`:

| Part | What it does |
|---|---|
| `supervisor.py` | The unit's main process. Starts the egress proxy, then the sealed agent, then pings the systemd watchdog every 0.5 s. Exits if the proxy dies. |
| `chimney.py` | The egress proxy, the only network route out. Every chunk in either direction is written to the audit log and fsynced before it is forwarded. If a log write fails or is short, the proxy exits. It is also the log writer, so there is one less component that can break. |
| systemd | `KillMode=control-group` and `KillSignal=SIGKILL`: when the main process exits, every process in the unit is killed. `WatchdogSec=2` and `WatchdogSignal=SIGKILL`: a supervisor that stops pinging is treated as dead. `ExecStopPost` runs `terminal.sh`, which writes the terminal log record however the unit stopped. |
| `probe.sh` | Hostile agent. Detaches three heartbeat processes, tries to truncate its audit log, and every 200 ms tries the proxy, the destination directly, UDP, and another host on the proxy's port. |
| `outside.py` | The world: an echo server at the declared destination, a UDP sink, and an attacker listening on `127.0.0.2` at the proxy's port. It logs every line received so the harness can compare with the audit log. |

The seal is `../common/seal.py` with `--connect <proxy port>`: Landlock allows TCP connect to that port only, and seccomp denies UDP, raw, packet and unix sockets.

## Results

Kernel 6.17, systemd 255, Landlock ABI 7. Run twice after the fix, with identical results.

| Failure | Agent stopped | Detached processes left | Crossings not logged | Terminal record |
|---|---|---|---|---|
| Supervisor `SIGKILL` | 19 ms | none | 0 | yes (`signal`) |
| Supervisor hung (`SIGSTOP`) | 2.2 s (watchdog 2 s) | none | 0 | yes (`watchdog`) |
| Egress proxy `SIGKILL` | network cut at once, agent stopped in 0.5 s | none | 0 | yes |
| Log disk full (2048 B limit on the proxy) | 3.5 s from start | none | **1 before the fix**, 0 after | yes |
| Two implementations (scope runtime and service runtime), both supervisors frozen, `extinguish.sh --all` | 14 ms | none | n/a | n/a |

**Baseline, healthy sandbox:** proxy 15/15, direct to destination 0/15, UDP 0/15, log truncation denied, 15 crossings received and 15 recorded. Another host on the proxy's port: **15/15 reached the attacker.**

## Findings

1. **The service manager makes supervisor death fail closed.** With the sandbox as a service and the supervisor as its main process, systemd kills every process in the unit when the supervisor exits, including double-forked and `setsid` processes. The earlier scope-based runtime left all of them running.
2. **A hung runtime is a broken runtime, so the watchdog is required.** A frozen supervisor is not dead and would hold the sandbox open forever. The watchdog interval sets the worst-case deadline, so it must sit inside the protocol's 5 s.
3. **A dead egress proxy cuts the network on its own.** It is the only route out, so killing it drops the network at once without help from anything else. The supervisor then ends the sandbox, which matches the manifesto: when the sandbox breaks, the agent stops.
4. **A short write is a failed write.** At the size limit, `write()` wrote part of the record and returned without an error. The proxy took that as success and forwarded the chunk, so the destination got 16 messages and the log held 15 complete records. The fix: a record counts only if the whole line was written and fsynced. Real `ENOSPC` can produce short writes too, so the protocol should say this outright.
5. **The terminal record comes from systemd.** `ExecStopPost` writes it however the unit stops, including when the kill switch kills it. When the log disk itself is full, the terminal record cannot be written either. The protocol should say it is written when possible.
6. **Bounded gap: without root, network rules can only filter by port.** Landlock matches TCP by port only, and seccomp cannot read the address passed to `connect()`. An agent allowed to reach `127.0.0.1:P` can reach any host on port `P`. Closing this needs a network namespace, so the agent's only interface leads to the proxy. On Ubuntu that needs unprivileged user namespaces, which AppArmor blocks by default. The options are a one-time admin step, such as an AppArmor profile for the runtime like the one Ubuntu ships for `bwrap`, or accepting the gap.

## Known limits of this spike

- Disk-full is simulated with `RLIMIT_FSIZE` on the proxy. A real full disk would also stop the supervisor's and `terminal.sh`'s writes.
- systemd's control-group kill was not raced against a fork bomb. `cgroup.kill` is atomic. Whether systemd 255 uses it or signals processes one by one was not checked.
- Not tested: the systemd user manager itself dying (doing so would end the desktop session), TCP Fast Open as a way around Landlock's connect rule, and the `time` and `resources` limits.
- Both runtime implementations were written by the same author. That is weak evidence for the "independent implementations" test.
- Writes to `write` paths go straight to disk through Landlock and are not recorded in the audit log. Auditable is not met for file egress. Without root, the options are logging after the fact with inotify, or staging writes through the runtime.
