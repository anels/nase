# Auto Mode (`/nase:design` default, or explicit `--auto`)

## Contents

- Activation
- Hard Gate
- Language preflight (Step 0 - MUST run before Step 1, non-negotiable)
- No-Ask Contract (mid-pipeline)
- Research Ladder (per open question)
- Step 1: Deep Context Gathering
- Step 2: Autonomous Design
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

The base skill's pointer applies; resolve it before Step 1, not at Step 6. Auto mode emits exactly two user-facing surfaces — the Step 4.5 `AskUserQuestion` batch and the Step 6 report — and both depend on the answer.

## No-Ask Contract (mid-pipeline)

**Never use `AskUserQuestion` mid-pipeline.** For every decision point, execute the Research Ladder first. Collect anything still unknowable into `human_input_queue` and keep going — do not stop to ask. The **one** place auto mode talks to the user is **Step 4.5**, which batches the whole queue into `AskUserQuestion` at the end, after research and grill have shrunk it to only what genuinely needs a human. Only after the ladder is exhausted does a question reach that batch.

"Unknowable" means: requires a business/stakeholder decision, involves external team ownership with no documented precedent, or has zero signal across all applicable research sources. **Exhaust every source before marking unknowable.** A single empty grep is not exhaustion.

## Research Ladder (per open question)

**If you can run it — run it.** Not "I would check X" or "we could look at Y": call the tool. Speculation about what the codebase might contain is not evidence. This governs every research step below and everywhere else in this algorithm.

Run this sequence before giving up on any question:

1. **Codebase** — execute Grep/Glob/Read in `repo_path`. Look for: existing patterns, similar features, constants, schema definitions, interface signatures, test expectations, recent commits touching the relevant area.
2. **KB** — read the domain KB file. Look for: architecture decisions, constraints, ownership, past choices on similar problems.
3. **CLAUDE.md** — read the repo's coding standards for relevant constraints.
4. **Jira** — execute `searchJiraIssuesUsingJql` for related tickets using keyword fragments from the question. Read comments on the top 2-3 hits.
5. **Effort docs** — execute `grep -r` across `workspace/efforts/*.md` for related design decisions.
6. **External docs** — when the question is about an external library/SDK/API/platform behavior, run the source ladder in `.claude/docs/design-research.md → Part A`: official docs (`context7`/`ms-learn` MCP or `WebSearch`+`WebFetch`), dependency source/changelog at the pinned version, then issue trackers. Cite the URL/source; apply the comprehension gate.

After all 6: if still no signal, classify as unknowable. When forced to choose between equally valid options with no signal, apply the Design Principles ordering from the base skill and pick the option that best satisfies the leading principle. Log the auto-selection reasoning.

---

## Step 1: Deep Context Gathering

Run the base command's interactive workflow Steps 1-2 without user interaction, then add the research below.

Resolve the repo and KB, then gather repo state, active efforts, Jira context, relevant callers/tests/history, and applicable plan-gate evidence. Use `.claude/docs/design-research.md` for external research and implementation-readiness checks.

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

## Step 2: Autonomous Design

Follow the base command's interactive workflow Steps 3-5 with these adaptations:

**Approach selection** - do not ask mid-pipeline. Run the Research Ladder. If a decision is still unknowable, add it to `human_input_queue`, use the most KB-aligned default assumption, and log its evidence.

**Plan gates and PR packaging** - Part B already ran at 1j against the gathered evidence; here re-check only the gates whose inputs the chosen option changed, then run Part C. Write a junior-implementable `### Implementation Plan` with per-step files, tests, done conditions, and dependency graph. Write `### PR Plan` with `Target PR count: 1` unless a Core Contract split boundary applies. If more than one PR is proposed, run the Research Ladder against the split boundary and explain why one coherent PR is worse for review or merge safety.

**Recommendation** - auto-select the best evidenced option. If the recommendation is a hybrid, define it explicitly using the Design Principles ordering.

**ETA** - read `.claude/docs/eta-estimation.md` and write the ETA section from the implementation steps. The base skill scores `ETA` as a Quality criterion in every mode, so auto mode owns producing it; `--review` scores what is written here.

**External writes** - skip Jira creation in auto mode.

Keep the complete effort-doc draft in memory and proceed directly to Step 3. Do not stage, apply, report, or create a todo yet.

---

## Step 3: Codebase Grill Pass (mandatory — always runs)

