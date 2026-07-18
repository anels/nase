---
name: nase:efforts
description: "Reconcile active efforts with live PR and Jira state. Use for list my efforts, effort status, sync efforts, stalled work, or what am I working on."
argument-hint: "[--by-scope|--by-repo] [--full]"
pattern: utility
category: Reporting
---

## Purpose

`/nase:today` shows a capped morning snapshot and status-syncs tracked work as a side effect. This skill answers a different question: *across all my efforts right now, where does everything stand?* — a full count and inventory, plus the one thing a stale frontmatter field can't tell you: which docs have fallen out of sync with their PR/Jira reality.

Because it already does the live PR/Jira reads to compute drift, it also **applies** the deterministic lifecycle transition on the spot rather than deferring to `/nase:today`: running `/nase:efforts` should leave the inventory correct, not just describe how to fix it. The transition itself is not reinvented here: both this skill and `/nase:today` call the single rule in `.claude/docs/effort-lifecycle.md → Drift Auto-Sync`. It does not mutate PR, Jira, or KB state, only effort frontmatter/location plus its report and log entry.

## Step 0: Language preflight (run first)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Read `workspace/config.md`; chat-facing prose uses `conversation:` language. The report file content uses `output:` language.

<workflow>

### Step 1: Inventory

- Active: every `workspace/efforts/*.md` excluding `done/`. Read each file's YAML frontmatter (`status`, `scope`, `repo`, `jira`, `created`, and — if present — `blocked-by`, `discovered-from`) and its `## Lifecycle` section if present. Capture last-updated date via `stat` mtime.
- Done: count files in `workspace/efforts/done/` (count only — don't read each).

If `workspace/efforts/` has no active files, say so and stop.

### Step 2: Classify each active effort by lifecycle stage

Reuse the canonical classifier - do not invent a parallel taxonomy:

```bash
python3 .claude/scripts/effort-state.py --file "workspace/efforts/<slug>.md"
```

Use its `stage`, `evidence`, `pending_followups`, and `needs_live_verification` fields. If `needs_live_verification` is true, keep the lifecycle result visible and resolve the conflict through the Step 3 live PR/Jira reads.

Status vocabulary lives in `.claude/docs/effort-lifecycle.md`; tolerate real-world extras (`tracked`, `blocked`, `awaiting-deploy`) by mapping them through the rules above rather than discarding them.

Also capture any `blocked-by` values. Do not finalize the **unblocked** flag yet: effort-slug blockers can be resolved from `done/` locally, but PR/Jira blockers need the Step 3 live reads.

### Step 3: Drift check (the value-add — verify against live state)

For each active effort, extract structured delivery PR references per `.claude/docs/effort-lifecycle.md → Drift Auto-Sync`, other report-only PR references per `PR Reference Resolution`, dependency PRs from `blocked-by`, and the `jira:` key. Keep delivery, report-only, and dependency PR sets separate, normalize/dedupe each, then verify each unique PR/Jira referent read-only — this is where a dedicated pass beats stale frontmatter:

```bash
gh pr view <n> --repo <owner>/<repo> --json state,reviewDecision,statusCheckRollup,mergedAt
```

When there are more than ~5 PRs to check, fan out via the `nase-pr-metadata-reader` agent instead of serial calls. Jira: read-only status read if an MCP is available. If a tracked Jira issue cannot be read, mark its transition input `unreadable` and report the effort as unresolved.

After live reads, compute the **unblocked** flag per `.claude/docs/effort-lifecycle.md → Dependency & Discovery Fields`:
- Blocked when `status: blocked` **or** `blocked-by` points at an unresolved referent.
- Resolve effort-slug blockers when `workspace/efforts/done/{slug}.md` exists; PR blockers when merged; Jira blockers when Done.
- Treat free-text blockers and unreadable PR/Jira blockers as unresolved. Name the skipped check in the blocked reason.
- Everything else active is *unblocked*. This is the "what can I actually pick up right now" set; it sits beside the stage classifier and does not replace it.

Pass the live delivery PR states, Jira state, and unresolved-blocker flag to the `effort-state.py` command in `.claude/docs/effort-lifecycle.md → Drift Auto-Sync`. Apply its `transition` output exactly. This documented auto-write uses the workspace write guard's normal `apply` or collision-safe `apply-move` path with no per-item human prompt, matching `/nase:today` 1b-v.

Record each transition applied for the Step 5 report. Report-only signals (no mutation):
- effort with **no PR and no mtime change in 14+ days** → **stalled**, may need attention or a `/nase:design --review {slug}` pass.

### Step 4: Count

Count **after** the Step 3 transitions so active/`done/` totals reflect post-sync reality.

- By stage (Planning / Implementing / In review / Awaiting deploy / Follow-up).
- By raw frontmatter `status:` value (shows vocabulary spread).
- Unblocked vs blocked (from Step 3): count of unblocked active efforts and the list of blocked ones with their blocker.
- Totals: active count, `done/` count, transitioned-this-run count, stalled count.
- If `$ARGUMENTS` has `--by-scope` or `--by-repo`, add a count grouped by that frontmatter field.

### Step 5: Write report + chat summary

Write the full report to `workspace/stats/effort-status-{YYYY-MM-DD}.md` (re-run overwrites). Structure:

```markdown
# Effort Status — {YYYY-MM-DD}

## Counts
| Stage | Count |  + by-status table, active/done/transitioned/stalled totals

## Transitioned this run   ← omit section if none
- {effort} — {evidence} → status: {awaiting-deploy|completed|wontfix}{; moved to done/ if terminal}

## Attention
- {effort} — {stalled, awaiting-deploy, or unresolved-read reason} → {recommended action}

## Blocked            ← omit section if none
- {effort} — blocked-by {referent} ({unresolved reason})

## Active efforts          ← full per-effort table ALWAYS in the file
| Effort | Stage | Status | Blocked-by | Last updated | Repo | PR |
```

Per `.claude/docs/skill-contract.md`, the chat reply is pointer + bounded summary only:
```
Effort status → workspace/stats/effort-status-{YYYY-MM-DD}.md
Active: {N} ({P} planning, {I} implementing, {R} in review, {D} awaiting deploy) · done/: {M}
Unblocked: {U} · Blocked: {B} · Transitions: {K} applied · Stalled: {S}
```
With `--full`, also echo the per-effort table inline (otherwise it lives only in the file).

### Step 6: Log

Append one line to `workspace/logs/{YYYY-MM-DD}.md` per `.claude/docs/daily-log-format.md`:
```
- {HH:MM} | efforts: {N} active, {K} transitions applied
```

</workflow>

## Notes

The move-to-`done/` transition is shared with `/nase:today` via `.claude/docs/effort-lifecycle.md → Drift Auto-Sync`: both apply the same deterministic rule, so running either keeps the effort inventory in sync. Only that documented transition auto-writes; stalled and `awaiting-deploy` efforts are reported, never auto-moved.
