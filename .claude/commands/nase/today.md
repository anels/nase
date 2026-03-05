Plan today's work — quick morning kickoff focused on what to do today.

## Steps

<workflow>

### 1. Context
- Read `work/tasks/todo.md` — identify In Progress + top Pending items
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
