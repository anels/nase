---
name: nase:today
description: "Build a live-status-checked daily plan from workspace, PR, Jira, Slack, and Confluence context. Use for today, morning kickoff, daily plan, standup, or what should I work on."
argument-hint: "[date or focus]"
category: Learning & reflection
---

Create a concise daily plan from current evidence. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Use `.claude/docs/closing-block.md` for the final card.

## Steps

### 0. Local state

Resolve the date, optional focus, logs, tasks, active efforts, recent lessons, and KB staleness with `nase-workspace-state-scanner`, and use `.claude/docs/repo-resolution.md` for repo/KB lookup. That agent is `Read, Grep, Glob` by design and has no Bash, so it cannot produce today's commits. Run the `git -C {repo_path} log` reads in the main thread and pass the resulting lines into the scanner's prompt as supplied evidence - the agent consumes git state, it does not gather it. Never widen the agent to close this gap.

Read the day's skill-usage counts from the helper rather than having the scanner derive them from logs:

```bash
python3 .claude/scripts/today-stats.py --date "{resolved_date}"
```

It prints `total_invocations=` and `unique_skills=`, then one `skill <name> <count>` line per skill, and exits 0 with zeros for a date that has no telemetry. Hold that output for Step 2. Leave the scanner to tasks, efforts, and lessons, which need judgment rather than counting.

### 1. Live status sync

Normalize every structured effort/todo PR field into a unique normalized PR reference. Keep the three PR sets separate: delivery, report-only, and dependency. Do not treat arbitrary body URLs as delivery evidence.

Batch the live reads for effort-file PRs in one pass instead of one agent per PR:

```bash
python3 .claude/scripts/effort-pr-sweep.py --format json
```

Top-level `live` is the PR-state source for every PR cited by `workspace/efforts/*.md`: a map keyed by PR reference carrying state, reviewDecision, mergedAt, mergeCommit, and failing/pending checks. Each `efforts[]` entry also carries an `invisible` list; handle it per `.claude/docs/effort-drift.md → Classifier Blind Spots`, which owns the rule for which hints are actionable.

The sweep globs effort files only, so a PR cited solely by `workspace/tasks/todo.md` appears in neither `live` nor the unreadable set. For those, and for any PR the sweep reports as unreadable, run the `gh` query in the main thread and hand the result to `nase-pr-metadata-reader` to read - it is `Read, Grep, Glob` with no Bash, and its own contract states the main thread performs every CLI/API query. With no active effort files the sweep exits 0 having written nothing to stdout, so treat empty output as "no efforts to sync" rather than parsing it.

Read failures stay visible and block automatic lifecycle changes for the affected item. Apply `.claude/docs/effort-drift.md → Drift Auto-Sync` and `.claude/scripts/effort-state.py`; route any local update through `.claude/docs/workspace-write-guard.md`.

### 2. Maintenance and context

Run the bounded KB staleness/gap checks, scheduled maintenance checks, and today's local activity. Take the skill-usage counts from the Step 0 helper output rather than re-deriving them; commits and log activity still come from Step 0's scanner reads. Keep maintenance behind active delivery work unless it is overdue or blocking.

### 3. Jira, Slack, and Confluence pulse

Slack/Jira MCP queries stay in the main thread because they depend on live connector context. Query only the bounded recent window and degrade each connector independently. Suppress resolved, already replied/reacted, assigned-away, and unchanged items. Confluence activity is read-only.

### 4. Need Attention scan + action menu

Rank confirmed blockers, requested reviews, failing CI, direct replies, Jira actions, stale decisions, and due maintenance. Ties break in that order: something blocking another person outranks failing CI, which outranks a direct reply owed, which outranks Jira and stale decisions, which outrank due maintenance. Within one class, older first.

Re-check live state before presenting an action. Rank a Slack item by its resolved thread state, not by the top-level message: read the whole thread, and suppress it when anyone answered and the asker acknowledged - not only when the reply was yours. A top-level-only read promotes closed items and buries open ones. Try jev first for that suppression call (`.claude/docs/jev-judgment-points.md`, point `today.slack-thread-resolved`, `--type Noul`; state = the thread's messages trimmed to author plus first line each). The question is "is this thread resolved?", and its criteria are the two conditions just stated: someone answered, and the asker acknowledged. Confidence < 0.9, missing, or unavailable → judge the thread yourself the same way. Include a direct URL for every external item and never manufacture an empty-queue claim when connector coverage is partial.

Offer only actions supported by the gathered evidence. External mutations remain draft-first or explicitly gated under `.claude/docs/external-mutation-policy.md`.

### 5. Closing block

Render the compact TLDR/tint card from `.claude/docs/closing-block.md`.

### 6. Output

Return focus, need-attention items, PR/Jira pulse, maintenance, and up to three concrete next actions. Keep raw query output and full tables out of chat.

### 7. Self-log

Append one bounded daily-log line using `.claude/docs/daily-log-format.md`. Do not rewrite the log.

`/nase:tech-digest` is optional and runs only when the user asks for tech news or a refresh.