This step runs unconditionally after the effort-doc draft is prepared in memory. It does not depend on review scores. Even if the initial self-review gave all PASS, the grill still runs.

**Purpose:** actively resolve every open question and design ambiguity through tool execution before submitting the doc for review. This is not a reasoning exercise — it is a research execution phase.

Before collecting branches, follow `.claude/docs/open-work-freshness.md` for every proposed implementation-plan item and success criterion. Consume `freshness_outcome` per that document's `Auto design` row; the draft being in memory rather than on disk is the only difference - discard means discard without staging.

### 3a. Collect all branches

Collect branches exactly as `.claude/docs/design-grill-mode.md → Step 3` specifies — the same open-questions / ambiguous-wording / missing-invariant sources, the same persona lenses, the same dependency-closed 15-branch cap and load-bearingness ordering. Run it against the in-memory draft instead of a saved effort doc.

### 3b. For each branch: classify then execute

Run the Research Ladder on each branch and apply what it returns to the design. Two grill-specific bindings: codebase reads run against `fresh_default_oid` (`git -C {repo_path} grep -n -E -e "{keyword}" "{fresh_default_oid}" -- "{target_path}"`, then `git show` from that same commit), and every resolution logs the `file:line` that settled it.

A branch reaches **unknowable** only after every applicable rung came back empty. Record it in `human_input_queue` as:
```
question: "{Concrete, specific question}"
why_unknowable: "{What was tried and why it came back empty}"
what_was_tried: ["{grep command + result}", "{JQL + result}", ...]
default_assumption: "{Conservative default applied in the design}"
design_section: "{Which section this affects}"
```

### 3c. Update the effort-doc draft

After working through all branches:
- Apply all resolutions to the relevant in-memory design sections
- Remove resolved items from `## Open Questions` and note what resolved each one (e.g., "Resolved via `src/api/routes.ts:42` — existing pattern uses pagination")
- Items moved to `human_input_queue` stay in `## Open Questions` with the note: "→ Queued for Step 4.5 human input"

Proceed to Step 4.

---

## Step 4: Auto-Review Loop (max 3 iterations)

Runs on the in-memory effort-doc draft updated by the Codebase Grill Pass.

### 4a. Score the design

Score via a fresh-context, read-only `verifier` from `.claude/roles.yaml`. Give it only the draft, criteria table, and cited references, never the authoring reasoning. For each FAIL or WEAK, record the specific gap.

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

1. Convert each queued item into an `AskUserQuestion` entry per `.claude/docs/skill-authoring-contract.md` → §5, which owns batching, recommendation-first options, load-bearingness ordering, and the `### Resolved Decisions` table. The only design-specific part: `question` is the concrete decision (not "clarify scope" but "Should the export endpoint support CSV only, or also Excel?"), and the recommended option is the default assumption the design already applied.
2. After each answer, apply the decision to the relevant design sections before moving on.
3. Anything the user skips or answers with "Other → defer" stays in `human_input_queue` for the `## Human Input Required` section (Step 5b). Everything answered is removed from the queue.

This replaces the old "queue everything to the doc and tell the user to run `--review`" behavior: the user gets asked once, at the end, and the written doc already reflects their answers.

## Step 5: Write Final Effort Doc

### 5a. Apply all revisions

Finalize the in-memory effort doc with all changes from Steps 3-4.5. Follow `.claude/docs/workspace-write-guard.md`: stage the final content, show its diff, and apply it with the fresh guard metadata to `workspace/efforts/{slug}.md`. Do not write or overwrite the target directly.

Run two mechanical checks against the **staged** content, before apply. Both catch defects that are cheap here and invisible later - `.claude/docs/effort-doc-audit.md` notes that a doc with no canonical rows falls back silently to frontmatter, so nothing downstream surfaces a missing `## Lifecycle` block or an invalid `partial_delivery`.

```bash
python3 .claude/scripts/citation-validator.py "{staged_path}" \
  --root nase="$NASE_ROOT" --repo-root {alias}="{repo_path}" --format json
python3 .claude/scripts/effort-state.py --file "{staged_path}" --evaluate-transition
```

`citation-validator.py` is the mechanical half of the Grounding criterion and of `design-research.md`'s *Cite or gap* rule: exit `1` means a cited PR, Jira key, or `path:line` does not resolve - fix or `gap`-mark it before applying. Exit `2` is `UNKNOWN` (Confluence needs MCP); record it, do not treat it as a pass. `effort-state.py` failing to classify the doc means its structure is wrong, not that the classifier is.

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
