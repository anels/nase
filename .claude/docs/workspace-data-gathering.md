# Workspace Data Gathering

Shared algorithm for loading workspace activity data within a date range. Used by `/nase:recap` and `/nase:wrap-up`.

## Inputs

- `START_DATE` / `END_DATE` — the date range (YYYY-MM-DD)
- `SCOPE` — `"day"` (wrap-up: today only) or `"range"` (recap: arbitrary range)

## Algorithm

### 1. Load compact workspace state

Run the deterministic scanner first:

```bash
SCAN_OUT=$(mktemp "${TMPDIR:-/tmp}/workspace-data.XXXXXX")
python3 .claude/scripts/workspace-data-scan.py "$START_DATE" "$END_DATE" --scope "$SCOPE" > "$SCAN_OUT"
```

Read `$SCAN_OUT` before reading raw workspace files. It contains:
1. Compact `workspace/tasks/todo.md` plus broad workspace state (`workspace/context.md`, `workspace/kb/.domain-map.md`) only for `SCOPE="range"`.
2. Only `workspace/tasks/lessons.md` sections dated within the requested range.
3. One activity payload per day, preferring `workspace/journals/YYYY-MM-DD.md` over `workspace/logs/YYYY-MM-DD.md`.
4. `path`, `chars`, and `truncated` metadata for every source that may need follow-up reading.

If a payload has `"truncated": true` and the compact content is not enough to answer a required question, read the referenced `path` directly and only around the missing section. Do not pre-load every raw file just because one payload is truncated.

Do NOT load KB domain files upfront — only read a specific one if needed to clarify something mentioned in journals/logs.

### 2. Resolve missing detail on demand

For each day from `$SCAN_OUT`:
1. Use `source = journal` when present; it is the synthesized daily summary.
2. Use `source = log` only when no journal exists.
3. Treat `source = none` as no-activity.
4. Follow `path` to the raw source only for missing details, preserving exact URLs and source wording when cited.

### 3. Extract structured data

- **Activity per day:** repos/projects worked on, tasks attempted/completed/blocked, decisions made, PR/ticket/Confluence links (preserve verbatim).
- **Task status (from todo.md):** completed during range; in-progress or blocked at range end.
- **Lessons added during range (from lessons.md):** scan for section headers in the format `## {category} -- {YYYY-MM-DD} -- {title}` (double-hyphen separator per `.claude/docs/lessons-format.md`) where the date falls within the range. Group by category (workflow / code / debugging / ops / infra / calibration).
- **KB updates:** look for `## KB Updates` sections in journals, or any mention of KB files being updated. Note which files changed and what was added.
- **Key decisions:** scan journals for architectural, workflow, or process decisions — often found in reflection sections or explicit decision notes.

### 4. Activity detection

Determine activity level from the gathered data:
- **Substantive:** journals/logs have session entries with real content
- **Low-activity:** files exist but only have auto-generated headers (no substantive `## Sessions` entries)
- **No-activity:** no journal or log file for the day

Report activity level to the caller — skills use this to decide which conditional steps to run (e.g., wrap-up skips reflect on low-activity days).

## Notes

- **Preserve all links** — PR URLs, Jira tickets, Confluence pages must appear verbatim in extracted data.
- **Degrade gracefully** — use logs as fallback when journals are missing; skip days where both are absent.
- **No KB full-load** — only read specific KB files when needed to clarify journal content.
- **Session entries are the source of truth** for AI-assisted work — do NOT scan git repos for commits (those include unrelated changes not done via AI).
