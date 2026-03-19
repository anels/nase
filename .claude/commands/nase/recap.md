---
name: nase:recap
description: Generate a structured recap of completed work plus actionable improvement suggestions. Use when asked to "recap", "review", "summarize", "what did I do", or "show my progress" for a week or month. Prompts for period if not specified. Always ends with concrete next-period suggestions.
---

**Input:** $ARGUMENTS

## Step 1 — Resolve the date range

If $ARGUMENTS is blank, use the `AskUserQuestion` tool (single-select) before proceeding:

- question: "Recap which period?"
- header: "Recap Period"
- options:
  - "Last week" — Monday–Sunday of last week
  - "Last month" — 1st–last day of last month
  - "Custom range" — I'll enter the dates manually

If the user selects "Custom range", ask for the dates as a free-text follow-up: "Enter range as YYYY-MM-DD to YYYY-MM-DD". Accept that format and proceed.

If $ARGUMENTS is already provided, skip the prompt and resolve directly:

| Input | Range |
|-------|-------|
| "week" / "last week" | Monday–Sunday of the previous week |
| "this week" | Monday of the current week → today |
| "month" / "last month" | 1st–last day of the previous month |
| "this month" | 1st of the current month → today |
| "YYYY-MM-DD to YYYY-MM-DD" | Explicit range |

The period for "last week" and "last month" is always a **completed** interval. Use today's actual date to compute relative ranges.

Use **weekly format** for ranges ≤ 14 days; **monthly format** for ranges > 14 days.

## Step 2 — Load workspace context (parallel)

Read in parallel:

1. `work/context.md` — repo list and domain patterns
2. `work/tasks/todo.md` — current task states
3. `work/tasks/lessons.md` — full lessons list (extract entries dated within range)
4. `work/kb/.domain-map.md` — domain → KB file index

Do NOT load KB domain files upfront — only read a specific one if needed to clarify something mentioned in journals.

## Step 3 — Load journals and logs for each day in range (parallel)

For each calendar day in the range:

1. Try `work/journals/YYYY-MM-DD.md` first (synthesized daily summary — preferred).
2. If journal missing, fall back to `work/logs/YYYY-MM-DD.md` (raw session notes).
3. If both missing, mark day as no-activity.

## Step 4 — Extract structured data

**Activity per day:** repos / projects worked on, tasks attempted / completed / blocked, decisions made, PR/ticket/Confluence links (preserve verbatim).

**Task status (from todo.md):** completed during range; in-progress or blocked at range end.

**Lessons added during range (from lessons.md):** scan for section headers in the format `## {category} — {YYYY-MM-DD}` where the date falls within the range. Group by category (workflow / code / debugging / ops / infra).

**KB updates:** look for `## KB Updates` sections in journals, or any mention of KB files being updated. Note which files changed and what was added.

**Key Decisions:** scan journals for architectural, workflow, or process decisions — often found in reflection sections ("What I'd do differently", "Key Activities", or explicit decision notes).

## Step 5 — Generate the recap

### Weekly format (≤ 14 days)

```markdown
# Recap — Week of {Mon YYYY-MM-DD}

## Overview
{2–3 sentences: main focus, major outcomes, notable blockers or surprises}

## Day-by-Day

### {Weekday} YYYY-MM-DD
- {one bullet per significant task/outcome; include PR/ticket links}

(omit days with zero activity entirely)

## Tasks
**Completed:** {list with ticket/PR links}
**In Progress:** {list with current status}
**Blocked:** {list with blocker reason}

## Lessons Learned
{lessons added this period, grouped by category (workflow / code / debugging / ops / infra); "none" if empty}

## KB Updates
{KB file name: what was added — one line per file; "none" if nothing}

## Key Decisions
{notable architectural, workflow, or process decisions; "none" if nothing}

## Suggestions for Next Period
{see Step 6}
```

### Monthly format (> 14 days)

```markdown
# Recap — {Month YYYY}

## Overview
{3–4 sentences: main themes across the month, major outcomes, recurring blockers}

## Week 1 (Mon DD – Sun DD)
- {one bullet per significant task/outcome per day, or grouped by theme if dense}

## Week 2 (Mon DD – Sun DD)
...

## Week 3 / Week 4 ...
...

## Tasks
**Completed:** {list with ticket/PR links}
**In Progress:** {list with current status}
**Blocked:** {list with blocker reason}

## Lessons Learned
{grouped by category; "none" if empty}

## KB Updates
{KB file name: what was added — one line per file; "none" if nothing}

## Key Decisions
{notable decisions made this month; "none" if nothing}

## Suggestions for Next Period
{see Step 6}
```

## Step 6 — Suggestions for Next Period

This section is the forward-looking value of the recap — always generate it. 3–5 bullets, each specific enough to act on next period. Generic advice ("communicate better") is useless; name the actual task, pattern, or gap.

Draw from:
- **Blocked tasks**: what caused the block? Process gap, missing knowledge, waiting on someone?
- **Repeated lessons**: same category appearing more than once = a habit or system problem, not just bad luck
- **Deferred tasks**: if a task carried over from last period with no progress, name it and suggest a concrete unblocking action
- **KB gaps**: areas looked up repeatedly but not documented
- **Velocity imbalance**: if the period was dominated by reactive work (oncall, reviews), flag what got crowded out
- **Pain points from journals**: scan reflection sections ("What was harder than expected", "What I'd do differently") — these are direct signals of friction; suggest tooling, process, or habit fixes
- **Tech trends** (optional): if `work/kb/general/tech-trends.md` exists, skim it for anything directly relevant to problems encountered this period — a new tool or pattern that could reduce recurrence of a pain point. Only surface this if there's a concrete connection, not as a general "go read the digest" suggestion

```markdown
## Suggestions for Next Period

- {e.g. "Unblock #5 IN-11620: ping Orchestrator team in Slack by Wed — it's been waiting 2 weeks"}
- {e.g. "Reserve 2h for #3 ADF CDC research — deferred 3 times, write even a rough draft"}
- {e.g. "Add Snowflake task failure patterns to KB — came up twice with no runbook"}
```

## Notes

- **Preserve all links** — PR URLs, Jira tickets, Confluence pages must appear verbatim.
- **Degrade gracefully** — use logs as fallback when journals are missing; skip days where both are absent.
- **No KB full-load** — only read specific KB files when needed to clarify journal content.
- **Output**: always display in chat AND write to `work/recaps/{period}.md` (e.g. `work/recaps/2026-W11.md` for weekly, `work/recaps/2026-03.md` for monthly). Create `work/recaps/` if it doesn't exist. After writing, print: `Recap saved → work/recaps/{period}.md`
