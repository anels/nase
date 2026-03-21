---
name: nase:today
description: Plan today's work — quick morning kickoff focused on what to do today. Use at the start of each work session, or when asked "what should I work on?", "morning kickoff", "morning standup", "daily plan", "what's my plan for today?", "start of day", or "daily kickoff".
---

## Why
A focused kickoff prevents drift. The goal is to pick 1–3 things and start — not to plan the whole week. Spend 2 minutes here, not 20.

## Steps

<workflow>

### 1. Context
- Read `work/tasks/todo.md` — identify In Progress + top Pending items
- Rank by impact × urgency. In-progress items take priority over new ones — context-switching is expensive.
- Read `work/logs/{yesterday}.md` (last working day — compute yesterday as the most recent `work/logs/YYYY-MM-DD.md` file before today; may skip weekends) — one-line summary of what was done

### 2. Stale KB Check
- Read `work/kb/.domain-map.md` — collect all `## Projects` entries
- For each project KB file, extract the `<!-- Last updated: YYYY-MM-DD -->` date
  - If the date is **older than 7 days**: add to stale list
  - If the date is missing: also add to stale list (note: "no update date found")
- If any stale entries exist, include a **Stale KB** section in the output (see Step 4)

### 3. Today's commits so far (if any)
<parallel>
- For each repo in `work/context.md`: `git -C {repo} log --since="midnight" --oneline --branches 2>/dev/null`
</parallel>

### 4. Output

```
**Today's Plan — {YYYY-MM-DD}**

Yesterday: [one-line summary]

**Focus**
1. [top priority item from todo — In Progress or top Pending]
2. [next item]
3. [next item if relevant]

**Backlog (parked)**
- [On Hold or lower priority items, one line each]

**Blockers**
- [any open questions or waiting-on, or "None"]

**Stale KB** (not updated in 7+ days)
- `{domain}` — last updated {date} → run `/nase:onboard {repo-path}`
[omit this section entirely if all KB entries are fresh]
```

</workflow>

## Notes
- If today's tech digest hasn't been run yet, suggest `/nase:tech-digest` first
- Emphasis on **what to do today** — yesterday is context only, keep it brief
- Focus list should be actionable and realistic for one day
- Skip completed items
