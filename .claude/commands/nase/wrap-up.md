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

1. Gather today's sanitized activity with `.claude/docs/workspace-data-gathering.md`, delegating the log/task/effort reads to `nase-workspace-state-scanner` - the answer is a day summary, not the file contents. Exclude confidential sessions from reflection, learning, KB, style, and journal synthesis.
2. Call the Skill tool for `nase:reflect` only when Step 1 surfaced a task that reached a terminal state today - completed, abandoned, or failed - **and** something about how it went was not already obvious from its diff. No terminal task, no reflect.
3. Call the Skill tool for `nase:learn` only for an insight that (a) came up today, (b) applies to a repo other than the one it came from, and (c) has a citable source - file path, PR, or URL. All three, or skip.
4. Never call `/nase:extract-skills` from this step. Tell the user to run it only when Step 1 shows the same non-obvious workflow performed at least twice and `grep -ril "<workflow keyword>" .claude/commands/nase workspace/skills` returns no owner. A hit means the workflow has a home already; extend that skill instead.
5. Run the automatic KB update only for durable, evidence-backed repo knowledge. Auto-write modes only skip human confirmation; they never skip final drift checks.
6. Compare estimates with actual outcomes when evidence exists. The anchor is the `estimate:` log line `.claude/docs/eta-estimation.md → Calibration Anchor` defines, so gate on `grep -c '^- [0-9][0-9]:[0-9][0-9] | estimate:' workspace/logs/{today}.md || true`. Only when that is non-zero and the task actually completed, read `.claude/docs/lessons-format.md` and append calibration lessons at the threshold documented there.
7. Reconcile Jira status. Skip the step silently - and skip the doc read - when `workspace/config.md` has no `cloudId` or the Atlassian MCP is unavailable; otherwise follow `.claude/docs/jira-lifecycle.md`. Jira writes are opt-in and require the exact transition/comment payload plus a fresh token.
8. Run `python3 .claude/scripts/today-stats.py --date {today}` for skill/activity counts. The `python3` prefix is required - the script is mode 644, so invoking it directly is a permission error. Missing telemetry is `no data`, not zero work.
9. Consolidate pending style deltas. Count them first with `grep -c '\[STYLE-DELTA\]' workspace/logs/{today}.md || true` - `grep -c` exits 1 on zero matches and 2 on a missing file, so without the `|| true` the predicate reads as a command failure rather than as "no deltas". On zero (or no log file), record `style-delta=skipped-no-deltas` and move on without reading the doc. Otherwise follow `.claude/docs/style-delta-capture.md`; never write the style profile from inference.
10. Build the journal with outcomes, reflection, lessons, KB/style changes, blockers, and stats. Render the final card from `.claude/docs/closing-block.md` at the end of the journal file.
11. Stage, diff, and apply the complete journal per `.claude/docs/workspace-write-guard.md`. All three subcommands take required arguments; a bare `stage` exits 2:

```bash
python3 .claude/scripts/workspace-write-guard.py stage \
  --target workspace/journals/{today}.md --content-file workspace/tmp/journal-{today}.md --skill wrap-up
python3 .claude/scripts/workspace-write-guard.py diff \
  --target workspace/journals/{today}.md --staged {staged path from stage}
python3 .claude/scripts/workspace-write-guard.py apply \
  --target workspace/journals/{today}.md --staged {staged path} \
  --expected-mtime-ns {from stage} --expected-sha256 {from stage} --expected-staged-sha256 {from stage}
```

Take every `--expected-*` value from the `stage` output, never from a fresh read. The main thread owns the write.
12. Prune `workspace/tmp/`. Run it after Step 11 so a prune problem can never block the journal write:

```bash
python3 .claude/scripts/tmp-prune.py --apply --manifest workspace/tmp/tmp-prune-{today}.tsv
```

The script's docstring owns which entries it deletes. Deletion is permanent: backups exclude `workspace/tmp/`, so the manifest is the only record. Report the removed count, the MB freed, and the manifest path; never list the paths in chat. A prune failure is recorded and does not fail the wrap-up.
13. Append one self-log line, then close the chat reply with: the journal path, up to five highlights, the prune line from Step 12, and the closing card as the final visible block - echoed from the journal, code-fenced per `.claude/docs/closing-block.md`.

Chained skill failures are recorded once and do not erase successful sibling steps. Never convert a skipped conditional step into a completion claim.
