# Firepit Protocol v0 (draft)

> Status: **draft, not a standard.** No runtime conforms yet. The first reference runtime is the first subject of this spec. v0 covers **local sandboxes**: the agent runs on a machine where the owner is the OS user who owns it.

Firepit is a shape any agent runtime can take: a sandbox boundary declared by its owner, enforced by the runtime, and readable by anyone. Unlike sandboxes run by experts or guard rails granted by vendors, the boundary here belongs to the one who bears the risk.

A sandbox must hold against the worst agent the owner could put in it, including one with every model-side safeguard removed. The boundary does not depend on why the agent pushes on it.

The key words MUST, MUST NOT and SHOULD are used as in RFC 2119.

## Terms

| Term | Meaning |
|---|---|
| **Agent** | What is being contained: everything that acts on the model's output, and every process it starts. A model that runs elsewhere is reached through the egress proxy like any other destination. |
| **Owner** | The person who declares the boundary and bears the risk. |
| **Sandbox** | An isolated session for one agent, enforcing one declaration for its lifetime. |
| **Runtime** | The software that starts, enforces and supervises sandboxes. |
| **Boundary** | The enforced line between the agent and everything else, including other agents. |
| **Declaration** | The owner's statement of the boundary. |
| **Group** | The OS-enforced container holding every process of one agent. |
| **Root group** | The per-user parent of every sandbox group on a machine. |
| **Egress proxy** | The runtime component every network crossing goes through. |
| **Audit log** | The record of everything that crosses, or tries to cross, the boundary. |

## The declaration

A runtime enforces exactly what is declared. Anything not declared is denied. The syntax is defined elsewhere. These are the required fields:

| Field | Declares | Default |
|---|---|---|
| `read` | Host paths the agent may read | none |
| `write` | Host paths the agent may write. Writes are egress. | none |
| `net` | Network destinations (host:port) the agent may reach, including the model's endpoint | none |
| `tools` | Executables the agent may run | none |
| `secrets` | Named credentials, each bound to one `net` destination and the request header that carries it | none |
| `time` | Maximum wall-clock lifetime | required, no default |
| `resources` | CPU and memory ceiling | required, no default |
| `max_denials` | Number of denied attempts after which the sandbox is killed, at least 1 | required, no default |

Local IPC is always denied in v0: unix sockets, D-Bus, signals to and tracing of processes outside the group, and writes to OS process-control interfaces such as the cgroup filesystem. Each of these lets an agent start work outside its group.

The agent also gets a private scratch workspace that is destroyed when the sandbox is killed. A declaration MUST NOT contain opaque fields such as scripts, hooks, regexes or vendor-specific policy. If a field can't be put into words, it can't be owned.

**Secrets never enter the sandbox.** The egress proxy holds each secret and adds it to requests bound for its declared destination. The agent never sees the value: not in its environment, its files or any response. The proxy MUST NOT send a secret to any other destination, MUST replace any header of the same name that the agent sets, and MUST remove the secret's value from anything flowing back to the agent. The audit log records the secret's name, never its value. A credential that cannot be carried this way cannot be declared in v0.

**Denials.** A denied attempt is a request the boundary refused and the runtime saw: a proxy request for an undeclared destination, or a system call refused by the runtime's filter. Anything not declared is absent from the sandbox, and reaching for something absent is not an attempt. Every denied attempt is recorded in the audit log and counts toward `max_denials`.

**Rendering.** Every declaration renders to one plain sentence stating the boundary, followed by the consequences this section requires to be stated. The protocol defines how; the runtime does not write it. For example:

> *This agent can read `~/project`, write to `~/project/out`, reach `api.anthropic.com:443` and `api.github.com:443`, run `git` and `python`, and use the `GITHUB_TOKEN` key only with `api.github.com`, for 30 minutes, within 2 CPUs and 4 GB. Anything it reads can be sent to `api.anthropic.com` and `api.github.com`. A later agent that reads `~/project` will see what this one writes to `~/project/out`. It is killed on its 3rd denied attempt. Everything that crosses is recorded.*

