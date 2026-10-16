# Spike: swarm

> Status: **brief, not run.**

Question: when many sandboxes run at once, can any agent pass data to another? And when agents run one after another, is written output the only thing an earlier agent leaves for a later one?

## Why

The protocol says the boundary includes other agents. Any writable state two sandboxes share can become a channel between them, and an agent can leave instructions for whatever reads its output next. The earlier spikes tested one sandbox against the host. This spike tests sandboxes against each other.

## Design under test

The namespaces runtime (`../namespaces/`), unchanged. N sandboxes, starting at 16 and going up to 64, all started under one root group. Each sandbox has its own mount, network, IPC, PID and UTS namespaces, its own tmpfs `/tmp` and `/scratch`, and a separate egress proxy socket. All sandboxes use the same declaration shape. Three layouts:

- **Disjoint.** No two sandboxes share a declared path.
- **Shared read.** All sandboxes read the same path, and none can write it.
- **Overlap.** Sandbox A writes a path that sandbox B reads. This is the case the rendering must name.

## Probe

Each sandbox runs `probe.py`, which picks a random token and tries to get it to any other sandbox, and to read any other sandbox's token, through:

- files: `/tmp`, `/scratch`, `/dev/shm`, the declared paths, and any other writable mount
- unix sockets, including abstract and filesystem sockets
- System V and POSIX shared memory, semaphores and message queues
- signals and `/proc` listings of other sandboxes' processes
- loopback TCP and UDP
- timing and load on shared resources, kept to a rough check that a low-rate covert channel exists
- the egress proxy: a request through its own proxy for another sandbox's socket path

A second run starts one one-shot sandbox that writes to a `write` path, kills it, then starts a second that reads that path. A third run has the first one try to write anywhere else the second could read, such as harness config or memory files in the home directory, the scratch path or `/tmp`.

## Pass

- **Disjoint:** no sandbox receives another sandbox's token by any route except timing.
- **Shared read:** same as disjoint. A read-only shared path carries nothing between sandboxes.
- **Overlap:** B receives A's token through the declared path and nothing else, and the rendered sentences of both sandboxes name the overlap.
- **One-shot sandboxes:** the second sees only what the first wrote to its `write` path, and nothing written anywhere else survives the first.
- **Kill switch:** `extinguish.sh --all` kills all N sandboxes within the Killable deadline, with nothing left.

## Risks to watch

- **Timing channels.** CPU, memory, disk and cache contention between sandboxes is a low-rate covert channel that namespaces do not close. Expect it to exist. Record it and add it to the protocol's Out of scope, instead of trying to close it.
- **`/dev/shm` and SysV IPC.** These depend on how `bwrap` sets up `/dev` and the IPC namespace. Confirm, don't assume.
- **Rendering overlaps needs the registry.** This is the first spike that reads other sandboxes' declarations at start. The registry is not on the kill path, so a broken registry may stop a sandbox starting but must never stop one being killed.
