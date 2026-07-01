---
name: nase:efforts
description: "Report all active efforts by lifecycle stage and status, flag PR/Jira drift, and count active vs done. Use for list my efforts, effort status, stalled work, or what am I working on. Read-only; use /nase:today to move completed efforts and /nase:stats for activity counts."
argument-hint: "[--active|--done|--all]"
pattern: utility
category: Reporting
---

## Purpose

`/nase:today` shows a capped morning snapshot and owns the status-sync mutations (moving finished efforts to `done/`). This skill answers a different question: *across all my efforts right now, where does everything stand?* — a full count and inventory, plus the one thing a stale frontmatter field can't tell you: which docs have fallen out of sync with their PR/Jira reality.

It does not mutate effort lifecycle, PR, Jira, or KB state. It only writes its report and log entry. Mutating effort status or moving files to `done/` belongs to `/nase:today` (see `.claude/docs/effort-lifecycle.md`) — duplicating that here would let two skills drift apart. This skill surfaces *what* needs syncing and hands the fix to `/nase:today`.

## Step 0: Language preflight (run first)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Read `workspace/config.md`; chat-facing prose uses `conversation:` language. The report file content uses `output:` language.

<workflow>

### Step 1: Inventory

- Active: every `workspace/efforts/*.md` excluding `done/`. Read each file's YAML frontmatter (`status`, `scope`, `repo`, `jira`, `created`) and its `## Lifecycle` section if present. Capture last-updated date via `stat` mtime.
- Done: count files in `workspace/efforts/done/` (count only — don't read each).

If `workspace/efforts/` has no active files, say so and stop.

### Step 2: Classify each active effort by lifecycle stage

Reuse the canonical classifier — do not invent a parallel taxonomy. Apply `.claude/commands/nase/today.md` → **§1b-vii Path A / Path B**:
- **Path A** (file has `## Lifecycle`): last `[x]` checkbox wins → Planning / Implementing / In review / Awaiting deploy / Follow-up only.
- **Path B** (no `## Lifecycle`): fall back to frontmatter `status:` (planned→Planning, in-progress→Implementing, PR-present/in-review→In review, awaiting-deploy/merged→Awaiting deploy, anything else→Planning).

Status vocabulary lives in `.claude/docs/effort-lifecycle.md`; tolerate real-world extras (`tracked`, `blocked`, `awaiting-deploy`) by mapping them through the rules above rather than discarding them.

### Step 3: Drift check (the value-add — verify against live state)

For each active effort, extract PR URLs from the body (`github.com/([^/]+)/([^/]+)/pull/(\d+)`) and the `jira:` key. Verify current state read-only — this is where a dedicated pass beats stale frontmatter:

```bash
gh pr view <url> --json state,reviewDecision,statusCheckRollup
```

When there are more than ~5 PRs to check, fan out via the `nase-pr-metadata-reader` agent instead of serial calls. Jira: read-only status read if an MCP is available; skip cleanly if not.

Flag drift where doc and reality disagree:
- frontmatter `in-progress`/`merge-ready` but **all** its PRs are MERGED (and Jira is Done, if tracked) → **should move to `done/`**.
- any PR CLOSED-not-merged with no open/merged sibling → **should close**.
- effort with **no PR and no mtime change in 14+ days** → **stalled**, may need attention or a `/nase:design --review {slug}` pass.

Drift items are reported, never auto-applied. Recommend `/nase:today` to apply the move-to-`done/` syncs.

### Step 4: Count

- By stage (Planning / Implementing / In review / Awaiting deploy / Follow-up).
- By raw frontmatter `status:` value (shows vocabulary spread).
- Totals: active count, `done/` count, drift count, stalled count.
- If `$ARGUMENTS` has `--by-scope` or `--by-repo`, add a count grouped by that frontmatter field.

### Step 5: Write report + chat summary

Write the full report to `workspace/stats/effort-status-{YYYY-MM-DD}.md` (re-run overwrites). Structure:

```markdown
# Effort Status — {YYYY-MM-DD}

## Counts
| Stage | Count |  + by-status table, active/done/drift/stalled totals

## Drift & attention
- {effort} — {drift reason} → {recommended action}

## Active efforts          ← full per-effort table ALWAYS in the file
| Effort | Stage | Status | Last updated | Repo | PR |
```

Per `.claude/docs/skill-contract.md`, the chat reply is pointer + bounded summary only:
```
Effort status → workspace/stats/effort-status-{YYYY-MM-DD}.md
Active: {N} ({P} planning, {I} implementing, {R} in review, {D} awaiting deploy) · done/: {M}
Drift: {K} need sync (run /nase:today to apply) · Stalled: {S}
```
With `--full`, also echo the per-effort table inline (otherwise it lives only in the file).

### Step 6: Log

Append one line to `workspace/logs/{YYYY-MM-DD}.md` per `.claude/docs/daily-log-format.md`:
```
- {HH:MM} | efforts: {N} active, {K} drift flagged
```

</workflow>

## Notes

No lifecycle `--sync`/mutation flag by design. If you want finished efforts moved to `done/`, run `/nase:today`, which owns that lifecycle write.
