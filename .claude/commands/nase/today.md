---
name: nase:today
description: Plan today's work — quick morning kickoff focused on what to do today, with proactive Need Attention items (live status-checked — PR review/CI state, Slack replies/reactions, Confluence page activity) and optional concrete next actions from KB, logs, tasks, Jira, Slack, and Confluence. Use at the start of each work session, or when asked "what should I work on?", "morning kickoff", "morning standup", "daily plan", "what's my plan for today?", "start of day", or "daily kickoff".
argument-hint: "[date or focus]"
when_to_use: "Morning kickoff / daily plan. Surfaces today's focus, status-syncs tracked PR/Jira work, and checks Need Attention items with bounded live PR/CI, Slack reply/reaction, and Confluence page activity. Use for \"what should I work on?\", \"morning kickoff\", \"daily plan\", \"start of day\", or \"daily standup\"."
pattern: pipeline
category: Learning & reflection
sub-patterns: [fan-out]
---

## Why
A focused kickoff prevents drift. The goal is to pick 1–3 things and start — not to plan the whole week. Spend 2 minutes here, not 20.

**Input:** $ARGUMENTS — optional flags
- `--verbose`: include full lists (no caps on Active Efforts, Jira, Slack Pulse). Default is the **compact view** with caps applied.

Follows `.claude/docs/workspace-write-guard.md` for status-sync edits to `workspace/tasks/` and `workspace/efforts/`.

Fan-out threshold: stay main-thread unless the request spans multiple repos, more than 20 files, more than 1000 diff lines, or the user explicitly asks for deep/batch work. Prefer compact script output before spawning agents.

## Steps

<workflow>

Run Step 0 first (preflight, blocking), then Step 1 (needed by 1b), then Steps 1b–4b (including 4b-conf) in parallel, then Step 4c (Need Attention — which runs a bounded live status-check on the top surfaced items before the action menu), then combine into Step 5 output. Honor `--verbose` from $ARGUMENTS for output caps in Step 5. Generate Step 4d (closing block) last so it can draw on the full picture and render as the final visible block.

Local fan-out: use `nase-workspace-state-scanner` for tasks/logs/efforts/scheduled maintenance and `nase-pr-metadata-reader` for tracked PR status summaries when there are multiple PR references.
Slack/Jira MCP queries stay in the main thread because they depend on live connector auth, user identity, and filtering state; the Step 4b-conf Confluence check stays main-thread for the same reason.
The main thread owns status-sync writes and the final Need Attention ranking.

**Bash idioms (avoid PATH/zsh pitfalls):**
- Do **not** use `cut`, `awk`, `sed` inside `$(...)` subshells — Bash-tool zsh PATH is inconsistent and RTK hook can mangle pipelines. Use bash parameter expansion instead: `path="${line#*=}"`, `st="${st_line#status: }"`.
- Do **not** name variables `status` — zsh reserves it read-only. Use `st`, `pr_state`, etc.
- When external utilities are unavoidable, call by absolute path: `/usr/bin/grep`, `/usr/bin/stat`, `/opt/homebrew/bin/gh`, `/usr/bin/jq`.
- For `.local-paths` reads, use `/usr/bin/grep "^${key}=" .local-paths` + `${line#*=}`.
- For YAML frontmatter `status:` reads, use `/usr/bin/grep -m1 "^status:" "$f"` + `${st_line#status: }`.

### 0. Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. If `workspace/config.md` is missing, default English and note it in the Yesterday line.

### 1. Local context
- Read `workspace/tasks/todo.md` — identify In Progress + top Pending items; rank by impact × urgency (in-progress first)
- Read `workspace/logs/{yesterday}.md` (most recent `workspace/logs/YYYY-MM-DD.md` before today) — one-line summary of what was done. If no prior log files exist, display "No previous activity logged" for the Yesterday line

### 1b. Status Sync (auto-update tracked items)

