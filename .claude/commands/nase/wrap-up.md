---
name: nase:wrap-up
description: "Capture end-of-day reflection, lessons, KB updates, and a journal entry. Use for wrap up, end of day, EOD, done for today, closing out, or summarize today."
argument-hint: "[day summary]"
category: Learning & reflection
---

Close the day in one bounded pass. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/confidential-marker.md` and `.claude/docs/skill-contract.md`.

Two former steps are gone on purpose. Log compaction had no trigger, no owner, and no consumer - it mutated `workspace/logs/` between the read in Step 1 and the journal built from that read. Review-finding calibration had no doc, no script, and no output path; ETA calibration is Step 6 and is the only calibration this skill does.

## Workflow

Steps 6, 7, and 9 each read a shared doc that a typical day does not need. Run the one-line predicate named in the step first and read the doc only when it is true.

1. Gather today's sanitized activity with `.claude/docs/workspace-data-gathering.md`. Exclude confidential sessions from reflection, learning, KB, style, and journal synthesis.
2. Run `/nase:reflect` only when meaningful completed or failed work produced a lesson.
3. Run `/nase:learn` only for a verified cross-project insight with usable sources.
4. Run `/nase:extract-skills` only when a repeated non-obvious workflow lacks an existing owner.
5. Run the automatic KB update only for durable, evidence-backed repo knowledge. Auto-write modes only skip human confirmation; they never skip final drift checks.
6. Compare estimates with actual outcomes when evidence exists. The anchor is the `- ETA estimate:` line `.claude/docs/eta-estimation.md → Calibration Anchor` defines, so gate on `grep -c '^- ETA estimate:' workspace/logs/{today}.md || true`. Only when that is non-zero and the task actually completed, read `.claude/docs/lessons-format.md` and append calibration lessons at the threshold documented there.
7. Reconcile Jira status. Skip the step silently - and skip the doc read - when `workspace/config.md` has no `cloudId` or the Atlassian MCP is unavailable; otherwise follow `.claude/docs/jira-lifecycle.md`. Jira writes are opt-in and require the exact transition/comment payload plus a fresh token.
8. Run `.claude/scripts/today-stats.py` for skill/activity counts. Missing telemetry is `no data`, not zero work.
9. Consolidate pending style deltas. Count them first with `grep -c '\[STYLE-DELTA\]' workspace/logs/{today}.md || true` - `grep -c` exits 1 on zero matches and 2 on a missing file, so without the `|| true` the predicate reads as a command failure rather than as "no deltas". On zero (or no log file), record `style-delta=skipped-no-deltas` and move on without reading the doc. Otherwise follow `.claude/docs/style-delta-capture.md`; never write the style profile from inference.
10. Build the journal with outcomes, reflection, lessons, KB/style changes, blockers, and stats. Render the final card from `.claude/docs/closing-block.md` at the end of the journal file.
11. Stage the complete journal with `python3 .claude/scripts/workspace-write-guard.py stage`, show the diff, then run `workspace-write-guard.py apply` with recorded mtime/hash/staged hash. The main thread owns the write.
12. Append one self-log line, then close the chat reply with: the journal path, up to five highlights, and the closing card as the final visible block — echoed from the journal, code-fenced per `.claude/docs/closing-block.md`.

Chained skill failures are recorded once and do not erase successful sibling steps. Never convert a skipped conditional step into a completion claim.
