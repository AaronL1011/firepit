# Spike: the kill switch

Question: can a kill switch stop any sandbox, through the kernel, without asking the runtime and without root?

Answer on Linux: **yes, if the sandbox is also sealed.** The cgroup kill is fast and does not depend on the runtime. On its own, though, it leaves three escape routes open, and the seal from Bounded is what closes them. Fail-closed does not come for free and needs its own design.

## Run it

```
bash run-spike.sh
```

Needs Linux with cgroup v2 (kernel 5.14+ for `cgroup.kill`), a systemd user session, Landlock ABI 6+, and `libseccomp.so.2`. No root, no system config changes. Takes about 30 s and cleans up after itself. Every test process stops itself after 60 s even if cleanup fails.

## Pieces

| File | Role |
|---|---|
| `vessel.sh` | The runtime. Writes a registry record, then starts the agent in its own cgroup, `firepit.slice/firepit-<id>.scope`. Optionally seals it first. |
| `../common/seal.py` | Unprivileged seal: Landlock (read anywhere, write only to the given dirs, TCP connect only to given ports, no signals or abstract sockets outside the sandbox) and seccomp (no unix, UDP, raw or packet sockets). |
| `probe.sh` | Hostile agent. Tries to detach, migrate cgroups, get host daemons to run work for it now and later, and checks whether `docker.sock` is reachable. |
| `../common/beat.sh` | A process that ignores TERM/HUP/INT and touches a heartbeat file every 200 ms. A fresh heartbeat after the kill means it survived. |
| `extinguish.sh` | The kill switch. Writes `1` to `cgroup.kill` for one sandbox or for all of `firepit.slice`, then waits for the kernel to report the group empty. Reads no registry and never contacts the runtime. |

## Results

Kernel 6.17, Ubuntu, cgroup v2, Landlock ABI 7. Run twice with identical results.

**Supervisor frozen with SIGSTOP, one sandbox killed**

| Route | Unsealed | Sealed |
|---|---|---|
| Main process | stopped | stopped |
| Background child | stopped | stopped |
| `nohup` | stopped | stopped |
| Double fork + `setsid` | stopped | stopped |
| Write own PID into another cgroup | **survived** | blocked |
| `systemd-run --user` (run now) | **survived** | blocked |
| `systemd-run --user --on-active` (run later) | **survived**, ran after the kill | blocked |
| `docker.sock` | **reachable** | blocked |

The kill took 12 to 13 ms with the supervisor frozen.

**Two sealed sandboxes, `extinguish.sh --all`:** both stopped, every route, in under 2 ms.

**Sealed sandbox, supervisor killed with SIGKILL:** every agent process **survived**. Nothing tied the agent's life to the runtime's.

## Findings

1. **The kill handle is a cgroup, and the kernel is the authority.** Killing one sandbox or all of them is a single write. A frozen runtime makes no difference. The kill switch is about 30 lines of bash.
2. **The OS user is enough authority.** The sandbox cgroups live under the user's delegated systemd tree, so the user can kill them and other users cannot. No Firepit-specific auth was needed.
3. **Killable depends on Bounded.** An agent that can write to cgroupfs, or reach the systemd user bus, outlives the kill. A sandbox that is not sealed is not killable.
4. **Local sockets are an escape route the spec did not yet cover.** `net` only declares host:port. The user bus and `docker.sock` each let the agent start work outside the sandbox. On this machine `docker.sock` is root-equivalent and one `connect()` away, which is normal on developer machines.
5. **Without root, the seal has to be Landlock plus seccomp.** Ubuntu blocks unprivileged user namespaces through AppArmor (`apparmor_restrict_unprivileged_userns=1`), so `bwrap` and `unshare -U` fail without changing system settings. Landlock and seccomp need neither. That matters for the manifesto's claim that this is accessible to everyone.
6. **Fail-closed needs its own mechanism.** With this runtime, if the supervisor dies the agent keeps running. The fail-closed spike (`../fail-closed/`) fixes this by running the sandbox as a systemd service.

## Known limits of this spike

- The seal blocks all `AF_UNIX` sockets. A sandbox that declares a specific socket will need a finer tool.
- Not tested: network egress (TCP/UDP, DNS), `crontab`, persistence by writing to files other programs run later (Landlock's write rule should cover this), ptrace (Yama scope 1 plus the Landlock domain should cover this), and macOS or Windows.
- Only one runtime implementation was used. The two-implementation kill switch test from the spec is still open, though the kill switch never touches the runtime, so the result should carry over.
- The cgroup root path assumes a systemd user session (`user@UID.service`).
