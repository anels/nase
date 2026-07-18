---
name: nase:wrap-up
description: "Capture end-of-day reflection, lessons, KB updates, and a journal entry. Use for wrap up, end of day, EOD, done for today, closing out, or summarize today."
argument-hint: "[day summary]"
pattern: pipeline
category: Learning & reflection
---

Close the day in one bounded pass. Run `.claude/docs/language-config.md`, `.claude/docs/confidential-marker.md`, and `.claude/docs/skill-contract.md` first.

## Workflow

1. Gather today's sanitized activity with `.claude/docs/workspace-data-gathering.md`. Exclude confidential sessions from reflection, learning, KB, style, and journal synthesis.
2. Run `/nase:reflect` only when meaningful completed or failed work produced a lesson.
3. Run `/nase:learn` only for a verified cross-project insight with usable sources.
4. Run `/nase:extract-skills` only when a repeated non-obvious workflow lacks an existing owner.
5. Run the automatic KB update only for durable, evidence-backed repo knowledge. Auto-write modes only skip human confirmation; they never skip final drift checks.
6. Compare estimates with actual outcomes when evidence exists; append calibration lessons only at the documented threshold in `.claude/docs/lessons-format.md`.
7. Reconcile Jira status through `.claude/docs/jira-lifecycle.md`. Jira writes are opt-in and require the exact transition/comment payload plus a fresh token.
8. Compact eligible log sections without deleting unique facts or unresolved markers.
9. Run `.claude/scripts/today-stats.py` for skill/activity counts. Missing telemetry is `no data`, not zero work.
10. Consolidate pending style deltas through `.claude/docs/style-delta-capture.md`; never write the style profile from inference.
11. Calibrate review findings from local evidence. GitHub stays read-only unless separately authorized.
12. Build the journal with outcomes, reflection, lessons, KB/style changes, blockers, and stats. Render the final card from `.claude/docs/closing-block.md`.
13. Stage the complete journal with `python3 .claude/scripts/workspace-write-guard.py stage`, show the diff, then run `workspace-write-guard.py apply` with recorded mtime/hash/staged hash. The main thread owns the write.
14. Append one self-log line and return the journal path plus up to five highlights.

Chained skill failures are recorded once and do not erase successful sibling steps. Never convert a skipped conditional step into a completion claim.
