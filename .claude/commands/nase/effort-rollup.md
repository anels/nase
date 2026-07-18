---
name: nase:effort-rollup
description: "Build a monthly delivery report from live PR and Jira state. Use for effort rollup, impact report, month in review, or what did I ship."
argument-hint: "<YYYY-MM> [--repo <name>] [--scope <v>] [--md-only]"
pattern: utility
category: Reporting
---

Generate an evidence-backed monthly delivery report. Run `.claude/docs/language-config.md` first and follow `.claude/docs/skill-contract.md`.

## Workflow

1. Resolve `YYYY-MM`; default to the previous calendar month. Reject invalid or future-only ranges.
2. Run `.claude/scripts/month-efforts.sh` and inventory active/done effort docs whose delivery evidence intersects the month. Apply optional repo/scope filters.
3. Read effort metadata through `.claude/docs/effort-lifecycle.md`. Treat frontmatter as a lead, not live truth.
4. Reconcile every structured delivery PR with `gh`. Split by actual `mergedAt` in the report month, closed without delivery, still open, or unreadable. Keep report-only and dependency PRs separate.
5. Reconcile linked Jira issues when access exists. Record access gaps; never infer Jira state from stale effort text.
6. Validate before/after claims from runnable evidence. Mark each impact value `verified`, `documented`, or `unverified`; never turn a target into a result.
7. Write `workspace/recaps/effort-rollup-{YYYY-MM}.md`. Unless `--md-only`, also write a self-contained HTML report with the same facts and no remote assets.
8. Include delivery totals, closed-without-delivery, active carryover, impact evidence, verification gaps, and per-effort source links.
9. Append the daily-log entry using `.claude/docs/daily-log-format.md` and return only the artifact pointer plus up to five highlights.

Do not mutate effort lifecycle, PRs, Jira, or GitHub. A PR merged outside the month stays outside delivered work even when its effort doc was completed during the month.
