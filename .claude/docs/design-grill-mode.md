# Grill Mode (`/nase:design --grill`)

Stress-test an existing plan via relentless one-question-at-a-time interview. Goal: walk every branch of the decision tree until shared understanding, recording resolutions back to the effort doc so `/nase:fsd` can pick up the constraints.

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

## Step 3: Build Decision Tree

Read the plan content (effort doc body or raw text). Extract every branch where a real decision is implied or unresolved. Sources of branches:

- Explicit `## Open Questions` section → each item is a branch.
- Ambiguous wording in design body ("we could", "either X or Y", "TBD", "later") → each is a branch.
- Missing constraints — invariants the plan asserts without specifying (error mode, retry semantics, idempotency, ordering, concurrency, schema migration, rollout, observability, ownership).
- Architectural choices the plan glosses over — interface shape, seam location, data path.
- Review packaging ambiguity — proposed multi-PR split without a merge/release/owner boundary, missing `Target PR count`, or implementation phases being treated as PRs without justification.

Output internally: a list `branches: [{topic, why-it-matters}]`. Cap at 15 top-level branches; if more candidates exist, prioritize by load-bearingness (security, data-loss risk, irreversibility, cross-team coordination) and surface the rest in `## Open after grill`. The 15-cap protects the 25-iteration budget in Step 5 from being burned on shallow branches before the load-bearing ones are reached.

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

1. **Deduplicate** against the existing `branches` list. If the question maps to a branch already extracted in Step 3, merge — mark the existing branch with source `[claude+codex]` for a confidence bump.
2. **Append new questions as branches**, each tagged `[codex]`, with `topic` = a short label, `why-it-matters` = the WHY line, `evidence_needed` = the EVIDENCE NEEDED line, and `recommended_default` = the DEFAULT line when present.
3. **Respect the 15-branch cap**. If Codex pushes total branches past 15, drop the lowest-load-bearingness items (regardless of source) into `## Open after grill`. Never silently drop a Codex question — surface it.

Step 4 then runs unchanged except for one rule: for `[codex]` branches, exhaust the evidence named by Codex (`codebase / config / CLI / pipeline / KB / Jira`) before asking the user. The user should only see a question when both Claude/NASE and Codex cannot answer from available evidence or when a stakeholder decision is genuinely required.

## Step 4: Grill Loop (one question at a time)

For each branch (deepest first when branches depend on each other):

### 4a. Classify

For the next branch, classify how it can be resolved:
- **codebase-answerable** — can be answered by reading the repo (file structure, existing patterns, current behavior)
- **config-answerable** — answered by KB / CLAUDE.md / Confluence runbooks
- **user-answerable** — only the user / stakeholder can decide

### 4b. Resolve before asking (codebase + config branches)

If codebase-answerable: use Grep / Read / Glob in `repo_path` to find the answer. Record the evidence-backed decision directly in `grill_resolutions` with file/line evidence and proceed to the next branch. Do not ask the user to confirm something the codebase already answers.

If config-answerable: read the relevant KB, CLAUDE.md, or Confluence runbook. Record the evidence-backed decision directly in `grill_resolutions` with the source reference and proceed to the next branch. Do not ask the user to confirm documented constraints.

Only fall through to step 4c when the branch is genuinely user-answerable, or when codebase/config exploration revealed a real fork with 2+ valid paths and no clear local precedent.

### 4c. Ask one question with a recommendation

Use `AskUserQuestion` with the structured form:

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

### 4d. Record + drill down

After each answer:
1. Append to internal buffer `grill_resolutions: [{topic, question, answer, rationale}]` (Step 6 does the single write).
2. If the answer implies a follow-up decision, push that as the next branch.

## Step 5: Termination

The loop ends when all branches have been resolved/deferred, or when the user explicitly stops the grill.

If every branch has been handled by evidence lookup, user answer, or `open_after_grill`, proceed to Step 5.5 with `termination = branches exhausted`. Do not ask a synthetic final question just to collect a stop token.

If a user-facing question is active, the user can also stop via the harness-added `Other` free-form. Match the entire trimmed payload (case-insensitive) against this exact-token list:

- `done`
- `enough`
- `stop`
- `done grilling`
- `好了`
- `够了`
- `停`
- `停止`

`good` is **not** a terminator — it's too easily produced as filler ("good, next question"). Require explicit termination.

If the payload is anything else (e.g. a long free-form override of the recommendation), treat it as a non-termination "Other" answer and continue the loop with that answer.

Hard cap: 25 iterations. If reached without termination, say so and ask whether to continue or stop. This is a safety bound, not a normal exit.

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

## Step 6: Write Back to Effort Doc

Append a single block to `effort_path`. Place it AFTER the `## Lifecycle` section (so lifecycle stays adjacent to frontmatter) and BEFORE any prior `## Grill Session` block (latest-first).

Block format:

```markdown
## Grill Session — {YYYY-MM-DD}

**Repo explored:** `{repo_path}` ({N} codebase lookups, {M} auto-resolutions)
**Branches walked:** {count}
**Termination:** {user signal verbatim, or "branches exhausted"}

### Resolutions

| # | Topic | Question | Decision | Rationale |
|---|-------|----------|----------|-----------|
| 1 | {topic} | {question} | {answer} | {1-sentence why} |
| 2 | ... | ... | ... | ... |

### Constraints for implementation

Distill the resolutions into ≤7 imperative constraints downstream skills (e.g. `/nase:fsd`) can read directly:

- {Imperative constraint 1}
- {Imperative constraint 2}
- ...

### Open after grill

Anything still unresolved (codebase exploration was inconclusive, or user deferred):
- {item, if any — else "None."}

### Codex round 2

Include only when Step 5.5 ran:
- Confirmed: {count}
- New risks resolved by evidence: {count}
- Still needs human input: {count}
```

Update lifecycle: append a checked item if the doc didn't already track grill:
```
- [x] Plan grilled — {YYYY-MM-DD}
```

(If a previous grill checked this, do not duplicate. Just rely on the Grill Session timestamp.)

## Step 7: Report

Report to the user (conversation language):
- Path of effort doc
- Number of branches walked + lookups + auto-resolutions
- Codex mutual grill status: skipped / round 1 only / round 1 + round 2, plus unresolved human-input count
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
