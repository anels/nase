---
name: nase:skill-usage
description: "Report skill usage, outcomes, context hotspots, and deprecation candidates. Use for which skills do I use, skill stats, skill token cost, context hotspots, or deprecate skills."
argument-hint: "[--window N --top N]"
pattern: utility
category: Reporting
model: haiku
effort: low
---

Generate a read-only usage report from `workspace/stats/skill-usage.jsonl`. Run `.claude/docs/language-config.md` first and follow `.claude/docs/skill-contract.md`.

## Workflow

1. Parse `--window` (default 60), `--top` (default 10), and `--verbose` from `$ARGUMENTS`.
2. Run:

```bash
python3 .claude/scripts/skill-usage-report.py --window "$WINDOW" --top "$TOP"
```

3. If the script returns `No skill usage data`, say the tracker may not have fired and stop successfully.
4. Open the generated report only when needed. It counts v2 `activated` events, keeps outcomes separate, and uses the bounded prompt/tool fallback only for legacy records.
5. Report `Hot`, `Active`, `Cold`, `Inactive`, and `Unused` counts plus the requested top N. Include the report path.
6. With `--verbose`, print the report after generation; otherwise keep chat to the pointer and up to five lines.

`Context Hotspots` is an estimate based on entry bytes and observed activations. Treat it as prioritization evidence, not billing truth. Deprecation candidates require a separate value/overlap review; this command never edits skills.
