# KB Usage Report

Procedure for `/nase:stats kb-usage [--window N|all] [--top N] [--verbose]`. It reports which skills read or surface KB files and which mapped files no consumer reads. It is read-only except for its report under `workspace/stats/`.

## Flags

- `--window N` - events from the last `N` days. Default `30`. `--window all` includes every event.
- `--top N` - rows in the top files and top skills tables. Default `10`.
- `--verbose` - print the written report inline after the summary.

## Run

Treat the text after `kb-usage` as command input, not shell source. Forward only the flags above, each value as its own shell-quoted argument, and let `kb-usage-report.py` parse and validate them. Never interpolate the raw argument string into a shell command and never reparse it in shell.

Do not forward `--verbose`. The helper prints the whole report to stdout when it sees that flag, so echoing the body afterwards emits the report twice. Consume `--verbose` in the caller by reading the written report back inline.

```bash
today=$(date +%F)
report="workspace/stats/kb-usage-${today}.md"
python3 .claude/scripts/kb-usage-report.py --window "7" --top "5" --output "$report"
```

Drop the flags the user did not pass. The `$(date +%F)` is owned by the skill, not by user input, so it may stay unquoted.

## Relay

Relay the script's own summary, since it is the source of truth for these fields.

- KB files accessed, read, and surfaced by resolve or search
- skills accessing KB
- `Mapped KB files never read by a consumer`, the actionable count
- top files, top skills, and the report path

Quote the consumer-unread count, not the plain `Unread` and `Unobserved` lines. Those two count maintenance-skill reads as use, so they read 0 on a workspace where only `/nase:kb-review` touched the KB. `resolve` and `search-result` events are discovery, not proof that a fact influenced the workflow. Do not edit `workspace/kb/.domain-map.md`.

To search KB content, run `bash .claude/scripts/kb-search.sh '<query>'` directly, single-quoted with any `'` removed from the query. It is read-only.
