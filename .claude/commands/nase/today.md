---
name: nase:today
description: Plan today's work — quick morning kickoff focused on what to do today. Use at the start of each work session, or when asked "what should I work on?", "morning kickoff", "morning standup", "daily plan", "what's my plan for today?", "start of day", or "daily kickoff".
---

## Why
A focused kickoff prevents drift. The goal is to pick 1–3 things and start — not to plan the whole week. Spend 2 minutes here, not 20.

## Steps

<workflow>

Run steps 1–4 in parallel, then combine into Step 5 output.

### 1. Local context
- Read `workspace/tasks/todo.md` — identify In Progress + top Pending items; rank by impact × urgency (in-progress first)
- Read `workspace/logs/{yesterday}.md` (most recent `workspace/logs/YYYY-MM-DD.md` before today) — one-line summary of what was done

### 2. Stale KB Check
- Read `workspace/kb/.domain-map.md` — collect all `## Projects` entries
- For each project KB file, extract the `<!-- Last updated: YYYY-MM-DD -->` date
  - Older than 7 days or missing → add to stale list

### 3. Today's commits so far (if any)
- Read repo local paths from `.local-paths` (skip comment/blank lines, format: `RepoName=/path`). For each path: `git -C {path} log --since="midnight" --oneline --branches 2>/dev/null`

### 4. Jira + Slack pulse (run in parallel; degrade gracefully if MCP unavailable)

**4a. Jira — my open tickets**
- Read `## Jira` section from `workspace/config.md` to get `cloudId`
- Use Atlassian MCP `searchJiraIssuesUsingJql`: `assignee = currentUser() AND status in ("In Progress", "To Do", "Open") AND updated >= -7d ORDER BY updated DESC`
- Limit to 10 results; extract: ticket key, summary, status
- If Atlassian MCP unavailable or `cloudId` missing from config: skip silently

**4b. Slack — hot discussions + mentions (last 24h)**

Two parallel queries:
1. **Configured channels**: read `## Slack > channels` list from `workspace/config.md`; search each channel for threads active in the last 24h (≥ 3 replies or reactions); extract: channel, one-sentence summary, thread link
2. **@mentions**: search `to:me after:{yesterday}` across all channels to find threads where you were mentioned or pinged

Merge results, deduplicate, sort by recency. Limit to **top 10 threads** total. For each show: `#{channel}: "{one-sentence summary}" — {link}`.
If Slack MCP unavailable or no results: skip silently.

### 5. Output

```
**Today's Plan — {YYYY-MM-DD}**

Yesterday: [one-line summary from Step 1]

**Focus**
1. [top priority item — In Progress or top Pending from todo]
2. [next item]
3. [next item if relevant]

**Backlog (parked)**
- [On Hold or lower priority items, one line each]

**Blockers**
- [any open questions or waiting-on, or "None"]

**Jira** (if results from Step 4a)
- [{KEY}] {summary} — {status}
[omit section entirely if no results or MCP unavailable]

**Slack Pulse** (if results from Step 4b)
- #{channel}: "{one-sentence summary}" — {link}
[omit section entirely if no hot threads or MCP unavailable]

**Today's Commits** (if any)
- [{RepoName}: {short commit summaries from Step 3}]
[omit this section entirely if no commits found today]

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
- Bookend: end the day with `/nase:wrap-up` to capture reflections, lessons, and a journal entry
