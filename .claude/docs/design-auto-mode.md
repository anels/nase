# Auto Mode (`/nase:design --auto`)

End-to-end design-grill-review loop. From requirement to effort doc without interactive prompts. Every open question is researched against the codebase and KB; questions that cannot be answered from available evidence are queued into `## Human Input Required` in the effort doc for the user to fill in after.

## Activation

`$ARGUMENTS` contains `--auto` (anywhere). Strip `--auto` before downstream parsing. `--grill` and `--review` are sub-routines inside this algorithm — if they appear alongside `--auto`, `--auto` wins.

## Hard Gate

Same as base skill: no code, no implementation, no FSD. Only the effort doc is produced.

## No-Ask Contract

**Never use `AskUserQuestion` in auto mode.** For every decision point, execute the Research Ladder first. Only after the ladder is exhausted does a question become unknowable.

| Branch type | Resolution strategy |
|-------------|---------------------|
| codebase-answerable | Execute Grep/Read/Glob in `repo_path`; follow existing conventions |
| config-answerable | Read domain KB file, repo `CLAUDE.md`, Confluence runbooks |
| jira-answerable | Execute `searchJiraIssuesUsingJql`; prior decisions are often in comments |
| effort-answerable | Execute `grep -r` across `workspace/efforts/*.md` |
| unknowable | Add to `human_input_queue` only after all four sources above come back empty |

"Unknowable" means: requires a business/stakeholder decision, involves external team ownership with no documented precedent, or has zero signal across all four research sources. **Exhaust every source before marking unknowable.** A single empty grep is not exhaustion.

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

After all 5: if still no signal, classify as unknowable. When forced to choose between equally valid options with no signal, apply the Design Principles ordering from the base skill and pick the option that best satisfies the leading principle. Log the auto-selection reasoning.

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

After gathering: synthesize context internally. No user interaction — proceed directly to Step 2.

---

## Step 2: Autonomous Design (Phases 2–5, adapted)

Run Phases 2–5 from the base skill with these adaptations:

**Phase 2c** — instead of `AskUserQuestion`: run the Research Ladder. If still unknowable after all 5 sources, add to `human_input_queue` and use the most KB-aligned option as a default assumption. Log: "Auto-assumption: {X} — based on {source}. Will appear in Human Input Required."

**Phase 2e / Implementation / PR Plan** — keep the base skill's PR Packaging Analysis. Auto mode must still write `### Implementation / PR Plan` with `Target PR count: 1` unless a documented split criterion is met. If more than one PR is proposed, run the Research Ladder against the split boundary and include why one coherent PR is worse for review or merge safety.

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
- Items moved to `human_input_queue` stay in `## Open Questions` with the note: "→ Queued for Human Input Required"

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

For each FAIL/WEAK criterion, for each specific gap: run the Research Ladder (5 sources), fix in-place. If Research Ladder exhausted and still unknowable → add to `human_input_queue`.

### 4d. Re-score and iterate

Re-evaluate Quality Criteria. If APPROVED: exit loop. If not APPROVED and iterations < 3: increment and repeat from 4a.

After 3 iterations: exit with status `max-iterations`. Remaining issues go to Human Input Required.

---

## Step 5: Write Final Effort Doc

### 5a. Apply all revisions

Finalize the effort doc with all in-place changes from Steps 3–4. Write (or overwrite) `workspace/efforts/{slug}.md`.

### 5b. Append `## Human Input Required`

Append only if `human_input_queue` is non-empty. Place AFTER `## Open Questions` and BEFORE `## Lifecycle`.

```markdown
## Human Input Required

These questions cannot be resolved from the codebase, KB, or Jira context. Provide your answers below, then run `/nase:design --review {slug}` before starting implementation.

| # | Question | Why it needs you | What was tried | Default assumption used | Affects |
|---|----------|-----------------|----------------|------------------------|---------|
| 1 | {question} | {business/stakeholder decision — no codebase signal} | {sources checked} | {conservative default} | {design section} |
```

Each row must be a concrete, actionable question — not "clarify scope" but "Should the export endpoint support CSV only, or also Excel? Default: CSV-only (matches existing download endpoints in `src/api/export.ts`)."

### 5c. Update lifecycle

```markdown
- [x] Auto-design completed — {YYYY-MM-DD} ({N} review iterations, {M} questions auto-resolved, {K} need human input)
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
- Stats: {N} review rounds, {M} branches grilled ({X} resolved, {K} need human input)
- If `## Human Input Required` is non-empty:
  > **{K} questions await your input** — listed in `## Human Input Required` in the effort doc. Run `/nase:design --review {slug}` and the review-mode skill will walk you through each one via `AskUserQuestion` (one question per turn, with the design's default highlighted as Recommended). See `design-review-mode.md` Step 1b for the interactive resolution flow.
- If APPROVED with no `## Human Input Required` entries:
  > Design approved with no open questions. Run `/nase:fsd {slug}` when ready to implement.

Daily log entry (per `.claude/docs/daily-log-format.md`):
`auto-design {slug} — grill: {M} branches ({X} resolved, {K} queued), {N} review rounds → {verdict}`

---

## Notes

- **Step 3 is unconditional** — the Codebase Grill Pass runs every time, regardless of whether the initial design looks complete. This is intentional: it surfaces hidden constraints before review, not after.
- **Execute before concluding** — if the Research Ladder says "check the codebase," that means calling Grep/Read/Glob, not reasoning about what might be there.
- **Auto-assumptions are conservative** — when forced to pick, prefer the simpler, more reversible option and flag it for review.
- **If `--auto` + `--review`** — run review only (skip Steps 1–3), apply no-ask contract throughout, produce updated effort doc with Human Input Required section.
- **Hard Gate still applies** — no code edits, no FSD invocation, no PRs. Only the effort doc is written.
