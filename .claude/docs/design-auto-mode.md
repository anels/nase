# Auto Mode (`/nase:design` default, or explicit `--auto`)

## Contents

- Activation
- Hard Gate
- Language preflight (Step 0 - MUST run before Step 1, non-negotiable)
- No-Ask Contract (mid-pipeline)
- Execute, Don't Narrate
- Research Ladder (per open question)
- Step 1: Deep Context Gathering (Phase 1, expanded)
- Step 2: Autonomous Design (Phases 2–5, adapted)
- Step 3: Codebase Grill Pass (mandatory - always runs)
- Step 4: Auto-Review Loop (max 3 iterations)
- Step 4.5: Resolve Human Input (the one interactive batch)
- Step 5: Write Final Effort Doc
- Human Input Required
- Step 6: Report
- Notes

End-to-end research-grill-review loop. From requirement to effort doc without turn-by-turn prompts. Every open question is researched against the codebase, KB, and external docs; questions that still cannot be answered from evidence are collected and asked in **one `AskUserQuestion` batch at the very end** (Step 4.5), before the final report is written. Anything the user defers there stays in `## Human Input Required` in the effort doc.

## Activation

This is the **default** mode when `/nase:design` runs with no flag and the slug does not already exist in `workspace/efforts/` (an existing slug routes to Review Mode). It also runs on explicit `--auto` when no higher-priority flag is present. Base mode detection routes `--grill` / `--review` to Grill/Review Mode before Auto Mode. Strip `--auto` before downstream parsing. Use `--interactive` to opt out into the turn-by-turn flow.

## Hard Gate

Same as base skill: no code, no implementation, no FSD. Only the effort doc is produced.

## Language preflight (Step 0 — MUST run before Step 1, non-negotiable)

Read `workspace/config.md` → `## Language`. Write all chat output — the Step 4.5 `AskUserQuestion` batch and the Step 6 report — in the `conversation:` value; write the effort doc in `output:`. English stays only for code identifiers, file paths, PR/Jira IDs, repo names, and structural labels. If config is missing or has no `## Language` section, default English and note it once. Do not defer this to Step 6 — every user-facing string the pipeline emits depends on it.

## No-Ask Contract (mid-pipeline)

**Never use `AskUserQuestion` mid-pipeline.** For every decision point, execute the Research Ladder first. Collect anything still unknowable into `human_input_queue` and keep going — do not stop to ask. The **one** place auto mode talks to the user is **Step 4.5**, which batches the whole queue into `AskUserQuestion` at the end, after research and grill have shrunk it to only what genuinely needs a human. Only after the ladder is exhausted does a question reach that batch.

| Branch type | Resolution strategy |
|-------------|---------------------|
| codebase-answerable | Execute Grep/Read/Glob in `repo_path`; follow existing conventions |
| config-answerable | Read domain KB file, repo `CLAUDE.md`, Confluence runbooks |
| jira-answerable | Execute `searchJiraIssuesUsingJql`; prior decisions are often in comments |
| effort-answerable | Execute `grep -r` across `workspace/efforts/*.md` |
| unknowable | Add to `human_input_queue` only after all applicable research sources above come back empty |

"Unknowable" means: requires a business/stakeholder decision, involves external team ownership with no documented precedent, or has zero signal across all applicable research sources. **Exhaust every source before marking unknowable.** A single empty grep is not exhaustion.

## Execute, Don't Narrate

**If you can run it — run it. Do not write "I would check X" or "we could look at Y." Just look.**

This applies to every research step in this algorithm. Grep, Read, Glob, searchJiraIssuesUsingJql — if a tool can answer the question, call it. Speculation about what the codebase might contain is not evidence.

## Research Ladder (per open question)

Run this sequence before giving up on any question:

