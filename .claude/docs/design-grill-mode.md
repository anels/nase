# Grill Mode (`/nase:design --grill`)

## Contents

- Activation
- Step 1: Resolve Target Plan
- Step 2: Confirm Target Repo
- Step 2.5: Ground the mechanism premise
- Step 3: Build Decision Tree
- Step 3.4: Persona Lenses (multi-perspective grill)
- Step 3.5: Codex Mutual Grill Round 1 (cross-model questions)
- Step 4: Grill Loop (frontier rounds)
- Step 5: Termination
- Step 5.5: Codex Mutual Grill Round 2 (answer Claude's questions)
- Step 5.6: Convergence loop
- Step 6: Write Back to Effort Doc
- Grill Session - {YYYY-MM-DD}
- Step 6.5: Doc Hygiene Pass (auto-cleanup)
- Step 7: Report
- Step 8: Follow-up Human Grill Recommendation (when applicable)
- Notes

Stress-test an existing plan via a relentless frontier-round interview. Goal: walk every branch of the decision tree until shared understanding, resolving each round's frontier (facts first, then a batched ask) and recording resolutions back to the effort doc so `/nase:fsd` can pick up the constraints.

## Activation

Trigger: `$ARGUMENTS` contains `--grill` (anywhere in the args). Strip `--grill` from `$ARGUMENTS` before parsing the rest. Skip the normal `/nase:design` Phase 1–5 flow and follow this algorithm instead.

## Step 1: Resolve Target Plan

Resolve the plan to grill, in priority order:

1. **Slug match** — if remaining `$ARGUMENTS` contains a token matching `workspace/efforts/{slug}.md`, that is the target.
2. **Raw text** — if remaining `$ARGUMENTS` is non-empty free-form text describing a plan, treat it as the plan body. Per the design contract, grill writes back into an existing effort doc — invoke `AskUserQuestion`:
   - "Which existing effort doc should I attach the grill session to?"
   - Options: list `workspace/efforts/*.md` files (recent first), plus "Cancel — I'll run /nase:design first to create one".
   - If user picks "Cancel": stop.
3. **Conversation fallback** — if remaining `$ARGUMENTS` is empty, scan the last 50 messages of the conversation (or back to the most recent `/nase:design` invocation, whichever is shorter) for plan/design content. Same `AskUserQuestion` for effort doc target. If no plan can be inferred from conversation, stop and tell user to provide a plan or slug.

Read the resolved effort doc into context. Hold the path as `effort_path`.

## Step 2: Confirm Target Repo

Read the effort doc's frontmatter `repo:` field.

- If present, resolve via `.claude/docs/repo-resolution.md` Part 1.
- If absent or `multiple` → invoke `AskUserQuestion`:
  - "Which repo should I explore while grilling this plan?"
  - Options: list repos from `workspace/context.md`, plus "Other — type the path".

Hold the resolved absolute path as `repo_path`. All codebase exploration in Step 4 runs against `repo_path`.

## Step 2.5: Ground the mechanism premise

Before building the decision tree, verify the plan's **load-bearing mechanism premise** — the 1-2 assumptions about how an external repo, pipeline, or system actually works that the plan's core approach rests on (e.g. "the cert job is separate", "AppGw config is imperative az", "this pipeline stage runs before that gate"). Fetch + grep the authority repo/pipeline (`repo_path` or the external source named in the plan) for those specific decision points and confirm each holds. If a premise is wrong, correct the plan body first, then build the tree.

A grill run on an ungrounded premise multiplies the wrong model across every branch — the whole tree, and the rounds spent resolving it, are wasted when the premise flips only late (the failure this guards against). Step 4b resolves per-branch questions but does **not** re-validate the shared premise the tree is built from, so it must be grounded here. Keep this scoped to the load-bearing premise only — this is not a full re-research of the design (the main `/nase:design` flow's Phase 2b does that); a grill just cannot afford to skip the one check its entire tree depends on.

## Step 3: Build Decision Tree

Read the plan content (effort doc body or raw text). Extract every branch where a real decision is implied or unresolved. Sources of branches:

- Explicit `## Open Questions` section → each item is a branch.
- Ambiguous wording in design body ("we could", "either X or Y", "TBD", "later") → each is a branch.
- Missing constraints — invariants the plan asserts without specifying (error mode, retry semantics, idempotency, ordering, concurrency, schema migration, rollout, observability, ownership).
- Architectural choices the plan glosses over — interface shape, seam location, data path.
- Review packaging ambiguity — proposed multi-PR split without a merge/release/owner boundary, missing `Target PR count`, or implementation phases being treated as PRs without justification.

Output internally: a list `branches: [{id, topic, why-it-matters, persona, depends_on: [branch-id]}]`. Assign each branch a stable `id`. Set `depends_on: []` only when the branch can be resolved independently; when a branch's valid options or recommendation depend on another decision, list that prerequisite's id. Dependency ids must exist, and the graph must contain no self-dependency or cycle. Cap at 15 top-level branches by keeping a dependency-closed set: if a kept branch depends on another branch, keep its full prerequisite chain too. Prioritize by load-bearingness (security, data-loss risk, irreversibility, cross-team coordination) and move the rest, plus any branch that depends on a moved branch, to `## Open after grill`. Revalidate ids and acyclicity after applying the cap. The 15-cap protects the 25-branch budget in Step 5 from being burned on shallow branches before the load-bearing ones are reached.

## Step 3.4: Persona Lenses (multi-perspective grill)

Run the plan past five reviewer personas; each catches a different failure class, and a design that survives all five is far harder to break than one grilled from a single angle. Walk the lenses, generate the sharpest 1–3 questions per persona that the plan does not already answer, and fold them into `branches` (tag each with its `persona` and preserve or add `depends_on` edges). Apply Step 3's dependency-closed 15-cap again, then revalidate dependency ids and acyclicity. A question a persona answers from the codebase/KB is resolved in Step 4 like any other branch; only genuine forks reach the user.

Lead with whichever personas matter most for this design (a CLI util needs little PM/SRE; a tenant-facing service needs all five). End with a **pre-mortem**: assume it's six months out and this design caused an incident — what was the cause? Treat each answer as a branch.

**ARCHITECT** — scalability, coupling, boundaries, tech debt
- Where are the system boundaries, and which interfaces are load-bearing — what breaks if one moves?
- Blast radius of coupling: if component X changes, how many others must change with it?
- Which competing quality attribute did this sacrifice (modifiability vs performance vs availability), and was that explicit?
- Does this belong in this service/codebase, or is it a library/platform concern leaking in?
- What's the 10× failure point — which dimension (data, traffic, fan-out) saturates first?
- What tech debt does this create, and what's the documented paydown trigger?

**PRODUCT MANAGER** — user value, scope, requirements, edge cases, metrics
- What user problem does this solve, and how do we know it's prioritized over what we're not building?
- What's explicitly out of scope — is the omission a recorded decision or a silent gap?
- Which non-happy-path users does this degrade for, and is that acceptable?
- What's the success metric, and what threshold would tell us this was the wrong bet?
- What's the cost of being wrong, and how reversible is the decision?

**SENIOR / STAFF ENGINEER** — correctness, maintainability, testability, ops
- What's the simplest thing that works — where are we solving a hypothetical future problem?
- Walk the concurrency / ordering / partial-failure cases; which can corrupt state?
- Will the tests actually fail when this breaks, or are they asserting the mock?
- Six months out, what will a new engineer misread — does the code explain *why*, not *what*?
- What's the rollback story if this ships and is wrong?
- Which invariant, if violated, makes the whole thing unsound — and where is it enforced?

**SRE / OPERABILITY** — reliability, observability, rollout
- How does this degrade under dependency failure or overload vs failing hard?
- Can on-call diagnose a 2am incident from the signals this emits, or is it a black box?
- Redundancy / horizontal-scaling story — has failure recovery been tested, not just assumed?
- What new alert does this introduce, and what's its expected false-positive rate?
- Deploy + rollback mechanism, and the blast radius of a bad rollout?

**SECURITY** — STRIDE
- *Spoofing:* how is every actor across each trust boundary authenticated — where can identity be forged?
- *Tampering:* where can data be modified in transit or at rest without detection?
- *Repudiation:* if a privileged action is disputed, what audit trail proves who did it?
- *Information Disclosure:* impact if an attacker reads this store / payload — is it tenant-isolated?
- *Denial of Service:* cheapest request that consumes the most work — where's the rate limit?
- *Elevation of Privilege:* where could an unprivileged user reach privileged paths; is least-privilege enforced at each hop?

When recording resolutions (Step 6), keep the `persona` tag and a **severity** — `blocking` (real correctness/security/data risk), `suggestion`, or `nit` — so downstream skills can triage. Don't over-escalate: `blocking` needs concrete evidence the design is broken, not a stylistic preference.

## Step 3.5: Codex Mutual Grill Round 1 (cross-model questions)

**Gate per `.claude/docs/codex-review.md → Prerequisite`** — skip cleanly to Step 4 if the MCP isn't loaded; never use a Claude fallback (the value here is finding attacks Claude's own training would miss).

Invoke the Codex MCP with the `mutual-questioner` mode contract from `.claude/docs/codex-review.md`:

- `cwd` = `repo_path` (so Codex can sanity-check claims against actual files)
- `prompt` = the full effort doc body (the design under review), plus a bullet list of known KB / past-decision constraints surfaced during Step 1
- `developer-instructions` = the `mutual-questioner` template verbatim
- `sandbox` = `read-only`
- `config` = `{"model_reasoning_effort": "xhigh"}` (grill is the right place to spend the extra thinking budget — adversarial design review is the exact task this model setting was tuned for)

Capture both `content` and `threadId`; hold the thread id as `codex_grill_thread_id` for Step 5.5.

Parse `content` as a numbered list of questions (`QUESTION / WHY / EVIDENCE NEEDED / DEFAULT IF EVIDENCE MATCHES`). For each question:

1. **Deduplicate** against the existing `branches` list. If the question maps to a branch already extracted in Step 3, merge it, mark the existing branch with source `[claude+codex]` for a confidence bump, and preserve the union of their `depends_on` edges.
2. **Append new questions as branches**, each tagged `[codex]`, with a stable `id`, `topic` = a short label, `why-it-matters` = the WHY line, `evidence_needed` = the EVIDENCE NEEDED line, `recommended_default` = the DEFAULT line when present, and `depends_on` inferred by the Step 3 rule.
3. **Respect the 15-branch cap**. If Codex pushes total branches past 15, keep the highest-load-bearing dependency-closed set and move the rest, plus their transitive dependents, into `## Open after grill`. Revalidate dependency ids and acyclicity after the merge/cap. Never silently drop a Codex question; surface it.

Step 4 then runs unchanged except for one rule: for `[codex]` branches, exhaust the evidence named by Codex (`codebase / config / CLI / pipeline / KB / Jira`) before asking the user. The user should only see a question when both Claude/NASE and Codex cannot answer from available evidence or when a stakeholder decision is genuinely required.

## Step 4: Grill Loop (frontier rounds)

Work the decision tree in **rounds**, not one question at a time. Compute the **frontier** from the branch graph: it is every unresolved branch whose `depends_on` ids are all resolved. These are the decisions you can resolve *now* without guessing at answers you haven't heard yet. A branch whose resolution depends on another still-open branch is not on the frontier; it belongs to a later round. If a branch is deferred, move all of its transitive dependents to `open_after_grill` instead of treating the missing decision as settled. Resolve the whole current frontier each round (facts first, then a single batched ask), then recompute the frontier and repeat. This front-loads evidence lookups and cuts the user's turn count versus asking serially. (Adapted from mattpocock/skills `batch-grill-me`; see `workspace/kb/general/workflow.md` §2026-07-16.)

### 4a. Classify the frontier

For every branch on the current frontier, classify how it can be resolved:
- **codebase-answerable** — can be answered by reading the repo (file structure, existing patterns, current behavior)
- **config-answerable** — answered by KB / CLAUDE.md / Confluence runbooks
- **user-answerable** — only the user / stakeholder can decide

### 4b. Resolve facts before asking (codebase + config branches) — parallel, non-blocking

Finding *facts* is the agent's job, never the user's. Dispatch codebase/config lookups for the frontier **in parallel** (one read-only `lookup` sub-agent per independent branch, or batched Grep/Read/Glob in `repo_path`), and **don't block the round on them**: a running exploration is an unsettled prerequisite, so only the branches *downstream* of that exploration wait — ask the rest of the frontier now.

- codebase-answerable → resolve via Grep / Read / Glob in `repo_path`; record the evidence-backed decision in `grill_resolutions` with file/line evidence. Never ask the user to confirm what the codebase answers.
- config-answerable → read the relevant KB / CLAUDE.md / Confluence runbook; record with the source reference. Never ask the user to confirm documented constraints.

Only fall through to 4c for branches that are genuinely user-answerable, or where evidence lookup revealed a real fork with 2+ valid paths and no clear local precedent.

### 4c. Ask the frontier's user-answerable branches (batched round)

Batch the round's user-answerable branches into a **single `AskUserQuestion` call**, up to the harness cap of 4 questions per call and never more than the Step 5 budget remaining (`25 - user-answerable branches already resolved`). If the frontier exceeds either limit, ask the most load-bearing branches that fit and carry the rest into the next round. Each question is still one single decision (never compound) and always leads with a recommended answer. Use the structured per-question form:

```
question: "{Question — clear, single-decision, no compound 'and']}"
header: "{≤12 char tag}"
options:
  - label: "Recommended: {answer}" , description: "{1 sentence why + main tradeoff}"
  - label: "{alt 1}"               , description: "{when this would be better}"
  - label: "{alt 2}"               , description: "{when this would be better}"  # optional — drop if no second alt
```

Rules:
- Always include a recommended answer in the first slot — never ask without an opinion. If you genuinely can't form one, that's a signal to do more codebase exploration before asking.
- 1-3 alts is the working range. Drop "alt 2" when the decision is binary (sync vs async). Drop both alts when the question is yes/no on a recommendation — fall through to harness-added "Other" for disagreement.
- The harness-added "Other" is the user's free-form escape hatch and the signal-channel for termination (Step 5).
- Never compound questions. "Should X be sync or async, and where does it live?" → split into two grill iterations.
- **`<thinking>` invite for ambiguous user answers**: if a prior user answer was vague, contradictory, or you sense the user's mental model differs from yours in ways the option list cannot capture, append a one-line note before the `AskUserQuestion`:
  > `If you'd rather walk me through the reasoning than pick an option, wrap it in <thinking>...</thinking> in your reply and I'll parse the shape instead of asking again.`

  Trigger only when needed — overuse trains the user to ignore it. Good triggers: previous "Other" with a long free-form rebuttal, two consecutive grill iterations resolving the same branch differently, the recommended answer scoring < 60% in your own confidence check.

### 4d. Record + recompute frontier

After each round's answers:
0. Apply the Step 5 stop-token rule first. If it matches, record the same batch's non-termination answers as specified there, then skip the steps below and end the grill.
1. Append to internal buffer `grill_resolutions: [{persona, severity, topic, question, answer, rationale}]` (Step 6 does the single write; `persona`/`severity` default to `—`/`suggestion` for non-persona branches).
2. Each answered decision reshapes the tree: settled branches push the frontier outward and unblock branches that depended on them. If an answer implies a new follow-up decision, add it as a branch. **Recompute the frontier** and run the next round (4a–4d).

## Step 5: Termination

The loop ends when the frontier is empty — every branch resolved/deferred — or when the user explicitly stops the grill.

If every branch has been handled by evidence lookup, user answer, or `open_after_grill`, proceed to Step 5.5 with `termination = branches exhausted`. Do not ask a synthetic final question just to collect a stop token.

If a user-facing question batch is active, the user can also stop via any question's harness-added `Other` free-form. Evaluate each returned answer independently and match each trimmed `Other` payload (case-insensitive) against this exact-token list:

- `done`
- `enough`
- `stop`
- `done grilling`
- `好了`
- `够了`
- `停`
- `停止`

`good` is **not** a terminator — it's too easily produced as filler ("good, next question"). Require explicit termination.

If any answer matches, record the other non-termination answers returned in the same batch, set `termination` to the first matching stop token in question order, and end the grill before adding follow-up branches or recomputing the frontier. The stop-token answer itself is not a branch resolution. If an `Other` payload does not match (e.g. a long free-form override of the recommendation), treat it as a non-termination answer and continue the loop with it.

Hard cap: 25 user-answerable branches resolved total (across all rounds). If reached without an empty frontier, say so and ask whether to continue or stop. This is a safety bound, not a normal exit.

## Step 5.5: Codex Mutual Grill Round 2 (answer Claude's questions)

Run this step only if Step 3.5 produced `codex_grill_thread_id`. Skip cleanly if the Codex MCP was unavailable or round 1 failed.

Before writing the effort doc, build an updated design snapshot in memory:
- The effort doc body
- The `grill_resolutions` gathered in Step 4
- The implementation constraints distilled so far
- Evidence gathered while resolving branches (file/line, CLI output summary, pipeline/KB/Jira references)

Create 3-7 round-2 questions for Codex. Ask about the revised design, not the original plan. Good questions look like:
- "Given the resolved constraints, is the rollback path still complete?"
- "Does the updated ordering leave any race or partial-deploy hole?"
- "Which remaining question requires human input rather than codebase evidence?"

Invoke `mcp__codex__codex-reply` using the `mutual-answerer` round-2 prompt from `.claude/docs/codex-review.md`:

- `threadId` = `codex_grill_thread_id`
- `prompt` = updated design snapshot + evidence gathered + Claude's round-2 questions

Parse each answer:
- `ANSWER` with `NEW RISK: none` → append a `[codex]` confirmation to `grill_resolutions` only if it adds a concrete implementation constraint.
- `NEW RISK` present → classify and resolve it through the same Step 4 research ladder. If codebase/config/CLI/pipeline/Jira can answer it, resolve it without asking the user. If not, add it to `open_after_grill`.
- `HUMAN INPUT NEEDED` present → first run the research ladder. Only keep it for the user if both Claude/NASE and Codex cannot answer it.
- `BLOCKED` → treat as unresolved only after evidence lookup also fails; otherwise write the evidence-backed answer and note that Codex was blocked.

Do not start a new Codex thread for round 2. The point is to make Codex re-check the updated design against its own first-round questions.

## Step 5.6: Convergence loop

Fixed two rounds under-converge. Empirically (nase design sessions), each successive Codex round can still surface NEW blocking/correctness findings — a design grilled twice was still shipping latent bugs (lagging-atom reads, invalid readiness signals, deeper coupling) that a third round caught. So loop; do not hard-code the round count.

After Step 5.5, if the Codex round produced any NEW `blocking` or `suggestion`-severity finding (a real correctness/design gap, not a nit), revise the design and run another `codex-reply` round on the same `codex_grill_thread_id` with the updated snapshot plus a convergence-check prompt ("ask ONLY where a real blocking/correctness gap remains; otherwise state CONVERGED explicitly"). Repeat.

If Codex was unavailable, start after Step 4 instead: revise the design, then rerun the relevant Step 3.4 persona lenses against the updated snapshot. Record those findings in `grill_resolutions` and repeat only when they add a NEW `blocking` or `suggestion` finding.

Stop when either:
- a full round yields **zero new `blocking`/`suggestion` findings** (only nits, or an explicit `CONVERGED`) — the design is stable, or
- **5 Codex rounds total** have run (hard cap).

Rules:
- **Severity gate** — only `blocking`/`suggestion` re-open the loop; `nit`s are recorded but never trigger another round (else it chases wording forever).
- **Structural-stability check** — evaluate convergence only after the design's shape is stable. A round that changes the shape (new component, new seam, scope change) opens new surface; its findings are the *first* round of the new shape, not proof the old shape "failed to converge". Expect the loop to run longer whenever a round restructures the design.
- **Non-convergence = decompose signal** — if the cap is hit with blocking findings still appearing, do NOT keep grinding: that means the design is too large / entangled to converge as one doc. Recommend splitting into separate, independently-grillable efforts, record the still-open findings in `## Open after grill`, and say so.
- When the Codex MCP is unavailable, the **same loop-until-no-new-blocking rule** governs the persona/self grill: keep running persona passes until one adds no new blocking finding, same 5-pass cap.

## Step 6: Write Back to Effort Doc

Append a single block to `effort_path`. Place it AFTER the `## Lifecycle` section (so lifecycle stays adjacent to frontmatter) and BEFORE any prior `## Grill Session` block (latest-first).

Block format:

```markdown
## Grill Session — {YYYY-MM-DD}

**Repo explored:** `{repo_path}` ({N} codebase lookups, {M} auto-resolutions)
**Branches walked:** {count}
**Termination:** {user signal verbatim, or "branches exhausted"}
**Cleaned:** {N lines auto-removed (superseded/duplicate/session-artifact), M flagged for the user — or "nothing needed cleaning"}

### Resolutions

| # | Persona | Sev | Topic | Question | Decision | Rationale |
|---|---------|-----|-------|----------|----------|-----------|
| 1 | {architect/pm/eng/sre/security/—} | {blocking/suggestion/nit} | {topic} | {question} | {answer} | {1-sentence why} |
| 2 | ... | ... | ... | ... | ... | ... |

### Constraints for implementation

Distill the resolutions into ≤7 imperative constraints downstream skills (e.g. `/nase:fsd`) can read directly:

- {Imperative constraint 1}
- {Imperative constraint 2}
- ...

### Open after grill

Anything still unresolved (codebase exploration was inconclusive, or user deferred):
- {item, if any — else "None."}

### Codex convergence

Include only when Codex rounds ran:
- Rounds completed: {count, 1-5}
- Outcome: {converged / cap reached / blocked}
- Confirmed: {count}
- New risks resolved by evidence: {count}
- Still needs human input: {count}
```

Update lifecycle: append a checked item if the doc didn't already track grill:
```
- [x] Plan grilled — {YYYY-MM-DD}
```

(If a previous grill checked this, do not duplicate. Just rely on the Grill Session timestamp.)

## Step 6.5: Doc Hygiene Pass (auto-cleanup)

An effort doc that has been through several grill/review rounds accumulates cruft — the resolutions you just wrote often supersede older wording, and iterative edits leave duplicates and session-process artifacts. Clean it in the same write-back so the doc stays the durable spec `/nase:fsd` reads, not an audit log of how it got there. Everything here goes through the normal workspace-write-guard diff, so it is reviewable, not silent.

**Auto-remove (safe, mechanical):**
- Wording this grill just **superseded** — once a resolution records the new decision, delete the old line it replaced (e.g. a decision the session overturned). The Grill Session table is the audit trail; the body should state the current decision once.
- **Exact-duplicate** claims/bullets repeated across sections — keep the canonical instance, leave a one-line pointer if it was cross-referenced.
- **Session/process artifacts** that aren't durable design — one-off `workspace/tmp/*` pointers, "appended this session / near end of file"-style meta, transient scaffolding notes.
- **Dead/duplicated non-citation links** - the same artifact URL cited three times: keep one and point to it. Never remove a citation.
- **Resolved `[NEEDS CLARIFICATION]` markers** whose answer is now recorded in a resolution.

**List-only (judgment calls — never auto-delete, surface in the report):**
- A section that looks redundant but carries unique detail, or a transitional subsection (e.g. a "research refinements" block) mostly folded inline but with some unique bits — propose a collapse, let the user decide.

**Never touch:** any MUST / constraint / Success Criterion / Risk / citation, unless a recorded superseding decision explicitly replaces it.

**Consistency check:** if the pass finds two lines asserting different values for the same thing (a drift, e.g. two different thresholds), **flag it, don't silently pick** — surface as a judgment call.

Record the result in the Grill Session block's `**Cleaned:**` line (N auto-removed, M flagged). If nothing needed cleaning, say so — silence is a valid outcome.

## Step 7: Report

Report to the user (conversation language):
- Path of effort doc
- Number of branches walked + lookups + auto-resolutions
- Codex mutual grill status: skipped / {N} rounds / converged / cap reached, plus unresolved human-input count
- 1-line summary of the most load-bearing constraint added
- Suggest next step: `/nase:fsd {slug}` if user is ready to implement, else "Park it — surfaces in /nase:today."

Daily log entry per `.claude/docs/daily-log-format.md` (tag: `grill` — ad-hoc, not in canonical tag table; add to that table if grill becomes a regular workflow):
`grilled {slug} — {N} branches, {top constraint} → effort doc updated`

## Step 8: Follow-up Human Grill Recommendation (when applicable)

For non-trivial designs — 8+ branches in the human grill loop, or designs touching CI/CD pipelines, infra, or cross-team coordination — recommend a **follow-up human grill pass** after the design body is updated with all current resolutions. The first human pass surfaces structural risks (constraints, dependencies, missing requirements); the later follow-up pass — re-reading the updated body — surfaces representational drift that only appears against the revised body: cache key format mismatch between body and resolution, dependsOn ordering, hardcoded artifact names, conditional-cleanup gaps. This is separate from Codex Mutual Grill Round 2 in Step 5.5.

Trigger output (append to Step 7 report when applicable):
> "Recommend a follow-up human grill once the design body is updated — this pass caught {N} structural issues; a later reread typically surfaces representational drift (cache keys, ordering, hardcoded names) only visible against the revised body."

Skip recommendation when the human grill loop had ≤4 branches or the design is purely greenfield code (no infra/CI artifacts to drift against).

## Notes

- The Hard Gate from `/nase:design` still applies: grill writes to the effort doc only. No code edits, no PR, no Jira.
- If the effort doc already contains a `## Grill Session — {today's date}` block, append resolutions to it rather than creating a duplicate same-day block.
- Never ask the user something the codebase or KB can answer (Q5 contract). When in doubt, explore first.
- Recommendations must be opinionated — "I don't know, you choose" is a failure mode. If you genuinely can't form an opinion, that's a signal the branch needs more codebase exploration before asking.
- Codex is a challenger, not the owner. Claude/NASE owns evidence gathering and final write-back; Codex's output is tagged and treated as untrusted until checked.
