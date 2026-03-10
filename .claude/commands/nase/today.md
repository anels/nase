Plan today's work — quick morning kickoff focused on what to do today. Run at the start of each work session or when asked "what should I work on?", "what's my plan for today?", or "morning standup". Reads todo.md and yesterday's log to surface the top 1–3 priorities.

## Why
A focused kickoff prevents drift. The goal is to pick 1–3 things and start — not to plan the whole week. Spend 2 minutes here, not 20.

## Steps

<workflow>

### 1. Context
- Read `work/tasks/todo.md` — identify In Progress + top Pending items
- Rank by impact × urgency. In-progress items take priority over new ones — context-switching is expensive.
- Read `work/logs/{yesterday}.md` (last working day) — one-line summary of what was done

### 2. Today's commits so far (if any)
- For each repo in `work/context.md`: `git -C {repo} log --since="midnight" --oneline --branches 2>/dev/null`

### 3. Output

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
```

</workflow>

## Notes
- Emphasis on **what to do today** — yesterday is context only, keep it brief
- Focus list should be actionable and realistic for one day
- Skip completed items