1. **Codebase** — execute Grep/Glob/Read in `repo_path`. Look for: existing patterns, similar features, constants, schema definitions, interface signatures, test expectations, recent commits touching the relevant area.
2. **KB** — read the domain KB file. Look for: architecture decisions, constraints, ownership, past choices on similar problems.
3. **CLAUDE.md** — read the repo's coding standards for relevant constraints.
4. **Jira** — execute `searchJiraIssuesUsingJql` for related tickets using keyword fragments from the question. Read comments on the top 2-3 hits.
5. **Effort docs** — execute `grep -r` across `workspace/efforts/*.md` for related design decisions.
6. **External docs** — when the question is about an external library/SDK/API/platform behavior, run the source ladder in `.claude/docs/design-research.md → Part A`: official docs (`context7`/`ms-learn` MCP or `WebSearch`+`WebFetch`), dependency source/changelog at the pinned version, then issue trackers. Cite the URL/source; apply the comprehension gate.

After all 6: if still no signal, classify as unknowable. When forced to choose between equally valid options with no signal, apply the Design Principles ordering from the base skill and pick the option that best satisfies the leading principle. Log the auto-selection reasoning.

---

## Step 1: Deep Context Gathering (Phase 1, expanded)

Run Phase 1 from the base skill, with additional parallel research:

**1a–1e** from base (parse idea, KB lookup, repo state, existing efforts, Jira context) — run as written.

**Additional parallel research:**

**1f. Related effort docs** — grep `workspace/efforts/*.md` for terms from $ARGUMENTS. Extract: constraints established, approaches rejected, open questions left by prior designs.

**1g. Codebase archaeology** — for the main domain area, find the 5 most recently modified relevant files and read them. This surfaces in-flight patterns and active conventions:
```bash
git -C {repo} log --oneline --diff-filter=M --name-only -- {relevant-paths} | head -20
```

**1h. Epic/feature context** — if Atlassian MCP is available, search for open epics or stories that might scope this work:
```
project in (...) AND issuetype in (Epic, Story) AND (summary ~ "{keywords}") AND status != Done ORDER BY updated DESC
```

**1i. External research** — run `.claude/docs/design-research.md → Part A` for any external-dependency-leaning approach: official docs, dependency source/changelog (pinned version), issue trackers, Q&A, blogs. Ground every external claim with a URL/source; run the debias pass before locking a direction.

**1j. Plan-phase gates** — run the applicable gates from `.claude/docs/design-research.md → Part B`: bug-repro + root-cause (bug-shaped work), prod-data validation (scale/usage assumptions), unit-test-gap analysis (any code change). Resolve from evidence where possible; queue genuine unknowns.

After gathering: synthesize context internally. No user interaction — proceed directly to Step 2.

---

## Step 2: Autonomous Design (Phases 2–5, adapted)

Run Phases 2–5 from the base skill with these adaptations:

**Phase 2c** — instead of `AskUserQuestion`: run the Research Ladder. If still unknowable after the full ladder, add to `human_input_queue` and use the most KB-aligned option as a default assumption. Log: "Auto-assumption: {X} — based on {source}. Queued for Step 4.5 human input."

**Phase 2e gates / 2f PR Packaging** — run the base skill's Phase 2e plan-phase gates and Phase 2f PR Packaging Analysis. Auto mode must still write the junior-implementable `### Implementation Plan` (per-step files/tests/done + dependency graph, base skill Phase 4 / `design-research.md` Part C) and `### PR Plan` with `Target PR count: 1` unless a documented split criterion is met. If more than one PR is proposed, run the Research Ladder against the split boundary and include why one coherent PR is worse for review or merge safety.

**Phase 3, Step 5** — instead of `AskUserQuestion`: auto-select the recommended option (first in the list). Log internally: "Auto-selected: Option {N} — {rationale}." If the recommendation is a hybrid, define it explicitly using the Design Principles ordering.

**Phase 5c** — skip. Do not create a Jira ticket in auto mode.

**Phase 5d** — after writing the effort doc, proceed directly to Step 3 (Codebase Grill Pass). Do not stop here.

---

## Step 3: Codebase Grill Pass (mandatory — always runs)

This step runs unconditionally after the effort doc is first written. It does not depend on review scores. Even if Phase 4b self-review gave all PASS, the grill still runs.

**Purpose:** actively resolve every open question and design ambiguity through tool execution before submitting the doc for review. This is not a reasoning exercise — it is a research execution phase.

