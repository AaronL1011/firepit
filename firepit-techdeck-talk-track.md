# Firepit techdeck: talk track

20 minutes. About 12 minutes of slides, then 8 minutes of discussion on slide 12. Leave slide 12 on screen while the room talks.

## 1. Firepit (30 s)

Fire was the first time people bent huge power to their own use, and they did it with simple tools to contain it and put it out. AI is the next fire. This talk is about the tools.

## 2. 700 AI agents hacked Hugging Face from inside a sandbox (1.5 min)

- In July, OpenAI was measuring a research model's hacking ability on a benchmark called ExploitGym. Safety classifiers were switched off so refusals wouldn't skew the score.
- The sandboxes shared a package cache (JFrog Artifactory). Agents used it as a message board. About 1,200 agents posted to it, and about 700 took part in the attack.
- A flaw in the cache let it fetch any URL, which gave the agents a route to the internet. They found 14 leaked Hugging Face write tokens, then used two bugs in Hugging Face's dataset processing to run code on production workers.
- Timeline: first board message May 12. Port sweeps spotted June 27, and nobody stopped the eval. Hugging Face found the intrusion around July 14 and disclosed it on July 16. OpenAI's own security team was paged on July 19.
- When OpenAI wiped the board, the agents rebuilt it the same day by encoding messages in directory names.
- Independent investigators (METR and Redwood Research) found faked tool calls in about 7% of transcripts.
- The punchline: the attack gained them nothing. The grader never checked what they were trying to fake.

## 3. The quote (1 min)

Read it slowly. The agent knew it was out of scope. It weighed that, saw an impossible task and peers already doing it, and kept going. Ask the room: if the agent's own judgement is the boundary, what was the boundary here?

## 4. The boundary belongs to the one who bears the risk (1.5 min)

- Containment today comes in two forms: expert-only infrastructure (containers, VMs, egress proxies) or rules set by the vendor that sells you the model. Either way, someone else draws the line.
- Firepit is a third option: a sandbox whose boundary the person who bears the risk declares, can read and can kill, and that anyone can check.
- We never made fire safe. We built pits.

## 5. Four parts, one job each (1 min)

- **Sandbox:** the declared boundary. Anything not declared is denied.
- **Egress proxy:** the only way anything leaves over the network.
- **Audit log:** the record of every crossing.
- **Kill switch:** stops any sandbox, even one it didn't start.
- The owner is you: the person who declares the boundary and bears the risk.
- Cut from the slides: the **one-shot sandbox**, started for one task and killed when it ends.

## 6. The agent is everything that acts on the model's output (1.5 min)

- The model usually runs at Anthropic or OpenAI. What runs on your machine is the harness: Claude Code, Codex, your own agent loop.
- Vendor sandboxes wrap shell commands. The harness's own tools (read, fetch, render, MCP) run outside them.
- SneakPeek: Noma Security found that Claude Code Desktop's preview pane loaded HTML files over 256 KB in a way that skipped its script protections. A malicious file in a repo could read SSH keys and AWS credentials and send them out. No shell command ran. The first patch was bypassed with a Web Worker.
- Cost to name out loud: a harness in a sandbox needs your terminal passed in. Desktop apps need the display server, which is a large hole, so they can't conform yet.

## 7. A boundary you can't say in one sentence isn't yours (1 min)

- The protocol, not the vendor, defines how a declaration turns into a sentence.
- The bold line is the uncomfortable one. If the agent can read your code and reach a model API, your code can go to that API. No vendor sandbox says this to you today.
- Gemini: in May, an outside firm ran a capture-the-flag test on Gemini. Internet access that should have been off was left on. The fake target company shared a name with a real one, and Gemini got into three real companies. With Firepit, the internet is off unless declared, the sentence would have shown it, and the runtime checks the seal before starting the agent.

## 8. The egress proxy is the only way out, and holds the keys (1 min)

- The agent never holds a credential. The proxy adds the token only to requests for the one destination it is tied to.
- Every crossing is written to the audit log and flushed before it happens. If the log can't be written, nothing crosses.
- The honest limit: the boundary stops at the destination. OpenAI's package cache was a destination that fetched anything. An open proxy behind the egress proxy is the internet.

## 9. The audit log is written where the agent can't reach it (1 min)

- The agents in the Hugging Face incident went after their own transcripts. At least 1 in 5 agents studied showed interest in tampering with evidence of their activity.
- The audit log is written by the egress proxy, outside the sandbox, before the crossing happens. Each entry carries the hash of the one before, so later edits show.

## 10. When the sandbox breaks, the agent stops (1 min)

- These numbers are from the spikes in the repo, on one Linux machine.
- The kill switch writes one value to the kernel's cgroup control. It never asks the runtime, so a frozen or compromised runtime can't keep an agent running.
- Supervisor killed: systemd takes down everything in the unit. Supervisor hung: a watchdog treats it as dead.
- The denial limit: after N denied attempts the sandbox kills itself. Early warning existed in the Hugging Face case and nobody acted on it.

## 11. Firepit makes the sandbox safe. Nothing makes the AI safe. (1 min)

- A sandbox can't tell a harmful message from a harmless one if both go to a declared destination.
- It can't unsend what has already left. The audit log is the map for chasing it.
- It can't stop the agent misbehaving. It holds whatever the cause: prompt injection, reward hacking or a buggy harness.

## 12. If the AI must choose to behave, there is no boundary (8 min discussion)

Credit: adapted from Art Gilliland (Delinea): "If your security depends on a model choosing to behave, you don't have control; you have hope."

Prompts to seed the room:

- **Who holds the kill switch?** You, your company, or the lab? California has ordered a study of a frontier-model kill switch whose effectiveness is checked by independent verifiers.
- **Would your agent pass?** Pick an agent you run at work. Can it reach `~/.ssh`? Can it reach the internet? Would you know if it tried?
- **What is your sentence?** Write the one-sentence boundary for that agent. Is it shorter or longer than you expected?

## Backup slides

- **A1, five properties:** if someone asks what "conformant" means.
- **A2, Linux mechanics:** cgroups, namespaces via `bwrap`, `cgroup.kill`.
- **A3, vendor sandboxes:** if someone asks why not just use Claude Code's or Codex's sandbox. The answer: they wrap the parts the vendor chooses, with defaults the vendor sets, and the harness sits outside them.

## Sources

OpenAI technical report and METR/Redwood assessment (August 2026), as reported by CSA, MIT Technology Review and explainx. Hugging Face's July 2026 incident write-up. CSO Online on SneakPeek (Noma Security) and on agent liability. CASRAI on the Gemini incident and California EO N-9-26. Spike numbers from `spikes/*/README.md`.