The required consequences are:

- **Where reads can go.** If the agent can read anything and reach anything, every destination it can reach is named as a place its reads can be sent.
- **What later agents see.** If a `write` path sits inside a `read` path, of this declaration or of any live sandbox, the sentence names it. The boundary between agents is only as wide as the paths their declarations share.
- **The denial limit.**

## Start

A runtime MUST start a sandbox in this order, and MUST NOT start the agent if any step fails:

1. Render the sentence, checking the declaration against the declarations of live sandboxes in the registry.
2. Write a registry record for the sandbox: id, implementation, start time, declaration, rendered sentence, audit log location. The record is for people. Nothing in the kill path reads it.
3. Write the audit log header.
4. Create the sandbox's group under the root group.
5. Seal the boundary.
6. Check the seal from inside it. A check process in the sealed group tries an undeclared host, the cloud metadata address, an undeclared path in the owner's home directory and the host's undeclared sockets. If any of them is reachable, the runtime kills the group and does not start the agent.
7. Start the agent inside the group.

## Installation

Some systems restrict the isolation a runtime needs. On those, a runtime MAY need a one-time install by an administrator. After that install:

- Starting, running and killing sandboxes, and reading audit logs, MUST NOT need admin rights.
- The install MUST state in plain words what it grants, to which program, and how to remove it.
- The install MUST grant only what the five properties need, and only to the runtime's own programs.

A runtime MUST NOT give up a property to avoid the install.

## The five properties

A runtime conforms only if it passes all five tests. Each test is run from outside the runtime, against a **hostile probe**: an agent whose job is to break the property.

