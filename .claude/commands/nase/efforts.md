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

- Active: every `workspace/efforts/*.md` excluding `done/` and `archive/`. Read each file's YAML frontmatter (`status`, `scope`, `repo`, `jira`, `created`, and, if present, `blocked-by`, `discovered-from`, `tracking_only`) and its `## Lifecycle` section if present. Capture last-updated date via `stat` mtime.
- Done: count files in `workspace/efforts/done/` (count only — don't read each).
- Archived: count files under `workspace/efforts/archive/*/` (count only). Terminal tracking-only efforts land here instead of `done/` per `.claude/docs/effort-lifecycle.md → Terminal Destination`, so reporting `done/` alone understates what closed.

If `workspace/efforts/` has no active files, say so and stop.

### Step 2: Classify each active effort by lifecycle stage

Reuse the canonical classifier - do not invent a parallel taxonomy:

```bash
python3 .claude/scripts/effort-state.py --file "workspace/efforts/<slug>.md"
```

Use its `stage`, `evidence`, `pending_followups`, and `needs_live_verification` fields. If `needs_live_verification` is true, keep the lifecycle result visible and resolve the conflict through the Step 3 live PR/Jira reads.

Status vocabulary lives in `.claude/docs/effort-lifecycle.md`; tolerate real-world extras (`tracked`, `blocked`, `awaiting-deploy`) by mapping them through the rules above rather than discarding them.

Also capture any `blocked-by` values. Do not finalize the **unblocked** flag yet: effort-slug blockers can be resolved locally from `done/` or `archive/*/`, but PR/Jira blockers need the Step 3 live reads.

### Step 3: Drift check (the value-add — verify against live state)

Take the delivery and dependency PR sets from the Step 2 classifier's `pr_references` field rather than re-deriving them with your own regexes - `.claude/docs/effort-lifecycle.md → PR Reference Resolution` owns the rules, including which bare and shorthand `#{n}` a row disclaims. Collect report-only body references yourself if the report needs them, and the `jira:` key. Keep delivery, report-only, and dependency PR sets separate: only the delivery set feeds the transition, and folding the other two into it is how a merely-mentioned PR turns into merge evidence. Then verify each unique PR/Jira referent read-only - this is where a dedicated pass beats stale frontmatter:

```bash
gh pr view <n> --repo <owner>/<repo> --json state,reviewDecision,statusCheckRollup,mergedAt
```

When there are more than ~5 PRs to check, fan out via the `nase-pr-metadata-reader` agent instead of serial calls. Jira: read-only status read if an MCP is available. If a tracked Jira issue cannot be read, mark its transition input `unreadable` and report the effort as unresolved.

After live reads, compute the **unblocked** flag per `.claude/docs/effort-lifecycle.md → Dependency & Discovery Fields`:
- Blocked when `status: blocked` **or** `blocked-by` points at an unresolved referent.
- Resolve effort-slug blockers when `workspace/efforts/done/{slug}.md` or `workspace/efforts/archive/*/{slug}.md` exists; PR blockers when merged; Jira blockers when Done.
- Treat free-text blockers and unreadable PR/Jira blockers as unresolved. Name the skipped check in the blocked reason. A `blocked-by` that literally reads `none`/`n/a` is free text and reports as blocked - call it out as a doc defect and recommend deleting the key rather than silently treating it as unblocked.
- Everything else active is *unblocked*. This is the "what can I actually pick up right now" set; it sits beside the stage classifier and does not replace it.

Pass the live delivery PR states, Jira state, and unresolved-blocker flag to the `effort-state.py` command in `.claude/docs/effort-lifecycle.md -> Drift Auto-Sync`. Apply its `transition` output exactly - `transition.status`, `transition.destination_dir` on `action: move` (do not assume `done/`), and `transition.stale_canonical_rows`, the unchecked `Merged` rows the live reads just proved merged. Stage the frontmatter change and the checkbox flips as one proposed file so a single guarded write covers both. This documented auto-write uses the workspace write guard's normal `apply` or collision-safe `apply-move` path with no per-item human prompt, matching `/nase:today` Step 1 (Live status sync).

An `action: none` transition can still carry `stale_canonical_rows`: `reason: already-awaiting-deploy` means the frontmatter is right and only the row lags. Apply the flips there too, otherwise the drift survives every run.

Record each transition and each row flip applied for the Step 5 report. Report-only signals (no mutation):
- effort with **no PR and no mtime change in 14+ days** → **stalled**, may need attention or a `/nase:design --review {slug}` pass.
- **doc drift the helper cannot fix.** These need a human because the repair is not derivable from live state, so name the exact line and the suggested edit instead of just flagging the effort:
  - `needs_live_verification` still true after the live reads and no `stale_canonical_rows` offered - the checked lifecycle rows and frontmatter disagree for a reason the PR states did not settle.
  - `method: frontmatter` on a doc that has a `## Lifecycle` heading - the section is prose with no canonical checkbox, so it carries no evidence at all. This one never raises `needs_live_verification` (that flag needs evidence to contradict), which is exactly why it has to be reported on its own: the classifier degrades to the frontmatter fallback silently.
  - non-empty `pr_references.validation_errors`, which surfaces as transition `reason: invalid-pr-reference` and blocks every write for that effort. Name the offending key and its repair per `.claude/docs/effort-lifecycle.md → PR Reference Resolution`; do not report the effort as having no delivery PR, because the helper never got to read one.
  - non-empty `pr_references.discarded_bare` - branch on `reason`: for `denied-in-row`,
    reword query/finding numbers without `#`; for `no-repo-context`, use
    `owner/repo#n` or add `repo: owner/repo`; for `outside-lifecycle`, put the row under
    a `## Lifecycle` heading or qualify the number. Report the line and reason rather than
    treating a real but unqualified PR as a non-PR reference.
  - a `blocked-by` whose value reads `none`/`n/a`, per the unblocked rules above.
- transition `reason: undelivered-lifecycle-rows` → **held back**. No delivery PR remains open, but the doc still owes deliverables. Report each `transition.undelivered` row verbatim with its line number so the reader can act on it directly: if the row is a real outstanding PR the effort correctly stayed active, and if it is a stale plan row or something nobody ticked, the fix is to edit that row (see `.claude/docs/effort-lifecycle.md → Multi-Deliverable Efforts`). Do not paraphrase the rows away - an unexplained hold looks like a bug and gets worked around.

### Step 4: Count

Count **after** the Step 3 transitions so active/`done/` totals reflect post-sync reality.

- By stage (Planning / Implementing / In review / Awaiting deploy / Follow-up).
- By raw frontmatter `status:` value (shows vocabulary spread).
- Unblocked vs blocked (from Step 3): count of unblocked active efforts and the list of blocked ones with their blocker.
- Totals: active count, `done/` count, `archive/*/` count, transitioned-this-run count, Lifecycle rows ticked this run, held-back count, stalled count, doc-drift count.
- If `$ARGUMENTS` has `--by-scope` or `--by-repo`, add a count grouped by that frontmatter field.

### Step 5: Write report + chat summary

Write the full report to `workspace/stats/effort-status-{YYYY-MM-DD}.md` (re-run overwrites). Structure:

```markdown
# Effort Status — {YYYY-MM-DD}

## Counts
| Stage | Count |  + by-status table, active/done/archive/transitioned/stalled totals

## Transitioned this run   ← omit section if none
- {effort} - {evidence} -> status: {awaiting-deploy|completed|wontfix}{; moved to {destination_dir} if terminal}{; ticked L{line} `Merged`}

## Held back - no open delivery PR, but deliverables still owed   ← omit section if none
- {effort} — stays `{status}`; {N} unchecked Lifecycle row(s):
  - L{line}: {row text}

## Doc drift - needs a human edit   ← omit section if none
- {effort} - L{line}: {what is wrong} → {the edit to make}

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
Active: {N} ({P} planning, {I} implementing, {R} in review, {D} awaiting deploy) · done/: {M} · archive/: {A}
Unblocked: {U} · Blocked: {B} · Transitions: {K} applied · Rows ticked: {T} · Held back: {H} · Stalled: {S} · Doc drift: {X}
```
With `--full`, also echo the per-effort table inline (otherwise it lives only in the file).

### Step 6: Log

Append one line to `workspace/logs/{YYYY-MM-DD}.md` per `.claude/docs/daily-log-format.md`:
```
- {HH:MM} | efforts: {N} active, {K} transitions applied, {T} Lifecycle rows ticked, {H} held back, {X} doc drift
```

</workflow>

## Notes

The terminal move is shared with `/nase:today` via `.claude/docs/effort-lifecycle.md -> Drift Auto-Sync`: both apply the same deterministic destination rule, so running either keeps the effort inventory in sync. Only that documented transition auto-writes - its frontmatter `status:`, its terminal move, and the `Merged` rows `transition.stale_canonical_rows` names. Everything else is reported: stalled and `awaiting-deploy` efforts are never auto-moved, and doc drift the live reads cannot settle (prose-only `## Lifecycle` sections, rows citing non-PR `#{n}`) is named line by line for a human, because a repair that has to be inferred from prose is exactly what this skill should not be guessing at unsupervised.
