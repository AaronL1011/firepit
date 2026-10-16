# Spike: credential injection

> Status: **brief, not run.**

Question: can the egress proxy hold a secret and add it to requests for one declared destination, so the agent can use the credential without ever seeing its value? And can it do that without root, without breaking fail-closed, and without an unrecorded crossing?

## Why

The protocol requires that secrets never enter the sandbox. A secret inside the sandbox can leave through any destination it can reach, including the model's endpoint. This spike tests whether the requirement can be built.

## Design under test

Same systemd service, supervisor and `bwrap` namespaces as the namespaces spike (`../common/`, `../namespaces/`). Changes:

- **A per-sandbox certificate authority.** The supervisor makes a key pair at start. The certificate is mounted read-only into the sandbox at `/run/firepit/ca.pem` and named in `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS`. The key stays in the proxy's memory and is never written into the sandbox.
- **The proxy ends TLS for bound destinations.** For a destination with a bound secret, the proxy presents a certificate for that host signed by the sandbox's authority, reads each request, sets the declared header to the secret, and forwards the request over a fresh TLS connection to the real host. Destinations without a bound secret are forwarded without being opened.
- **Replies are cleaned.** The proxy replaces the secret's value with a fixed marker in anything sent back to the agent, including across chunk boundaries.
- **The audit log records the name.** Each crossing that carries a secret records the secret's name and never its value.

`host.py` stands up two HTTPS destinations: one bound to the secret, and one unbound. Both log the headers they receive, and the bound one echoes request headers back in its reply.

## Probe

`probe.py` tries to get the secret's value or misuse it:

1. Search its environment, every file it can read, and `/proc` for the value.
2. Call the bound destination and check its own view of the reply for the value.
3. Call the unbound destination with the secret's header name and hope the proxy fills it in.
4. Set the secret's header itself to a value it controls.
5. Use HTTP/2, chunked bodies, a pipelined second request on one connection, and a request split across many small writes.
6. Present its own CA, or connect with verification off, to see whether the proxy behaves differently.

## Pass

- The value never appears inside the sandbox (probe steps 1 and 2).
- The bound destination receives the value on every request, and only in the declared header.
- The unbound destination never receives the value (step 3).
- The agent's own header is replaced, never sent alongside (step 4).
- Steps 5 and 6 change nothing above.
- Every crossing is in the audit log with the secret's name and no value. The log file never contains the value.
- The fail-closed results still hold: proxy `SIGKILL` cuts the network at once, supervisor `SIGKILL` ends the sandbox, a full log disk stops crossings.

## Risks to watch

- **Certificate pinning.** A tool that pins certificates will refuse the sandbox's authority on bound destinations. Under fail-closed this fails safely, but it may rule out some harnesses.
- **CA trust variables.** Not every runtime reads the same variable. Record which harnesses need more.
- **Protocol coverage.** HTTP/1.1 and HTTP/2 only. WebSockets, gRPC streaming and HTTP/3 (QUIC over UDP, which the seal already blocks) are out.
- **Size of the proxy.** Ending TLS and parsing HTTP moves the proxy from a byte pipe to an HTTP proxy. Prefer a well-known proxy library over hand-rolled parsing, and note how much code the proxy grows by.