### 3a. Collect all branches

Gather every item that needs investigation:
- All items in `## Open Questions` in the effort doc
- Any ambiguous wording spotted during Phase 4b ("we could", "either X or Y", "TBD", "later")
- Missing invariants the design asserts without specifying: error modes, retry semantics, idempotency, ordering, concurrency, rollout, observability
- **Persona-lens questions** — walk the design through the five lenses + pre-mortem in `.claude/docs/design-grill-mode.md → Persona Lenses` (architect / PM / senior-eng / SRE / security) and add the sharpest unanswered questions, tagged with their persona

Cap at 15 branches. Prioritize by load-bearingness: security, data-loss risk, irreversibility, cross-team coordination first.

### 3b. For each branch: classify then execute

**Do not reason about what you might find. Run the tools and look.**

Classify each branch:

**codebase-answerable** → execute immediately:
```
grep -r "{keyword}" {repo_path} --include="*.{ext}" -l
```
Then read the relevant files. Extract the concrete answer. Apply it to the design. Log what file:line resolved it.

**config-answerable** → execute immediately:
Read the relevant KB section, `CLAUDE.md`, or Confluence runbook. Extract the constraint. Apply it to the design.

**jira-answerable** → execute immediately:
```
searchJiraIssuesUsingJql: project in (...) AND (summary ~ "{keyword}" OR description ~ "{keyword}") ORDER BY updated DESC
```
Read comments on the top 2-3 hits. Extract the prior decision. Apply it to the design.

**unknowable** (only after executing all applicable sources above) → add to `human_input_queue`:
```
question: "{Concrete, specific question}"
why_unknowable: "{What was tried and why it came back empty}"
what_was_tried: ["{grep command + result}", "{JQL + result}", ...]
default_assumption: "{Conservative default applied in the design}"
design_section: "{Which section this affects}"
```

### 3c. Update the effort doc

After working through all branches:
- Apply all resolutions to the relevant design sections in-place
- Remove resolved items from `## Open Questions` and note what resolved each one (e.g., "Resolved via `src/api/routes.ts:42` — existing pattern uses pagination")
- Items moved to `human_input_queue` stay in `## Open Questions` with the note: "→ Queued for Step 4.5 human input"

Proceed to Step 4.

---

## Step 4: Auto-Review Loop (max 3 iterations)

Runs on the effort doc updated by the Codebase Grill Pass.

### 4a. Score the design

Score via the fresh-context subagent defined in the base skill's Phase 4b (read-only `verifier`; gets the draft + criteria table + cited references only, never your reasoning). For each FAIL or WEAK, record the specific gap.

Also check: has any codebase or KB data gathered in Steps 1–3 revealed assumptions in the design that don't hold?

### 4b. Exit condition

All criteria PASS or ≤1 WEAK → verdict: **APPROVED**. Exit loop → Step 5.

### 4c. Resolve remaining issues

For each FAIL/WEAK criterion, for each specific gap: run the Research Ladder, fix in-place. If the ladder is exhausted and the issue is still unknowable → add to `human_input_queue`.

### 4d. Re-score and iterate

Re-evaluate Quality Criteria. If APPROVED: exit loop. If not APPROVED and iterations < 3: increment and repeat from 4a.

After 3 iterations: exit with status `max-iterations`. Remaining issues go to `human_input_queue` for Step 4.5; anything deferred there becomes Human Input Required.

---

## Step 4.5: Resolve Human Input (the one interactive batch)

This is the single point where auto mode talks to the user. By now research + grill + review have shrunk `human_input_queue` to only what genuinely needs a human — business/stakeholder calls, decisions with no codebase/KB/Jira/external signal. Ask them all here, together, before the final write.

**If `human_input_queue` is empty: skip this step entirely** — write the doc and report with no prompt. The best auto run asks nothing.

**If non-empty:**

