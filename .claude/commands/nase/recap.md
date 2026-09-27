---
name: nase:recap
description: "Generate a weekly or monthly work recap with improvement suggestions. Use for recap, review my work, review progress, what did I do, or summarize a period."
argument-hint: "[days|week|month] [--verbose]"
category: Reporting
---

Create a sourced recap from bounded workspace data. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/confidential-marker.md` and `.claude/docs/skill-contract.md`.

## Workflow

1. Resolve the range with `.claude/scripts/date-resolve.py`. When `$ARGUMENTS` names none, default to the last full week rather than stopping to ask, because the range is recoverable from `workspace/logs/` and step 8 states which window it used so the user can rerun with another. Ask only when the logs are empty for that window.
2. Gather compact data with `.claude/docs/workspace-data-gathering.md` and `.claude/scripts/log-range.py`. Exclude confidential sessions before synthesis.
3. For broad ranges, run read-only `nase-workspace-state-scanner` slices over disjoint dates. That agent is `tools: Read, Grep, Glob` with no Bash, so it reads the log, journal, and effort files directly and never runs `log-range.py`, `git`, or `gh`; the main thread runs step 2's helpers and passes their output into the slice prompt. The main thread owns recap synthesis and file writes.
4. Probe tool availability before gathering, with the invocation `.claude/docs/cli-tooling.md → Availability Probe` owns:
   `python3 .claude/scripts/tool-availability.py --group data --group usage --format json`. Use CLI aggregation when available; keep raw logs out of context.
5. Derive unique PRs, reviews, commits, repos, incidents, lessons, KB updates, decisions, blockers, and completed work. De-duplicate on a stated key so two runs over the same logs agree: PRs and reviews on `{owner}/{repo}#{number}`, commits on SHA, repos on the resolved local path, Jira items on issue key. Every count stays backed by surviving source lines or live metadata.
6. Validate citations with `.claude/docs/citation-validator.md`. Remove unsupported claims or state the evidence gap. Keep the `--format json` payload for step 7.
7. Write `workspace/recaps/{start}_{end}.md` with stats, overview, chronological highlights, tasks, lessons, KB changes, decisions, and concrete next-period suggestions. Then persist the payload from step 6 as `workspace/recaps/{start}_{end}.md.receipt.json` per `.claude/docs/citation-validator.md → Persist the receipt`.
8. Return the resolved `{start}..{end}` window, the artifact pointer, and up to five highlights. Add nothing more unless `--verbose` is present.

Missing logs or tools reduce coverage; they do not justify invented activity. This command is read-only except for three writes: the recap artifact, its `.receipt.json` sidecar, and the daily-log entry.
