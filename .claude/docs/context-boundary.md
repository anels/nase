# Context Boundary

> Which context move to make when a chunk of work ends. Referenced from `CLAUDE.md → Compact instructions`. Edit here, not in the skills.

A **phase** is a chunk of work inside a session — the research, the implementation, the review pass. It ends when the work in front of you is done, not when the context window fills up. The **phase boundary** is the gap between two phases, and it is the only place this decision belongs: mid-phase there is no decision to make (continue, or split the remaining work into subagents), and compacting mid-phase loses the thread.

## The tree

Work top to bottom at the boundary. The first **yes** wins.

| # | Question | Move |
|---|---|---|
| 1 | Does the next phase need this one as a **primary source**, or does the remaining window fit it? | **Continue** |
| 2 | Is everything in this session — exploration, dead ends, decisions — disposable from here? | **`/clear`** |
| 3 | Does the work have to **travel** — new harness, new worktree or repo, another person, or a side task found mid-phase? | **Hand off** |
| 4 | Is the task tight enough to run with no steering? | **Subagent** |
| 5 | Otherwise | **`/compact`** |

**1. Continue.** The default and the cheapest: it costs nothing and loses nothing. Design → implementation is the standard yes — the implementation wants the reasoning verbatim, not a summary of it. Rule it out before anything else.

**2. `/clear`.** Cheapest move on the board when the context truly is disposable, and it is not terminal — the old session stays resumable. The cost of getting it wrong is one-way: clear a *relevant* context and the **why** behind what you built is gone, and re-reading the diff never returns it.

**3. Hand off.** Narrow, and only for **portability**: a file that travels. In nase that is the effort doc (`workspace/efforts/`, see `.claude/docs/effort-lifecycle.md`), a `/nase:design` output feeding `/nase:fsd`, or `.claude/docs/pr-next-step-handoff.md` for PR work. If nothing is travelling, you do not need one.

**4. Subagent.** Scoped tightly enough to run unattended. Read-only fan-out — repo state, KB lookup, PR metadata, reviewer ownership — is the standard case: the agent reads and reports, and the main session stays untouched. Route by `.claude/roles.yaml` or a persisted agent in `.claude/agents/`, and hold it to `.claude/docs/subagent-output-contract.md`.

**5. `/compact`.** Where the tree lands often, but it is the **default, not the first reach** — the four questions above it are all cheaper or more precise. Pass it an instruction so the summary keeps what the next phase needs, and see `CLAUDE.md → Compact instructions` for what must survive. The failure mode when you start here is a fresh session that is confidently wrong about a decision the summary flattened.

## Primary and secondary sources

Every move except Continue turns a **primary source** — the session as it happened — into a **secondary source**, a summary of it.

| Source | Information | Noise | Room to move |
|---|---|---|---|
| Primary (Continue) | Full | Lots | Little |
| Secondary (hand off, `/compact`) | Lossy | Less | Lots |

That trade is why question 1 comes first: you only pay the lossiness when staying costs more than it saves.

These are judgement calls — the same boundary can go two ways on two days. The value is asking them **in order**, at the boundary rather than in the middle of the work.

Attribution: adapted from mattpocock/skills `ask-matt/PHASE-BOUNDARIES.md` — see `workspace/kb/general/workflow.md → §2026-08-06`.