1. Convert each queued item into an `AskUserQuestion` entry:
   - `question` — the concrete, specific question (not "clarify scope" but "Should the export endpoint support CSV only, or also Excel?").
   - `header` — ≤12-char tag.
   - `options` — **first option = the default assumption the design already applied, suffixed " (Recommended)"**, its `description` quoting *why* (the evidence/principle behind the auto-choice). Then the real alternative(s), each `description` stating the trade-off. The harness adds "Other" as the free-form escape.
2. **Batch** — group related entries into the fewest `AskUserQuestion` calls the harness supports. If the queue is large, order by load-bearingness (security / data-loss / irreversibility / cross-team first) so the most consequential are asked first.
3. After each answer: apply the decision to the relevant design sections, and record it in a `### Resolved Decisions` block (columns: `#`, `Question`, `Decision`, `Applied to`) for the audit trail.
4. Anything the user skips or answers with "Other → defer" stays in `human_input_queue` for the `## Human Input Required` section (Step 5b). Everything answered is removed from the queue.

This replaces the old "queue everything to the doc and tell the user to run `--review`" behavior: the user gets asked once, at the end, and the written doc already reflects their answers.

## Step 5: Write Final Effort Doc

### 5a. Apply all revisions

Finalize the effort doc with all in-place changes from Steps 3–4.5. Write (or overwrite) `workspace/efforts/{slug}.md`.

### 5b. Append `## Human Input Required`

Append only if `human_input_queue` is still non-empty **after Step 4.5** — i.e. the user deferred these at the end-of-run prompt (skipped, or "Other → defer"). Most questions should be resolved by then; this section is the leftover. Place AFTER `## Open Questions` and BEFORE `## Lifecycle`.

```markdown
## Human Input Required

You deferred these at the end-of-run prompt. Provide answers below, then run `/nase:design --review {slug}` before starting implementation.

| # | Question | Why it needs you | What was tried | Default assumption used | Affects |
|---|----------|-----------------|----------------|------------------------|---------|
| 1 | {question} | {business/stakeholder decision — no codebase signal} | {sources checked} | {conservative default} | {design section} |
```

Each row must be a concrete, actionable question — not "clarify scope" but "Should the export endpoint support CSV only, or also Excel? Default: CSV-only (matches existing download endpoints in `src/api/export.ts`)."

### 5c. Update lifecycle

```markdown
- [x] Auto-design completed — {YYYY-MM-DD} ({N} review iterations, {M} auto-resolved, {A} answered at end-of-run prompt, {K} deferred)
```

### 5d. Update todo.md

Append to `workspace/tasks/todo.md` under `## Pending`:
```markdown
- [ ] **{Title}** — {one-line summary} → `workspace/efforts/{slug}.md`
```

---

## Step 6: Report

Report to user (conversation language). Include:

- Effort doc path
- Final verdict: APPROVED or max-iterations-reached
- Stats: {N} review rounds, {M} branches grilled ({X} resolved from evidence), {A} questions answered at the end-of-run prompt, {K} deferred
- If the user deferred questions (`## Human Input Required` non-empty):
  > **{K} questions still open** — you deferred these at the prompt; they're in `## Human Input Required`. Run `/nase:design --review {slug}` to resolve them before implementing.
- If APPROVED with nothing deferred:
  > Design approved with no open questions. Run `/nase:fsd {slug}` when ready to implement.

Daily log entry (per `.claude/docs/daily-log-format.md`):
`auto-design {slug} — grill: {M} branches ({X} resolved), {A} asked/{K} deferred, {N} review rounds → {verdict}`

---

## Notes

- **Step 3 is unconditional** — the Codebase Grill Pass runs every time, regardless of whether the initial design looks complete. This is intentional: it surfaces hidden constraints before review, not after.
- **Execute before concluding** — if the Research Ladder says "check the codebase," that means calling Grep/Read/Glob, not reasoning about what might be there.
- **Auto-assumptions are conservative** — when forced to pick, prefer the simpler, more reversible option and flag it for review.
- **If `--auto` + `--review`** — this should not reach Auto Mode; base mode detection routes to Review Mode first.
- **Hard Gate still applies** — no code edits, no FSD invocation, no PRs. Only the effort doc is written.
