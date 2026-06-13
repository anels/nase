---
name: nase:kb-usage
description: "Read-only KB observability report: shows which skills used which KB files, top files/skills, access-source breakdown, and mapped KB files with no recent usage. Supports --window N|all, --top N, and --verbose."
pattern: utility
---

Generate a read-only KB usage telemetry report from `workspace/stats/kb-usage.jsonl`.

## Language

Read `workspace/config.md` for `conversation:` and `output:` values before producing text. Keep command names, file paths, and table labels in English.

## Input

`$ARGUMENTS` supports:

- `--window N` — include events from the last `N` days. Default: `30`.
- `--window all` — include all events.
- `--top N` — number of top files and skills to show. Default: `10`.
- `--verbose` — print the full generated report inline after writing it.

## Run

Parse flags conservatively, then write the dated report:

```bash
window=30
top=10
verbose=0

set -- $ARGUMENTS
while [ "$#" -gt 0 ]; do
  case "$1" in
    --window)
      shift
      window="${1:-30}"
      ;;
    --window=*)
      window="${1#--window=}"
      ;;
    --top)
      shift
      top="${1:-10}"
      ;;
    --top=*)
      top="${1#--top=}"
      ;;
    --verbose)
      verbose=1
      ;;
    *)
      echo "Usage: /nase:kb-usage [--window N|all] [--top N] [--verbose]"
      exit 1
      ;;
  esac
  shift
done

today=$(date +%F)
report="workspace/stats/kb-usage-${today}.md"

if [ "$verbose" -eq 1 ]; then
  python3 .claude/scripts/kb-usage-report.py --window "$window" --top "$top" --output "$report" --verbose
else
  python3 .claude/scripts/kb-usage-report.py --window "$window" --top "$top" --output "$report"
fi
```

## Output

Return the script summary in chat:

- unique KB files used
- skills using KB
- unused mapped KB files
- top files
- top skills
- report path

If `--verbose` is present, include the report body after the summary. Do not edit `workspace/kb/.domain-map.md`; this command is read-only except for the report artifact under `workspace/stats/`.
