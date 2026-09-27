---
name: nase:skill-usage
description: "Report skill usage, outcomes, context hotspots, and deprecation candidates. Use for which skills do I use, skill stats, skill token cost, context hotspots, or deprecate skills."
argument-hint: "[--window N --top N]"
category: Reporting
model: haiku
effort: low
---

Generate a read-only usage report from `workspace/stats/skill-usage.jsonl`. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/skill-contract.md`.

## Workflow

1. Parse `--window` (default 60), `--top` (default 10), and `--verbose` from `$ARGUMENTS`.
2. Run the report, substituting the parsed numbers **literally**. `$ARGUMENTS` is a prompt-template placeholder, so `--window "$WINDOW"` passes an empty string and `argparse`'s `type=int` exits 2. Omit a flag entirely to take the script default rather than passing a blank:

```bash
python3 .claude/scripts/skill-usage-report.py --window 60 --top 10
```

Add `--print-report` to that same call when `--verbose` is in `$ARGUMENTS`; the script already prints the rendered report on that flag, so do not re-read the file to echo it.

3. If the script returns `No skill usage data`, distinguish the two causes before reporting: `test -s workspace/stats/skill-usage.jsonl` failing means the tracker never wrote anything (say the PostToolUse hook may not have fired, and point at `/nase:doctor`); a non-empty ledger with no in-window rows means genuinely no usage in that window (say that, and name the window). Either way, stop successfully.
4. Open the generated report only when needed. It counts a use for each `activated` event and each tool outcome, dropping a tool outcome only when a prompt event for the same skill and session precedes it inside the dedupe window, and dedupes legacy records against each other. Outcome counts stay per tool call, so `tool_successes` can differ from `total`.
5. Report `Hot`, `Active`, `Cold`, `Inactive`, and `Unused` counts plus the requested top N. Include the report path.
6. Without `--verbose`, keep chat to the pointer and up to five lines; `--verbose` already printed the report in Step 2.

The `Hot`/`Active`/`Cold`/`Inactive`/`Unused` tiers here are lifecycle states over the script's fixed windows. `/nase:stats` buckets the same ledger as Heavy/Steady/Light/Low/Rare, which are activity counts for one requested range. Two questions, two vocabularies - do not read one as the other.

`Context Hotspots` is an estimate based on entry bytes and observed uses. Treat it as prioritization evidence, not billing truth. Deprecation candidates require a separate value/overlap review; this command never edits skills.
