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

Output internally: a list `branches: [{topic, why-it-matters}]`. Cap at 15 top-level branches; if more candidates exist, prioritize by load-bearingness (security, data-loss risk, irreversibility, cross-team coordination) and surface the rest in `## Open after grill`. The 15-cap protects the 25-iteration budget in Step 5 from being burned on shallow branches before the load-bearing ones are reached.

## Step 4: Grill Loop (one question at a time)

For each branch (deepest first when branches depend on each other):

### 4a. Classify

For the next branch, classify how it can be resolved:
- **codebase-answerable** — can be answered by reading the repo (file structure, existing patterns, current behavior)
- **config-answerable** — answered by KB / CLAUDE.md / Confluence runbooks
- **user-answerable** — only the user / stakeholder can decide

### 4b. Resolve before asking (codebase + config branches)

If codebase-answerable: use Grep / Read / Glob in `repo_path` to find the answer. Present finding to user as a confirmation, not an open question:

> "Looking at `{file}:{line}`, the existing pattern is {X}. I'll follow that. OK to confirm?"

Use `AskUserQuestion` with options: `[Confirm / Override / Investigate further]`.

If config-answerable: read the relevant KB or CLAUDE.md, present as confirmation similarly.

Only fall through to step 4c when the branch is genuinely user-answerable, or when codebase exploration revealed a real fork.

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

### 4d. Record + drill down

After each answer:
1. Append to internal buffer `grill_resolutions: [{topic, question, answer, rationale}]` (Step 6 does the single write).
2. If the answer implies a follow-up decision, push that as the next branch.

## Step 5: Termination

The loop ends ONLY when the user signals completion via the harness-added `Other` free-form on any question. Match the entire trimmed payload (case-insensitive) against this exact-token list:

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

## Step 6: Write Back to Effort Doc

Append a single block to `effort_path`. Place it AFTER the `## Lifecycle` section (so lifecycle stays adjacent to frontmatter) and BEFORE any prior `## Grill Session` block (latest-first).

Block format:

```markdown
## Grill Session — {YYYY-MM-DD}

**Repo explored:** `{repo_path}` ({N} codebase lookups, {M} confirmations)
**Branches walked:** {count}
**Termination:** {user signal verbatim}

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
```

Update lifecycle: append a checked item if the doc didn't already track grill:
```
- [x] Plan grilled — {YYYY-MM-DD}
```

(If a previous grill checked this, do not duplicate. Just rely on the Grill Session timestamp.)

## Step 7: Report

Report to the user (conversation language):
- Path of effort doc
- Number of branches walked + lookups + confirmations
- 1-line summary of the most load-bearing constraint added
- Suggest next step: `/nase:fsd {slug}` if user is ready to implement, else "Park it — surfaces in /nase:today."

Daily log entry per `.claude/docs/daily-log-format.md` (tag: `grill` — ad-hoc, not in canonical tag table; add to that table if grill becomes a regular workflow):
`grilled {slug} — {N} branches, {top constraint} → effort doc updated`

## Notes

- The Hard Gate from `/nase:design` still applies: grill writes to the effort doc only. No code edits, no PR, no Jira.
- If the effort doc already contains a `## Grill Session — {today's date}` block, append resolutions to it rather than creating a duplicate same-day block.
- Never ask the user something the codebase or KB can answer (Q5 contract). When in doubt, explore first.
- Recommendations must be opinionated — "I don't know, you choose" is a failure mode. If you genuinely can't form an opinion, that's a signal the branch needs more codebase exploration before asking.
