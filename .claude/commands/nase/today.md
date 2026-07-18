---
name: nase:today
description: "Build a live-status-checked daily plan from workspace, PR, Jira, Slack, and Confluence context. Use for today, morning kickoff, daily plan, standup, or what should I work on."
argument-hint: "[date or focus]"
pattern: pipeline
category: Learning & reflection
sub-patterns: [fan-out]
---

Create a concise daily plan from current evidence. Run `.claude/docs/language-config.md` first and use `.claude/docs/closing-block.md` for the final card.

## Steps

### 0. Local state

Resolve the date, optional focus, logs, tasks, active efforts, recent lessons, KB staleness, and today's commits. Use `nase-workspace-state-scanner` for bounded local reads and `.claude/docs/repo-resolution.md` for repo/KB lookup.

### 1. Live status sync

Normalize every structured effort/todo PR field into a unique normalized PR reference. Keep the three PR sets separate: delivery, report-only, and dependency. Do not treat arbitrary body URLs as delivery evidence.

Use `nase-pr-metadata-reader` for GitHub metadata. Read failures stay visible and block automatic lifecycle changes for the affected item. Apply `.claude/docs/effort-lifecycle.md` and `.claude/scripts/effort-state.py`; route any local update through `.claude/docs/workspace-write-guard.md`.

### 2. Maintenance and context

Run the bounded KB staleness/gap checks, scheduled maintenance checks, and today's local activity. Keep maintenance behind active delivery work unless it is overdue or blocking.

### 3. Jira, Slack, and Confluence pulse

Slack/Jira MCP queries stay in the main thread because they depend on live connector context. Query only the bounded recent window and degrade each connector independently. Suppress resolved, already replied/reacted, assigned-away, and unchanged items. Confluence activity is read-only.

### 4c. Need Attention scan + action menu

Rank confirmed blockers, requested reviews, failing CI, direct replies, Jira actions, stale decisions, and due maintenance. Re-check live state before presenting an action. Include a direct URL for every external item and never manufacture an empty-queue claim when connector coverage is partial.

Offer only actions supported by the gathered evidence. External mutations remain draft-first or explicitly gated under `.claude/docs/external-mutation-policy.md`.

### 4d. Closing block

Render the compact TLDR/tint card from `.claude/docs/closing-block.md`.

### 5. Output

Return focus, need-attention items, PR/Jira pulse, maintenance, and up to three concrete next actions. Keep raw query output and full tables out of chat.

### 6. Self-log

Append one bounded daily-log line using `.claude/docs/daily-log-format.md`. Do not rewrite the log.

`/nase:tech-digest` is optional and runs only when the user asks for tech news or a refresh.
