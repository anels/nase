---
name: nase:kb-usage
description: "Report which skills access, read, or surface KB files and which mapped files are unobserved. Use for KB usage, KB observability, top KB files, or unused KB entries."
argument-hint: "[--window N|all] [--top N] [--verbose]"
pattern: utility
category: Reporting
---

Generate a read-only KB usage telemetry report from `workspace/stats/kb-usage.jsonl`.

## Language

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Command names, file paths, and table labels stay English.

## Input

`$ARGUMENTS` supports:

- `--window N` — include events from the last `N` days. Default: `30`.
- `--window all` — include all events.
- `--top N` — number of top files and skills to show. Default: `10`.
- `--verbose` — print the full generated report inline after writing it.

## Run

Treat `$ARGUMENTS` as command input, not shell source. Accept only the flags documented above and forward each recognized flag and value as a separately shell-quoted argument to the existing Python helper. Never interpolate the raw argument string into a shell command. Let `kb-usage-report.py` parse and validate those arguments.

Append `--output "workspace/stats/kb-usage-$(date +%F).md"` and run the resulting command. For example, the default invocation is:

```bash
today=$(date +%F)
report="workspace/stats/kb-usage-${today}.md"
python3 .claude/scripts/kb-usage-report.py --output "$report"
```

For `--window 7 --top 5 --verbose`, invoke:

```bash
today=$(date +%F)
report="workspace/stats/kb-usage-${today}.md"
python3 .claude/scripts/kb-usage-report.py --window "7" --top "5" --verbose --output "$report"
```

## Output

Return the script summary in chat:

- unique KB files accessed, directly read, and surfaced by resolve/search
- skills accessing KB
- unread and unobserved mapped KB files
- top files
- top skills
- report path

If `--verbose` is present, include the report body after the summary. Treat `resolve` and `search-result` as discovery, not proof that a fact influenced the workflow. Do not edit `workspace/kb/.domain-map.md`; this command is read-only except for the report artifact under `workspace/stats/`.