Scan `workspace/tasks/todo.md` and active `workspace/efforts/*.md` for tracked PRs and Jira tickets. Check their current status and update files in-place. This step keeps the morning kickoff accurate without manual status maintenance.
Before applying any status update, stage the target file change under `workspace/tmp/`, show a short diff summary, and run the final mtime/hash drift check. Append-only daily-output files are not part of this step.

**1b-i. Extract tracked items:**
- From `todo.md`: find all lines containing `[ ]` (unchecked) that have GitHub PR URLs (`github.com/{owner}/{repo}/pull/{number}`) or Jira ticket keys (`[A-Z]+-\d+`). Skip `[x]` lines — they're already done.
- From `workspace/efforts/*.md`: read each file's YAML frontmatter. The active path itself requires reconciliation; do not skip a file because its status looks terminal. Extract structured delivery PRs per `.claude/docs/effort-lifecycle.md → Drift Auto-Sync`, report-only PRs per `PR Reference Resolution`, dependency PRs from `blocked-by`, and the `jira:` key. Keep the three PR sets separate while normalizing/deduping them.

**1b-ii. Check PR statuses (via Bash):**
For each unique normalized PR reference found, run:
```bash
gh pr view {number} --repo {owner}/{repo} --json state,mergedAt,closedAt --jq '{state,mergedAt,closedAt}'
```
If `gh` fails for a todo-only or report-only PR, skip that check silently. For a delivery or dependency PR, record it as unreadable, prevent that effort's transition, and report the unresolved read.

**1b-iii. Check Jira statuses (via MCP):**
Read `cloudId` from `workspace/config.md` `## Jira` section. For each unique Jira ticket key, use Atlassian MCP `getJiraIssue` to fetch current status. Extract the status category name.
If Atlassian MCP is unavailable or `cloudId` is missing, todo-only Jira checks may be skipped silently. Mark each tracked effort Jira input unreadable, prevent that effort's transition, and report the unresolved read.

**1b-iv. Apply updates to `todo.md`:**
- PR state `MERGED` → change `[ ]` to `[x]`, append or update status annotation to `merged {YYYY-MM-DD}` (use `mergedAt` date)
- PR state `CLOSED` (not merged) → wrap task title in `~~strikethrough~~`, append `closed (not merged)`
- PR state `OPEN` → no change to checkbox or annotation
- Jira status category `Done`/`Closed`/`Resolved` on a `[ ]` item that has no associated PR → change `[ ]` to `[x]`
- Do NOT touch lines already marked `[x]`

**1b-v. Apply updates to effort files:**
Pass the separated live states to the `effort-state.py` command in `.claude/docs/effort-lifecycle.md → Drift Auto-Sync`, apply its `transition` output exactly, and use the guarded `apply` or `apply-move` path.

**1b-vi. Collect change report:**
Build a list of all status changes applied. This list feeds the "**Status Updates**" section in the output (Step 5). If no changes were detected, this section is omitted.

**1b-vii. Active Efforts Snapshot:**
For every `workspace/efforts/*.md` (excluding `done/`) that remains active after the updates above, run the canonical classifier:

```bash
python3 .claude/scripts/effort-state.py --file "workspace/efforts/<slug>.md"
```

Use its `stage`, `evidence`, `pending_followups`, and `needs_live_verification` fields. The helper scans the whole file and uses the highest checked canonical stage (`Implementation started`, `PR opened`, `Merged`, `Deployed`) regardless of line order or a `## Lifecycle` header. Ordinary plan/grill checkboxes are not stage signals. A checked `Deployed` plus unchecked `Follow-up:` items becomes **Follow-up only**; no canonical stage falls back to frontmatter status. If `needs_live_verification` is true, resolve the conflict with the live PR/Jira read rather than guessing.

Capture: filename (without `.md`), stage, last-updated date (file mtime via `stat`), PR reference if any (per `.claude/docs/effort-lifecycle.md → PR Reference Resolution`; not a URL-only grep), status frontmatter value, and the single most informative pending checkbox text when the classifier supplies one. Group by stage for the output. Sort within each group by mtime descending. If `workspace/efforts/` is empty (or only contains `done/`), skip this snapshot.

