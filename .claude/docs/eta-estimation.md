# ETA Estimation

Shared estimation contract for `/nase:estimate-eta` (standalone estimate) and `/nase:design` (an `### ETA Estimate` section appended to the effort doc). Both turn a subtask breakdown into a rough effort picture; this doc owns the lane model, the size scale, and the confidence-range format so the two stay aligned instead of drifting.

The point is **not** a precise number. AI now writes code fast, so total build-time is a misleading single blob. The useful signal is *where the time actually goes* — which subtasks AI can do well, which are gated by environment, which need a human, and which need verification. Estimate by **execution lane**, not by lines of code.

## Estimation Principles
- Estimates improve with familiarity — explore the codebase before classifying subtasks.
- Codegen being fast does not make the task fast. Verification and integration did not shrink; spec/decision work did not shrink. ([METR 2025](https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/) measured experienced OSS developers 19% slower with early-2025 AI while believing they were faster; [Addy Osmani's 70% problem](https://addyosmani.com/agentic-engineering/the-70-percent-problem/) frames the final production-ready portion as the human bottleneck.)
- Unknowns dominate: one unclear dependency or one undecided design call can triple the timeline.
- Compare against similar past tasks in `workspace/tasks/lessons.md` and the relevant project KB (`workspace/kb/projects/`) — pattern-matching beats guessing.
- Be rough on purpose. Use size buckets, not hour-precision; if the work is too vague to classify, say so and ask rather than guess.

## Lane Classification (the core step)
Break the task into concrete subtasks, then tag each with its **dominant lane** — ask "what is this step actually blocked on?":

| Lane | What it covers | Blocked on | AI leverage |
|------|----------------|------------|-------------|
| 🤖 **AI** | Generation, boilerplate, refactor, rewrite, well-specified implementation, docs | Writing code | High (compresses ~5–10×) |
| 🔌 **Env** | Getting it running, deps/secrets, infra, data access, repro, deploy, external systems | Environment readiness | Low |
| 🧠 **Human** | Judgment/design/tradeoffs, ambiguous spec, cross-team, approvals, domain knowledge | Making a decision | ~None |
| ✅ **Verify** | Review, writing/running tests, confirming correctness, security | Confirming it's correct | Low (evidence says it may even grow) |

A subtask may touch several lanes; pick the one that dominates its time. Apply the AI-leverage compression **only** to the 🤖 lane — the other three lanes do not speed up because codegen got faster.

## Size Scale
Rough buckets, no hour-precision:

| Bucket | Duration | Meaning |
|--------|----------|---------|
| **S** | <2h | one sitting |
| **M** | half-day to 1 day | |
| **L** | ~3 days | |
| **XL** | ~1 week | |
| **XXL** | >1 week | too big — split into subtasks and re-estimate |

XXL is mostly a signal: stop estimating, decompose first.

## "Where the time goes" line
After the subtask table, add one line summarizing the lane split (rough % or which lanes dominate). This is the most valuable output:
- 🤖 dominates → genuinely fast, trust the compressed estimate.
- 🔌 / 🧠 / ✅ dominate → AI barely helps; fast code ≠ fast task. Name the real bottleneck (env setup, an undecided design call, verification).

## Confidence Range
Roll the subtasks into three rough numbers:
- **Optimistic** — everything understood, no surprises.
- **Realistic** — the number you'd commit to; accounts for the usual friction. This is the calibration anchor.
- **Pessimistic** — a key unknown bites or a dependency slips.

The gap *is* the risk signal. On AI-heavy tasks the spread should **widen, not narrow** — AI raises outcome variance (different prompts → wildly different results; higher churn/rework). A wide spread means unresolved unknowns worth naming as risks.

## Calibration Anchor (optional)
A consumer that wants `/nase:wrap-up` to compare estimate vs actual appends one line to `workspace/logs/{YYYY-MM-DD}.md`:
```
- ETA estimate: {task name} — {realistic estimate} ({scope})
```
`/nase:wrap-up` later diffs this against actual completion time and writes a calibration note to `workspace/tasks/lessons.md` on significant divergence — see `.claude/docs/lessons-format.md`.
