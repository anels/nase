---
name: nase:discuss-pr
description: "Read-only PR analysis that finds the product/repo problem, then checks logic, design, simpler options, security, and testability before drafting comments. Use for analyze PR, self-review, prepare review comments, review PR #N, or PR URL + review without posting. Use /nase:address-comments for existing feedback."
argument-hint: "<pr-url-or-number>"
pattern: fan-out
category: Git workflow
---

## Language

Read `workspace/config.md` for `conversation:` and `output:` values before producing any text.

**Discipline (read once; apply everywhere below):**
- **Narrative prose** - Review Frame paragraphs, Sense Check evidence cells, Risk map reasons, Scorecard justifications, summary line phrasing, finding descriptions, open-question explanations, AskUserQuestion option labels/descriptions, handoff confirmations → write in the `conversation:` value.
- **Structural skeleton** - table column headers, code blocks, file paths, line numbers, symbol/identifier names, GitHub-bound drafts, daily-log entries, JSON keys/values, command output → keep English.
- This rule **outranks** caveman-mode fragments and SKILL-template English defaults. The English examples below are template scaffolding, not a directive to keep narrative in English. When `conversation:` is non-English (e.g. `简体中文`), translate narrative prose; keep skeleton untouched.

## Review stance

Default question order:

1. What problem is this PR solving, for which users/components, and why now?
2. Does the implementation actually satisfy that intent across the changed code paths?
3. Does the design fit the larger system boundaries, ownership, and adjacent patterns?
4. Is there a simpler, more coherent implementation that reduces risk or maintenance cost?
5. Are tests, security checks, and PR hygiene sufficient for the risk level?

Keep findings anchored to the PR's intent. Drop unrelated pre-existing issues. Treat "more elegant" as actionable only when the alternative is concretely simpler, safer, easier to test, or a better fit with existing patterns.

Fan-out threshold: stay main-thread unless the request spans multiple repos, more than 20 files, more than 1000 diff lines, or the user explicitly asks for deep/batch review. Prefer compact script output before spawning agents.

## Standing invariants

- This command is read-only. It may draft review comments in chat but never posts, reacts, replies, resolves, edits a PR, or performs another external mutation.
- Keep findings anchored to the stated PR intent and changed code. Drop unrelated pre-existing issues.
- Fetch existing human and bot comments once, then de-duplicate every candidate against them before presenting.
- Preserve the KB lookup shape `mentions:<path>` for core changed files.
- Confidence tiers remain: Critical 90-100, High 80-89, Medium 50-79 for discussion only, and below 50 dropped.
- Diff-first investigation and the trace-shape self-check must run at the actual investigation and classification call sites.
- Narrative uses `conversation:`; GitHub-bound drafts use `output:`. Structural skeleton, paths, symbols, IDs, and command output stay English.

## State contract

Preserve normalized `owner`, `repo`, `number`, `pr_ref`, `repo_path`, compact PR metadata, changed files, existing comment set, review frame, risk map, selected specialists, candidate findings, confidence scores, verification matrix, doubt-cycle results, de-duplicated findings, draft choice, and final counts.

## Phase map

| Step | Owner and load point |
|---|---|
| 0 | This entrypoint: input and read-only contract. |
| 1-5.7 | Read `.claude/docs/discuss-pr-analysis.md` when entering Step 1. |
| 6-Final | Read `.claude/docs/discuss-pr-output.md` when entering Step 6. |

## Phase 0: Input Guard

Follow `.claude/docs/pr-input-guard.md`. If `$ARGUMENTS` is empty, ask for the PR URL instead of printing usage.

## Steps 1-5.7: Analyze

Read `.claude/docs/discuss-pr-analysis.md` once. Execute compact context collection, review framing, risk/specialist selection, scoring, deep dives, verification recommendation, and the bounded doubt cycle.

Return the complete state contract above. Before Step 6, no user-visible finding may rely only on a widen-first or path-guessing trace.

## Steps 6-Final: Present and hand off

At Step 6, read `.claude/docs/discuss-pr-output.md` once. Follow its exact output order, scorecard, confidence grouping, optional deep dives, draft decision, KB offer, error handling, notes, and daily log.

End after chat drafts or no-draft confirmation. Posting requires a separate explicit GitHub mutation workflow and is never offered by this command.