### 1c. Scheduled Maintenance Check

Scan the `## Scheduled Maintenance` section in `workspace/tasks/todo.md` for items due today or overdue:

1. Find all unchecked (`[ ]`) lines matching either scheduled-maintenance format:
   - `📅 {YYYY-MM-DD} — \`/nase:{skill}\` — {reason}`
   - `{YYYY-MM-DD} - \`/nase:{skill}\` - {reason}`
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
- For each stale project, derive `{owner}/{repo}` for the `gh api` call:
  1. Resolve the project's local path via `.local-paths` (per `.claude/docs/repo-resolution.md`).
  2. Read the GitHub origin: `git -C {local-path} remote get-url origin`.
  3. Parse `owner/repo` from the origin URL (handle both `https://github.com/{owner}/{repo}(.git)?` and `git@github.com:{owner}/{repo}(.git)?`). Strip trailing `.git`.
  4. Detect the default branch: `git -C {local-path} symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's|^origin/||'`. Fall back to `main` if unset.
  - If any step fails (no local path, no origin, parse fails), skip this project's commit count silently — show the KB entry as stale without the `({N} new commits)` annotation.
- For each project where the derivation succeeded, count new commits merged to the default branch since the last KB update. `gh api --paginate -q 'length'` returns one length per page (not the total), so the previous "sum the paginated counts" instruction silently under-reported when pagination kicked in. Concatenate pages first, then count:
    ```bash
    gh api "repos/{owner}/{repo}/commits?sha={default-branch}&since={last-updated-date}T00:00:00Z" --paginate \
      | jq -s 'add | length'
    ```
    If `gh api` returns a non-zero exit code or empty output, treat the commit count as `unknown` and skip the staleness percentage for that repo — do not let the error propagate.
  - Show the count in the output as `({N} new commits)`

