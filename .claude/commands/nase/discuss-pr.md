---
name: nase:discuss-pr
description: "Deeply review a PR and draft evidence-backed inline findings. Use for analyze PR, review PR, self-review, or a PR URL; use /nase:address-comments for existing feedback."
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

- Analysis (Steps 1-6.5) is investigation-only and auto-runs deep-dive traces without asking. The only external mutations this command performs are the review submission and any batched reactions/replies the user explicitly approves at Step 7-8. Every GitHub write goes through a payload-bound `external-write-action.py` manifest the user authorizes; never run a raw `gh api` mutation.
- Keep findings anchored to the stated PR intent and changed code. Drop unrelated pre-existing issues.
- Fetch existing human and bot comments once, then de-duplicate every candidate against them before presenting.
- Preserve the KB lookup shape `mentions:<path>` for core changed files.
- Keep `confidence` (evidence certainty), `severity` (impact), `kind` (`issue | suggestion | nit | question`), and `disposition` (`blocking | non-blocking | needs-answer`) independent. High confidence never makes a nit severe or blocking.
- Every GitHub-bound inline draft must pass the private outgoing-comment research gate. Keep private or sensitive evidence out of GitHub text.
- A nit may be drafted only when it is high-confidence, PR-introduced, changed-line anchored, not formatter-detectable, and supported by repo authority or a concrete maintainability benefit. Nits are always non-blocking.
- Diff-first investigation and the trace-shape self-check must run at the actual investigation and classification call sites.
- Narrative uses `conversation:`; GitHub-bound drafts use `output:`. Structural skeleton, paths, symbols, IDs, and command output stay English.

## State contract

Preserve normalized `owner`, `repo`, `number`, `pr_ref`, `repo_path`, compact PR metadata, changed files, existing comment set, review frame, risk map, selected specialists, candidate findings, private outgoing-comment records, confidence, severity, kind, disposition, authority, `safe_defer`, `must_not_merge_reason`, verification matrix, doubt-cycle results, de-duplicated findings, draft choice, and final counts.

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

At Step 6, read `.claude/docs/discuss-pr-output.md` once. Follow its exact output order, scorecard, severity/disposition grouping, automatic additional deep dives, draft decision, gated review submission, completion message, KB offer, error handling, notes, and daily log.

The draft decision defaults to drafting inline comments and submitting a GitHub review; the user still actively confirms the draft choice and the review state before any write. All writes go through the `external-write-action.py` manifest gate.
