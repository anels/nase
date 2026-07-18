---
name: nase:recap
description: "Generate a weekly or monthly work recap with improvement suggestions. Use for recap, review my work, review progress, what did I do, or summarize a period."
argument-hint: "[days|topic]"
pattern: pipeline
category: Reporting
sub-patterns: [fan-out]
---

Create a sourced recap from bounded workspace data. Run `.claude/docs/language-config.md`, `.claude/docs/confidential-marker.md`, and `.claude/docs/skill-contract.md` first.

## Workflow

1. Resolve the range with `.claude/scripts/date-resolve.py`; if unspecified, ask for week or month once.
2. Gather compact data with `.claude/docs/workspace-data-gathering.md` and `.claude/scripts/log-range.py`. Exclude confidential sessions before synthesis.
3. For broad ranges, run read-only `nase-workspace-state-scanner` slices over disjoint dates. The main thread owns recap synthesis and file writes.
4. Probe optional aggregation tools with:

```bash
python3 .claude/scripts/tool-availability.py --group data --group usage --format json
```

Use CLI aggregation when available; keep raw logs out of context.
5. Derive unique PRs, reviews, commits, repos, incidents, lessons, KB updates, decisions, blockers, and completed work. Counts must be de-duplicated and backed by surviving source lines or live metadata.
6. Validate citations with `.claude/docs/citation-validator.md`. Remove unsupported claims or state the evidence gap.
7. Write `workspace/recaps/{start}_{end}.md` with stats, overview, chronological highlights, tasks, lessons, KB changes, decisions, and concrete next-period suggestions.
8. Return only the artifact pointer and up to five highlights unless `--verbose` is present.

Missing logs or tools reduce coverage; they do not justify invented activity. This command is read-only except for its recap artifact and daily-log entry.