### 3. Today's commits so far (if any)
- Read repo local paths from `.local-paths` (only lines matching `RepoName=/path` pattern — skip `backup-target=`, comment lines starting with `#`, and blank lines). For each path: `git -C {path} log --since="{TODAY}T00:00:00" --oneline --branches 2>/dev/null` (use today's date in YYYY-MM-DD format — avoids timezone ambiguity from `"midnight"`)

### 4. Jira + Slack pulse (run in parallel; degrade gracefully if MCP unavailable)

**4a. Jira — my open tickets** (follow `.claude/docs/jira-lifecycle.md` for cloudId resolution, JQL patterns, and graceful degradation)
- `searchJiraIssuesUsingJql`: `assignee = currentUser() AND status in ("In Progress", "To Do", "Open") AND updated >= -7d ORDER BY updated DESC`
- Limit to 10 results; extract: ticket key, summary, status, updated timestamp, URL (construct as `{baseUrl}/browse/{KEY}` using `baseUrl:` from `workspace/config.md → ## Jira` — e.g. `https://your-org.atlassian.net/browse/PROJ-13067`)

**4b. Slack — hot discussions + mentions (last 24h)**

Two parallel queries:
1. **Configured channels**: read `## Slack > channels` list from `workspace/config.md`; search each channel for threads active in the last 24h (≥ 3 replies or reactions); extract: channel name, channel_id, one-sentence summary, thread_ts, plus the search payload's `from`/author and `reactions` fields if present.
2. **@mentions**: search `to:me after:{yesterday}` across all channels to find threads where you were mentioned or pinged; extract same fields as above.

Merge results, deduplicate, sort by recency. Keep **top 7 candidates** (lower cap than before — Slack Pulse only displays 5, so 7 leaves a small buffer for filter losses without paying for 15× thread reads).

**4b-filter. Exclude already-acknowledged threads (cheap → expensive):**

For each candidate, pass through two filter stages:

1. **Cheap pre-filter (no extra tool call):** if the search payload already shows the current user as the message `from` author OR the `reactions` field already lists the current user's ID, the user is aware — exclude immediately.
2. **Fallback to `slack_read_thread`** only for candidates that survived (1). Check:
   - **Replied** in the thread (any message where the author matches the current user), OR
   - **Reacted** with any emoji on any message in the thread (`reactions` field includes current user ID).

   If either is true, exclude.

This keeps `slack_read_thread` calls to the minimum needed — typically 0–3, not 15.

**4b-link. Construct clickable Slack thread permalinks:**
For each surviving thread, build the permalink using: `https://{workspace}.slack.com/archives/{channel_id}/p{thread_ts_without_dot}` (remove the `.` from thread_ts to form the `p` parameter). The workspace domain can be extracted from any Slack search result URL, or default to the team's known domain.

After filtering, limit to **top 5 threads** (matches the Step 5 output cap). For each show: `#{channel}: "{one-sentence summary}" — [link]({permalink})`.
If Slack MCP unavailable or no results: skip silently.

### 4b-conf. Confluence — tracked pages with new activity

Cheap discovery only. This finds Confluence pages your live work already points at and flags the ones that moved since you last touched them; the detailed comment read is deferred to the 4c enrichment pass so it only runs for pages that actually reach the top of Need Attention. This keeps the kickoff fast.

1. Grep Confluence page URLs from the workspace files that represent live work — this is what scopes the check to pages you care about right now:
   - `workspace/efforts/*.md` (excluding `done/`), unchecked (`[ ]`) lines in `workspace/tasks/todo.md`, and the two most recent `workspace/logs/YYYY-MM-DD.md`.
   - Extract with `/usr/bin/grep -rhoE 'https://[a-z0-9.-]+\.atlassian\.net/wiki/[^ )]+'`, dedupe, and cap at **5 unique pages**. Parse the numeric page id from the `/pages/{id}/` segment when present.
2. Resolve `cloudId` per `.claude/docs/jira-lifecycle.md` (same Atlassian connector as Jira). If `cloudId` is missing or the Atlassian MCP is unavailable, skip 4b-conf silently — never block the kickoff.
3. For each page id, fetch metadata via `getConfluencePage`. Flag the page as a Need Attention candidate when the latest version's author is **someone other than you** and the update is within the last 7 days (someone else moved a page tied to your work). Capture: page title, url, last editor, last-updated date.
4. Collect the flagged pages for the Need Attention sources in Step 4c. If no URLs are found, or none show recent non-self activity, skip silently — Confluence adds no output on a quiet day.

### 4c. Need Attention scan + action menu

Build a lightweight `need_attention_items` list from signals already gathered in Steps 1–4 plus one cheap log/lesson scan. This is daily triage, not a full report.

**Additional cheap scans:**
- **Recent KB gap signals:** run:
  ```bash
  RANGE=$(python3 .claude/scripts/date-resolve.py 7d)
  START=${RANGE%% *}
  END=${RANGE##* }
  GAP_OUTPUT=$(bash .claude/scripts/kb-gap-scan.sh --since "$START" --until "$END" 2>/dev/null)
  GAP_RC=$?
  printf '%s\n' "$GAP_OUTPUT" | head -20
  ```
  If `GAP_RC=0` and there are hits, add one item summarizing `{N} recent log/lesson signals` and an action candidate for `/nase:kb-gap-detect --days 7 --min-recurrence 1`. If `GAP_RC=2`, add nothing. If the script fails for another reason, add nothing and do not block kickoff.

**Sources:**
- Overdue or due-today scheduled maintenance from Step 1c
- Active efforts stalled by mtime or pending checkbox text from Step 1b-vii
- Stale project KB entries from Step 2, especially those with known new commits
- Recent KB-gap scan hits
- Jira tickets from Step 4a whose extracted `updated` timestamp is within the last 48h
- Slack Pulse threads from Step 4b that survived the already-acknowledged filter
- Confluence pages from Step 4b-conf flagged with recent non-self edits

**Stalled effort rules:**
- Add an active effort when the most informative pending checkbox contains `blocked`, `waiting`, `needs`, `open question`, `review`, `deploy`, or `follow-up`.
- Add an active effort when mtime is older than 3 days in **Implementing**, **In review**, or **Awaiting deploy**.
- Add an active effort when mtime is older than 7 days in **Planning** or **Follow-up only**.
- `tracking_only: true` efforts appear as awareness items only.

**Ranking order:**
1. User-unblocking items with a concrete next command (`/nase:design --review`, `/nase:onboard`, `/nase:kb-gap-detect`)
2. Overdue/due maintenance
3. In-review PRs, Slack/Jira, and Confluence items that likely need user response (enrichment below confirms which actually do)
4. Stale KB with known new commits
5. Stalled efforts
6. Awareness-only `tracking_only: true` items

For each item, store:
- `title` — short concrete target
- `reason` — why it needs attention today
- `suggested_action` — exact command or local workflow suggestion
- `candidate_type` — one of `Run maintenance`, `Refresh KB`, `Detect KB gaps`, `Review effort`, `Handle review/PR`, or `awareness-only`
- `status` — live status-check result (filled by the enrichment pass below; may be empty if not enriched)
- `waiting_on` — `you`, `others`, or `none` (set by enrichment; `none`/unset for items not enriched)
- `actionable` — false for tracking-only or informational items

**Live status enrichment (top surfaced items only — keep the kickoff fast):**

Ranking above gives you an ordered list; before rendering, refresh the *true* state of only the items that can affect the visible output: the top **3** actionable action-menu candidates, plus any Confluence candidates that already land inside the top **5** Need Attention output. Do NOT enrich tracking-only efforts or the whole candidate list: enriching everything is what would turn a 2-minute kickoff into a full audit, and most candidates never reach the menu. Enrich by type, then fold the result back into `reason`/`status`/`waiting_on`:

- **GitHub PR / review item** — one rich read (reuse the `state` already fetched in Step 1b; do not re-fetch state):
  ```bash
  gh pr view {number} --repo {owner}/{repo} \
    --json reviewDecision,statusCheckRollup,mergeable,isDraft \
    --jq '{reviewDecision, mergeable, isDraft,
           failing: ([.statusCheckRollup[]? | (.conclusion // .state // "")] | map(select(.=="FAILURE" or .=="ERROR" or .=="CANCELLED" or .=="TIMED_OUT")) | length),
           pending: ([.statusCheckRollup[]? | (.conclusion // .state // "PENDING")] | map(select(.=="PENDING" or .=="EXPECTED" or .=="")) | length)}'
  ```
  Then one GraphQL read for unresolved review threads (skip silently on any error):
  ```bash
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved}}}}}' \
    -F o={owner} -F r={repo} -F n={number} \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false)] | length'
  ```
  Derive a one-line live `status` + `waiting_on` + `suggested_action`:
  - `reviewDecision=CHANGES_REQUESTED` OR unresolved threads > 0 → `status: changes requested / {N} unresolved`, `waiting_on: you`, suggest `/nase:address-comments {PR-URL}`
  - `failing > 0` → `status: CI {failing} failing`, `waiting_on: you`
  - `mergeable=CONFLICTING` → `status: merge conflict`, `waiting_on: you`
  - `reviewDecision=REVIEW_REQUIRED` and it is **not** your PR → `status: review requested`, `waiting_on: you`, suggest `/nase:discuss-pr {PR-URL}`
  - `reviewDecision=APPROVED`, `failing=0`, no unresolved, `mergeable=MERGEABLE` → `status: approved, ready`, `waiting_on: none`, suggest `/nase:prep-merge {PR-URL}`
  - If `gh` fails, keep the Step 1b `state`, leave `status` empty, and skip enrichment for that item.

- **Slack thread item** — reuse the `slack_read_thread` payload already read in Step 4b-filter; do **not** read the thread again. From it derive reply count, latest author, and whether the last message is a question or @mention directed at you (`waiting_on: you`) vs. an FYI (`waiting_on: none`). Set `status` to `{N} replies, last from {author}`.

- **Confluence page item** — for the Confluence pages selected by the cap above, read new comments via `getConfluencePageFooterComments` / `getConfluencePageInlineComments` (and the version author from Step 4b-conf's `getConfluencePage`). Set `status` to `{N} new comments` or `edited by {author} {date}`. Confluence items stay `awareness-only` (no nase mutation skill posts to Confluence) — set `waiting_on: you` when a comment mentions you so it sorts high, but keep `actionable: false`.

After enrichment, **re-rank** using the refreshed signals (`waiting_on: you` items outrank `waiting_on: none`), and **drop** any item a live check proved resolved: PR merged or approved-and-you-already-know, Slack thread you already answered, Confluence page with no new activity. A stale reason that live state contradicts must not survive into the output.

Cap Need Attention output at 5 items by default; with `--verbose`, show all.

**Action menu:** derive up to three options from the highest-ranked actionable items, plus `Skip`. Allowed option types:
- `Run maintenance: /nase:{skill}` — due/overdue scheduled maintenance
- `Refresh KB: /nase:onboard {repo-path}` — stale project KB with commits and a resolved repo path
- `Detect KB gaps: /nase:kb-gap-detect --days 7 --min-recurrence 1` — recent log/lesson signals
- `Review effort: /nase:design --review {slug}` — stalled active planning/implementation effort
- `Handle review/PR: {command}` — local workflow suggestion only, such as `/nase:discuss-pr {PR-URL}` or `/nase:address-comments {PR-URL}`

Do not include awareness-only items or `tracking_only: true` efforts. Do not run full `/nase:kb-review`, full `/nase:kb-gap-detect`, `/nase:onboard`, or any Slack/Jira/GitHub mutation unless the user selects a delegated action.

In Step 5, render through `**Need Attention**` first. If action candidates exist, immediately invoke `AskUserQuestion` after `**Need Attention**` and before `**Focus**`; otherwise continue rendering Step 5. Use the conversation language from Step 0.

```
question: "这些需要我现在处理吗？"
header: "Need Action"
multiSelect: true when more than one independent action exists; otherwise false
options:
  - label: "{candidate_type}: {specific target}" , description: "{exact command, path, PR URL, repo path, or reason}"
  - label: "Skip"                                , description: "只保留今日计划，不执行额外动作"
```

Menu rules:
- Present at most four options total: up to three candidates plus `Skip`.
- Labels must name the specific target; descriptions must name the command/path/URL.
- If `Skip` is selected, continue Step 5 without extra work.
- Execute selected actions in this order: run maintenance, refresh KB, detect KB gaps, review effort, handle review/PR.
- Delegated skills keep their own external-mutation gates; `/nase:today` does not directly send Slack, Jira, or GitHub mutations.
- After selected actions finish, add `Action result: {command} → {outcome/path}` immediately before `**Focus**`.
- Generate the closing block only after selected actions and final Step 5 rendering are complete.

### 4d. Closing block (TLDR + tint)

Follow `.claude/docs/closing-block.md` for shape, name resolution, style palette, and generation rules.

**Per-skill delta for `/nase:today`:** TLDR items are lifted from the sections already drafted in this run — Need Attention count, Focus count, hot PR numbers, named blockers, stale-KB count, Jira hot tickets. Tint is forward-looking (kickoff flavor). For the style-rotation check, read yesterday's `workspace/logs/{yesterday}.md` only. In the new format, use the second non-empty `│     ...` content line inside the prior closing card; fall back to `^│ tint:` and then legacy `^｜` during format migration.

### 5. Output

**Output caps (default — compact view):**
- **Active Efforts:** show top **3 per stage** (sorted by mtime desc within stage). If a stage has more, append `(+N more — run /nase:today --verbose for full list)` on the last line of that stage.
- **Jira:** show top **5** tickets.
- **Slack Pulse:** show top **5** threads.
- **Today's Commits:** show top **5** per repo.
- **Stale KB:** show top **5** oldest entries.
- **Need Attention:** show top **5** highest-ranked items.

**With `--verbose`:** drop all caps — show full lists for every section.

The "omit section entirely if empty" rules below still apply in both modes.

```
**Today's Plan — {YYYY-MM-DD}**

Yesterday: [one-line summary from Step 1]

**Status Updates** (if any changes from Step 1b)
- ✓ {task name} — PR #{N} merged {date} → marked complete
- ✗ {task name} — PR #{N} closed (not merged) → marked closed
- ✓ effort/{file} — all PRs merged → status: completed → moved to efforts/done/
[omit section entirely if no status changes detected]

**Active Efforts** ({total count} unfinished, from Step 1b-vii)
- 🟢 In review ({N}): `{effort-name}` — [PR #{num}]({url}) ({last-updated})
- 🟡 Implementing ({N}): `{effort-name}` — {next pending checkbox} ({last-updated})
- 🔵 Planning ({N}): `{effort-name}` — status: {frontmatter status} ({last-updated})
- 🟣 Awaiting deploy ({N}): `{effort-name}` — PR merged, deploy pending ({last-updated})
- ⚪ Follow-up only ({N}): `{effort-name}` — {N} open follow-ups ({last-updated})
[group by stage; within each stage list sorted by mtime descending; omit empty stages; omit entire section if no active efforts]

**Maintenance Due** (if any from Step 1c)
- 🔴 overdue ({N} days): `/nase:{skill}` — {reason}
- 🟡 due today: `/nase:{skill}` — {reason}
- 🔵 upcoming ({date}): `/nase:{skill}` — {reason}
[omit section entirely if nothing due within 3 days]

**Need Attention** (if any from Step 4c)
- 🔴 {title} — {reason} [{status}; waiting on {waiting_on}]. Suggested: `{suggested_action}`
- 🟡 {title} — {reason} [{status}]. Suggested: `{suggested_action}`
- 🔵 {title} — {reason}. Suggested: `{suggested_action}`
[ranked by Step 4c; show the `[{status}; waiting on …]` bracket only for enriched items — omit it for un-enriched items rather than printing empty brackets; cap at 5 unless --verbose; omit section entirely if empty]
[if action candidates exist, invoke AskUserQuestion here, execute selected actions, then print `Action result: ...` before continuing]

**Focus**
1. [top priority item — In Progress or top Pending from todo]
2. [next item]
3. [next item if relevant]

**Backlog (parked)**
- [On Hold or lower priority items, one line each]

**Blockers**
- [any open questions or waiting-on, or "None"]

**Jira** (if results from Step 4a)
- [[{KEY}]({baseUrl}/browse/{KEY})] {summary} — {status}
[omit section entirely if no results or MCP unavailable]

**Slack Pulse** (if results from Step 4b)
- #{channel}: "{one-sentence summary}" — [thread]({permalink})
[omit section entirely if no hot threads or MCP unavailable]

**Today's Commits** (if any)
- [{RepoName}: {short commit summaries from Step 3}]
[omit this section entirely if no commits found today]

**Stale KB** (not updated in 7+ days, oldest first)
- `{domain}` — last updated {date} ({N} new commits) → run `/nase:onboard {repo-path}`
[omit this section entirely if all KB entries are fresh; omit commit count if unavailable]

╭─ {Name}
│
│     {TLDR — see `.claude/docs/closing-block.md`}
│
│     {tint — see `.claude/docs/closing-block.md`}
│
╰─
```

### 6. Self-log (mandatory)

Append a `today` bullet per `.claude/docs/daily-log-format.md → Self-logging rule`. Summary content: Focus picks or top blocker.

</workflow>

## Notes
- `/nase:tech-digest` is optional. Do not add it to `/nase:today` Need Attention or the proactive action menu just because today's digest is missing.
- Emphasis on **what to do today** — yesterday is context only, keep it brief
- Focus list should be actionable and realistic for one day
- Skip completed items
- Bookend: end the day with `/nase:wrap-up` to capture reflections, lessons, and a journal entry
- Language: Step 0 preflight is **mandatory** — read `workspace/config.md → ## Language` and write Step 5 in the `conversation:` value (not English by default). See `.claude/docs/language-config.md` for the full algorithm.
