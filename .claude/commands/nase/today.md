---
name: nase:today
description: Plan today's work — quick morning kickoff focused on what to do today. Use at the start of each work session, or when asked "what should I work on?", "morning kickoff", "morning standup", "daily plan", "what's my plan for today?", "start of day", or "daily kickoff".
---

## Why
A focused kickoff prevents drift. The goal is to pick 1–3 things and start — not to plan the whole week. Spend 2 minutes here, not 20.

## Steps

<workflow>

Run Step 1 first (needed by 1b), then run Steps 1b–4 in parallel, then combine into Step 5 output.

### 1. Local context
- Read `workspace/tasks/todo.md` — identify In Progress + top Pending items; rank by impact × urgency (in-progress first)
- Read `workspace/logs/{yesterday}.md` (most recent `workspace/logs/YYYY-MM-DD.md` before today) — one-line summary of what was done. If no prior log files exist, display "No previous activity logged" for the Yesterday line

### 1b. Status Sync (auto-update tracked items)

Scan `workspace/tasks/todo.md` and active `workspace/efforts/*.md` for tracked PRs and Jira tickets. Check their current status and update files in-place. This step keeps the morning kickoff accurate without manual status maintenance.

**1b-i. Extract tracked items:**
- From `todo.md`: find all lines containing `[ ]` (unchecked) that have GitHub PR URLs (`github.com/{owner}/{repo}/pull/{number}`) or Jira ticket keys (`[A-Z]+-\d+`). Skip `[x]` lines — they're already done.
- From `workspace/efforts/*.md`: read each file's YAML frontmatter. **Skip** files where `status:` is `completed` or `closed`. For active files, extract PR URLs from the body (regex: `github.com/([^/]+)/([^/]+)/pull/(\d+)`) and `jira:` key from frontmatter.

**1b-ii. Check PR statuses (via Bash):**
For each unique PR URL found, run:
```bash
gh pr view {number} --repo {owner}/{repo} --json state,mergedAt,closedAt --jq '{state,mergedAt,closedAt}'
```
If `gh` fails for any PR (network error, repo access), skip that PR silently.

**1b-iii. Check Jira statuses (via MCP):**
Read `cloudId` from `workspace/config.md` `## Jira` section. For each unique Jira ticket key, use Atlassian MCP `getJiraIssue` to fetch current status. Extract the status category name.
If Atlassian MCP unavailable or `cloudId` missing: skip all Jira checks silently.

**1b-iv. Apply updates to `todo.md`:**
- PR state `MERGED` → change `[ ]` to `[x]`, append or update status annotation to `merged {YYYY-MM-DD}` (use `mergedAt` date)
- PR state `CLOSED` (not merged) → wrap task title in `~~strikethrough~~`, append `closed (not merged)`
- PR state `OPEN` → no change to checkbox or annotation
- Jira status category `Done`/`Closed`/`Resolved` on a `[ ]` item that has no associated PR → change `[ ]` to `[x]`
- Do NOT touch lines already marked `[x]`

**1b-v. Apply updates to effort files:**
- If **all** tracked PRs for an effort are `MERGED` AND Jira ticket (if any) is Done → update frontmatter `status: completed`, then move the file from `workspace/efforts/` to `workspace/efforts/done/` (create the `done/` directory if it doesn't exist)
- If any PR is `CLOSED` (not merged) and no other open/merged PR exists for the effort → update frontmatter `status: closed`, then move to `workspace/efforts/done/`
- If any PR is still `OPEN` → do NOT change the effort status

**1b-vi. Collect change report:**
Build a list of all status changes applied. This list feeds the "**Status Updates**" section in the output (Step 5). If no changes were detected, this section is omitted.

### 1c. Scheduled Maintenance Check

Scan the `## Scheduled Maintenance` section in `workspace/tasks/todo.md` for items due today or overdue:

1. Find all unchecked (`[ ]`) lines matching pattern: `📅 {YYYY-MM-DD} — \`/nase:{skill}\` — {reason}`
2. Parse the date from each line
3. Classify:
   - **Overdue**: date < today
   - **Due today**: date == today
   - **Upcoming** (next 3 days): today < date ≤ today + 3
4. Collect these for the output in Step 5. If none are due/overdue, skip the section.

### 2. Stale KB Check
- Read `workspace/kb/.domain-map.md` — collect all `## Projects` entries
- For each project KB file, extract the `<!-- Last updated: YYYY-MM-DD -->` date
  - Older than 7 days or missing → add to stale list
- Sort the stale list by last-updated date ascending (oldest first)
- For each stale project that has a local repo path in `.local-paths`, run: `gh api repos/{owner}/{repo}/commits?sha={default-branch}&since={last-updated-date}T00:00:00Z --paginate -q 'length'` to count new commits merged to the default branch since the last KB update. Sum the paginated counts. If `gh api` returns a non-zero exit code or empty output, treat the commit count as `unknown` and skip the staleness percentage for that repo — do not let the error propagate.
  - Show the count in the output as `({N} new commits)`

### 3. Today's commits so far (if any)
- Read repo local paths from `.local-paths` (only lines matching `RepoName=/path` pattern — skip `backup-target=`, comment lines starting with `#`, and blank lines). For each path: `git -C {path} log --since="{TODAY}T00:00:00" --oneline --branches 2>/dev/null` (use today's date in YYYY-MM-DD format — avoids timezone ambiguity from `"midnight"`)

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

**Status Updates** (if any changes from Step 1b)
- ✓ {task name} — PR #{N} merged {date} → marked complete
- ✗ {task name} — PR #{N} closed (not merged) → marked closed
- ✓ effort/{file} — all PRs merged → status: completed → moved to efforts/done/
[omit section entirely if no status changes detected]

**Maintenance Due** (if any from Step 1c)
- 🔴 overdue ({N} days): `/nase:{skill}` — {reason}
- 🟡 due today: `/nase:{skill}` — {reason}
- 🔵 upcoming ({date}): `/nase:{skill}` — {reason}
[omit section entirely if nothing due within 3 days]

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

**Stale KB** (not updated in 7+ days, oldest first)
- `{domain}` — last updated {date} ({N} new commits) → run `/nase:onboard {repo-path}`
[omit this section entirely if all KB entries are fresh; omit commit count if unavailable]
```

</workflow>

## Notes
- If today's tech digest hasn't been run yet, suggest `/nase:tech-digest` first
- Emphasis on **what to do today** — yesterday is context only, keep it brief
- Focus list should be actionable and realistic for one day
- Skip completed items
- Bookend: end the day with `/nase:wrap-up` to capture reflections, lessons, and a journal entry
- If the user specifies a conversation language in config.md, use it for the output summary.
