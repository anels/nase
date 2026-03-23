# Workspace Data Gathering

Shared algorithm for loading workspace activity data within a date range. Used by `/nase:recap` and `/nase:wrap-up`.

## Inputs

- `START_DATE` / `END_DATE` — the date range (YYYY-MM-DD)
- `SCOPE` — `"day"` (wrap-up: today only) or `"range"` (recap: arbitrary range)

## Algorithm

### 1. Load workspace state (parallel)

Read in parallel:
1. `workspace/context.md` — repo list and domain patterns (resolve local paths from `.local-paths`)
2. `workspace/tasks/todo.md` — current task states
3. `workspace/tasks/lessons.md` — full lessons list (filter to entries dated within range)
4. `workspace/kb/.domain-map.md` — domain → KB file index

Do NOT load KB domain files upfront — only read a specific one if needed to clarify something mentioned in journals/logs.

### 2. Load journals and logs for each day in range (parallel)

Read all `workspace/journals/YYYY-MM-DD.md` and `workspace/logs/YYYY-MM-DD.md` files for the date range in a single parallel batch. Then for each day:
1. Prefer the journal file if it exists (synthesized daily summary).
2. Fall back to the log file if no journal exists (raw session notes).
3. If neither exists, mark the day as no-activity.

### 3. Extract structured data

- **Activity per day:** repos/projects worked on, tasks attempted/completed/blocked, decisions made, PR/ticket/Confluence links (preserve verbatim).
- **Task status (from todo.md):** completed during range; in-progress or blocked at range end.
- **Lessons added during range (from lessons.md):** scan for section headers in the format `## {category} — {YYYY-MM-DD}` where the date falls within the range. Group by category (workflow / code / debugging / ops / infra / architecture / project).
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
