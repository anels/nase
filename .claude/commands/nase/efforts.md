---
name: nase:efforts
description: "Reconcile active efforts with live PR and Jira state. Use for list my efforts, effort status, sync efforts, stalled work, or what am I working on."
argument-hint: "[--by-scope|--by-repo] [--full]"
pattern: utility
category: Reporting
---

## Purpose

`/nase:today` shows a capped morning snapshot and status-syncs tracked work as a side effect. This skill answers a different question: *across all my efforts right now, where does everything stand?* - full count and inventory, plus what a stale frontmatter field cannot tell you: which docs fell out of sync with their PR/Jira reality.

Because it already does the live reads, it **applies** the deterministic transition on the spot: running it should leave the inventory correct, not just describe how to fix it. The rule is not reinvented here - both this skill and `/nase:today` call `.claude/docs/effort-lifecycle.md → Drift Auto-Sync`. It mutates effort frontmatter/location plus its report and log entry, never PR, Jira, or KB state.

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

One command does the live reads and audits the classifier's two mechanical blind spots in one pass (~15 s for 50 efforts / 90 PRs - do not fan out agents or call `gh` serially instead):

```bash
python3 .claude/scripts/effort-pr-sweep.py --check-reverts
```

It returns live state per PR (including `mergeCommit`), any **invisible** delivery PRs - cited by a checked lifecycle row but missing from `pr_references.delivery` because the row label is not canonical - and any merge commit a later **revert** commit names.

Read `.claude/docs/effort-lifecycle.md → Classifier Blind Spots` before acting on either: an invisible PR means the doc under-reports its own delivery; repair it with the canonical `PR opened` label and the effort's PR number in the body, but only for the `likely-delivery` hint. Every other hint is a legitimate exclusion, so classify rather than bulk-relabel. A revert means ancestry is lying, so confirm by grepping a symbol the PR *added* at the ring commit.

Keep delivery, report-only, and dependency PR sets separate: only the delivery set feeds the transition, and folding the other two into it is how a merely-mentioned PR turns into merge evidence. Jira: read-only status read if an MCP is available. If a tracked Jira issue cannot be read, mark its transition input `unreadable` and report the effort as unresolved.

After live reads, compute the **unblocked** flag per `.claude/docs/effort-lifecycle.md → Dependency & Discovery Fields`:
- Blocked when `status: blocked` **or** `blocked-by` points at an unresolved referent.
- Resolve effort-slug blockers when `workspace/efforts/done/{slug}.md` or `workspace/efforts/archive/*/{slug}.md` exists; PR blockers when merged; Jira blockers when Done.
- Treat free-text blockers and unreadable PR/Jira blockers as unresolved. Name the skipped check in the blocked reason. A `blocked-by` that literally reads `none`/`n/a` is free text and reports as blocked - call it out as a doc defect and recommend deleting the key rather than silently treating it as unblocked.
- Everything else active is *unblocked*. This is the "what can I actually pick up right now" set; it sits beside the stage classifier and does not replace it.

Pass the live delivery PR states, Jira state, and unresolved-blocker flag to the `effort-state.py` command in `.claude/docs/effort-lifecycle.md -> Drift Auto-Sync`. Apply its `transition` output exactly - `transition.status`, `transition.destination_dir` on `action: move` (never assume `done/`), and `transition.stale_canonical_rows`. Stage the frontmatter change and the checkbox flips as one proposed file so one guarded `apply` / `apply-move` covers both, no per-item prompt, matching `/nase:today` Step 1.

An `action: none` transition can still carry `stale_canonical_rows`: `reason: already-awaiting-deploy` means the frontmatter is right and only the row lags. Apply the flips there too, otherwise the drift survives every run.

Record each transition and each row flip applied for the Step 5 report. Report-only signals (no mutation):
- effort with **no PR and no mtime change in 14+ days** → **stalled**, may need attention or a `/nase:design --review {slug}` pass.
- **doc drift the helper cannot fix.** These need a human because the repair is not derivable from live state, so name the exact line and the suggested edit instead of just flagging the effort:
  - `needs_live_verification` still true after the live reads and no `stale_canonical_rows` offered - the checked lifecycle rows and frontmatter disagree for a reason the PR states did not settle.
  - `method: frontmatter` on a doc that has a `## Lifecycle` heading - the section is prose with no canonical checkbox, so it carries no evidence. It never raises `needs_live_verification` (that flag needs evidence to contradict), so it has to be reported on its own: the classifier degrades to the frontmatter fallback silently.
  - non-empty `pr_references.validation_errors`, surfacing as transition `reason: invalid-pr-reference` and blocking every write for that effort. Name the offending key and its repair per `.claude/docs/effort-lifecycle.md → PR Reference Resolution`; never report the effort as having no delivery PR - the helper never got to read one.
  - non-empty `pr_references.discarded_bare`, except `reason: denied-in-row` - that one means the row itself says the number is not a PR, so the classifier is right and there is nothing to repair. For `no-repo-context` use `owner/repo#n` or add `repo:`; for `outside-lifecycle` move the row under a `## Lifecycle` heading or qualify the number.
  - an **invisible delivery PR** hinted `likely-delivery` by the sweep - name the line, the PR and the canonical-label repair.
  - real outstanding work that lives only in the Implementation Plan. The hold scans `## Lifecycle` only, so such an effort auto-closes the moment its last Lifecycle row is ticked; the repair is to promote that deliverable to a Lifecycle row.
  - a `blocked-by` whose value reads `none`/`n/a`, per the unblocked rules above.
- transition `reason: undelivered-lifecycle-rows` → **held back**. Report each `transition.undelivered` row verbatim with its line number: a real outstanding PR means the effort correctly stayed active, a stale plan row means edit that row (`.claude/docs/effort-lifecycle.md → Multi-Deliverable Efforts`). Never paraphrase them away - an unexplained hold reads as a bug and gets worked around.

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

Only the documented Drift Auto-Sync transition auto-writes - frontmatter `status:`, the terminal move, and the `Merged` rows `transition.stale_canonical_rows` names. `/nase:today` applies the same rule, so running either keeps the inventory in sync. Everything else is reported line by line for a human, because a repair inferred from prose is what this skill must not guess at unsupervised.

Effort docs get edited by other sessions while this runs. Use exact-string edits for row repairs rather than staging a whole file, re-`stat` before any guarded write, and if the active count moved mid-run, say so in the report instead of publishing a count that was true at Step 1.

Before calling any effort complete, read the full text of its unchecked rows - `.claude/docs/effort-lifecycle.md → Classifier Blind Spots` explains why `pending_followups: 0` is not evidence.