**1. Bounded.** The agent reaches only what is declared.
*Test:* The probe tries to read an undeclared path (parent directory, `~/.ssh`, other users' files), write outside `write`, connect to an undeclared host (raw IP, DNS lookup, localhost, cloud metadata `169.254.169.254`), run an undeclared tool, read inherited environment credentials, and go over `time` and `resources`. It also tries every local IPC route: the user's D-Bus and service manager, `docker.sock` and other daemon sockets, abstract sockets, signalling or tracing outside processes, and writing to the cgroup filesystem. It also connects to a different host on the proxy's own port, because some OS mechanisms filter by port only. It searches its environment, files and memory for the value of a declared secret, asks the proxy to send the secret to an unbound destination, overwrites the secret's header, and calls a bound destination that echoes request headers back. Finally, two sandboxes with separate declarations are started, each running a probe that tries to reach the other through files, sockets, shared memory, signals, process listings and the network. **Pass:** every attempt is denied, the egress proxy is the agent's only network route, a secret's value never appears inside the sandbox and reaches only its bound destination, and neither sandbox gets a byte to the other.

**2. Legible.** The declaration fully describes what the agent can do at the boundary.
*Test:* The declaration contains only protocol fields and renders as defined above. The Bounded probe is then run against the full declared scope. **Pass:** every capability the probe gets is stated in the rendering, and every capability the rendering states actually works. The boundary is what it says, nothing more and nothing less. What a declared destination does with data after it arrives is beyond the boundary (see Out of scope).

**3. Killable.** Killing a sandbox is immediate, complete and leaves nothing running.
*Test:* The probe forks, double-forks, calls `setsid`, daemonises, ignores polite signals, holds open sockets, tries to move itself out of its group, and asks host services to run work now and later (`systemd-run`, timers, cron, `at`). Then the sandbox is killed. Separately, a probe makes one fewer denied attempt than its `max_denials` and must still be running, then makes one more. **Pass:** in both cases, within 5 s no agent process remains, no connection stays open, the workspace is gone, nothing scheduled ever runs, and the audit log records no crossing after the kill marker. Killing MUST NOT depend on the agent cooperating. A sandbox that fails Bounded cannot pass Killable, because an unsealed agent can start work outside its group.

**4. Auditable.** Nothing crosses unseen.
*Test:* The probe makes a known set of allowed crossings and denied attempts, then tries to read, change, truncate or flood its own audit log. **Pass:** every crossing and every denied attempt is in the audit log, which is append-only, out of the agent's reach, and readable by a person while the agent runs. The log is one JSON object per line. Each entry records time, direction, channel, target, size, allow/deny and the SHA-256 hash of the entry before it, so any later edit breaks the chain. The first entry is a header recording the owner's OS user, the host, the runtime implementation and version, the full declaration and its rendering, and the command started as the agent with the hash of its executable. It records only what the runtime observed. A record counts only once it has been written in full and flushed to stable storage, before the crossing it records. A short or failed write is a failure, and the crossing MUST NOT happen. The log ends with a terminal record when the sandbox stops, whenever the log can still be written.

**5. Fail-closed.** When the runtime breaks, the agent stops.
*Test:* Each runtime component (supervisor, egress proxy, log writer) is killed in turn with `SIGKILL`, then frozen in turn with `SIGSTOP`, and the log disk is filled up. A component that stops responding counts as broken. **Pass:** each failure kills the sandbox within 5 s, and the network is cut at once. No crossing happens without being recorded: if the audit log can't be written, nothing crosses.

## Components

| Component | Definition | Holds |
|---|---|---|
| **Sandbox** | A session of work enforcing one declaration for its lifetime. | All five properties |
| **One-shot sandbox** | A sandbox started for one task: it is killed when the task ends, and nothing survives but what it wrote to `write` paths. That output is the one thing a later agent can read from an earlier one, and the rendering names it when it can. | All five properties |
| **Egress proxy** | Carries every network crossing to a declared `net` destination. The only way anything leaves over the network, and the only holder of secrets. | Bounded, Auditable, Fail-closed |
| **Kill switch** | A standalone tool that kills any conforming sandbox, including sandboxes it did not start. | Killable, applied to everything |

## The kill switch

The kill switch works on the group, through the OS. It never asks the runtime, so a hung, buggy or compromised runtime cannot keep an agent running.

- Every group MUST sit under the owner's root group, and the agent MUST NOT be able to leave its group or start processes outside it, directly or through another process.
- Terminating a group MUST be atomic and MUST NOT require the runtime. Terminating the root group kills every sandbox at once.
- The authority to kill is the OS user who owns the group. No Firepit-specific credentials exist. Other users cannot kill your sandboxes because the OS already forbids it.
- The kill switch MUST confirm through the OS that the group is empty, and report either "stopped" or "still running". It MUST NOT report an outcome it did not observe.
- Once the sandbox has stopped, the kill switch appends a terminal record to its audit log, chained like any other entry, if the runtime has not.

**Kill switch test:** start sandboxes from two independent implementations and freeze both supervisors. A third, unrelated kill switch kills each sandbox individually, then a fresh pair all at once. **Pass:** every sandbox meets the Killable test.

## Conformance

The tests in this spec are published as a runnable suite, versioned with the protocol. A conformance claim names the protocol version, the suite version, the platform, and a report holding each test's result and the probes' audit logs. Anyone can rerun the suite against the same runtime and compare. A report from the runtime's own authors is a claim. A report from someone else who ran the published suite is evidence.

## Platform bindings

The rules above are platform-neutral. Each platform binds them to OS mechanisms.

| Platform | Group | Terminate | Confirm empty | Seal without root |
|---|---|---|---|---|
| **Linux** | cgroup v2 of a systemd user service, one per sandbox, under `user@UID.service/firepit.slice` | write `1` to `cgroup.kill` (kernel 5.14+) | `cgroup.events` shows `populated 0` | Landlock (ABI 6+) plus seccomp, and user, mount and network namespaces |
| **Windows** | Job Object | `TerminateJobObject` | job reports no active processes | not yet defined |
| **macOS** | not yet defined | not yet defined | not yet defined | not yet defined |
| **Containers** | not yet defined | not yet defined | not yet defined | not yet defined |

**Linux fail-closed.** The supervisor is the service's main process. systemd kills every process in the unit when the supervisor exits (`KillMode=control-group`, `KillSignal=SIGKILL`), treats a supervisor that stops pinging as dead (`WatchdogSec` within the 5 s deadline, `WatchdogSignal=SIGKILL`), and writes the terminal record however the unit stops (`ExecStopPost`).

**Linux install.** Landlock and seccomp filter TCP by port only, so a network namespace is needed to make the egress proxy the only route. Where AppArmor restricts unprivileged user namespaces (Ubuntu 23.10 and later), the install adds an AppArmor profile that grants `userns` to the runtime's isolation program (`bwrap`) only. Elsewhere no install is needed.

**Linux separation and secrets.** Each sandbox gets its own mount, network, IPC and PID namespaces, so sandboxes share nothing on the machine but the paths their declarations name. For a destination with a bound secret, the egress proxy ends TLS with a certificate authority made for that sandbox. The authority's certificate is mounted read-only into the sandbox and its key never enters it. Refused system calls reach the supervisor through seccomp user notification so they can be counted.

**Evidence.** Tested on Linux against a hostile probe: with the supervisor frozen, one sandbox was killed in about 13 ms and the whole root group in under 2 ms. Supervisor killed: stopped in 19 ms. Supervisor hung: stopped in 2.2 s with a 2 s watchdog. Egress proxy killed: network cut at once, sandbox stopped in 0.5 s. Log disk full: no unrecorded crossing. With namespaces, the agent reached nothing but the egress proxy and one declared socket: no other host, LAN or internet address, and no undeclared socket. Not yet tested: secret injection, separation between sandboxes, the denial limit, the seal check and the log hash chain. The Windows row has not been tested.

## Out of scope

- **Judging what goes through the egress proxy.** A sandbox guarantees the proxy is the only way out and that it is recorded. It cannot tell whether a permitted message is harmful.
- **Relayed reach.** A declared destination can pass data on: a package proxy fetches other URLs, a link shortener redirects, a shared service stores what one agent writes for another to read. The boundary stops at the destination. Declaring a general-purpose proxy is declaring everything behind it.
- **What reads the output.** Whatever consumes what an agent wrote, a later agent, a CI job or a person, receives untrusted input. The sandbox records it. It does not vouch for it.
- **Undoing what already left.** Killing stops the agent. A message already sent stays sent, and a job already started elsewhere keeps running. The audit log is the map for chasing it.
- **Stopping the agent turning.** Containment limits how far a misbehaving agent can reach, whether prompt injection turned it, it chased its goal down a route nobody intended, or its harness failed. It does not stop the misbehaviour.
- **Other layers.** Monitoring a model's reasoning, guardian models, per-action approval, rollback and agent identity systems are separate layers. A sandbox sits under them and does not depend on them.
- **Hosted sandboxes.** When a platform runs sandboxes under its own OS user on the owner's behalf, the owner bears the risk but the platform holds the kill authority. v0 does not cover this.
- Model alignment, vendor policy, persistent memory, and supplying the agent.

## Open questions

1. How do hosted sandboxes give the owner the kill authority directly? One candidate is a lease: the agent runs only while the owner keeps renewing it. This blocks the containers binding, so it is the next scope after v0.
2. What is the macOS binding: a lightweight VM per sandbox, such as Apple's Containerization framework, or a dedicated OS user per sandbox?
3. How are credentials carried for protocols other than HTTP, such as SSH and databases? One candidate for SSH is mounting an `ssh-agent` socket, so the agent can ask for signatures without holding the key. A mount namespace makes this possible, and this has been tested.
4. How are writes to `write` paths recorded before they happen? Landlock lets them straight through to disk. Candidates are a logging filesystem layer (FUSE) or staging writes through the runtime.
5. Is 5 s the right deadline for Killable and Fail-closed, and should the declaration be able to set it lower?
6. How much of each crossing's content is recorded in the audit log, given that full content may itself be a leak?
7. How do `read` and `write` treat symlinks, hard links and mount points?
