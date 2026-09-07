---
name: nase:efforts
description: "Reconcile active efforts with live PR and Jira state. Use for list my efforts, effort status, sync efforts, stalled work, or what am I working on."
argument-hint: "[--by-scope|--by-repo] [--full] [--closed]"
category: Reporting
---

## Purpose

`/nase:today` shows a capped morning snapshot and status-syncs tracked work as a side effect. This skill answers a different question: *across all my efforts right now, where does everything stand?* - full count and inventory, plus what a stale frontmatter field cannot tell you: which docs fell out of sync with their PR/Jira reality.

Because it already does the live reads, it **applies** the deterministic repairs on the spot: running it should leave the inventory correct, not just describe how to fix it. The rules are not reinvented here - both this skill and `/nase:today` call `.claude/docs/effort-lifecycle.md`. It mutates effort docs and its own report and log entry, never PR, Jira, or KB state.

## Step 0: Language preflight (run first)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Read `workspace/config.md`; chat-facing prose uses `conversation:` language. The report file content uses `output:` language.

## Mode routing

`--closed` audits terminal docs in `done/` and `archive/*/` instead of active efforts: follow `.claude/docs/effort-doc-audit.md → Part 2` and skip the workflow below. Nothing else re-reads those docs, so a wrong record there survives indefinitely - and because `/nase:effort-rollup` drops `status: wontfix` from the delivery record, an effort whose code shipped but whose verdict was dropped takes its merged PRs out of the impact report with it. Run it on the `/nase:kb-review` cadence rather than every session; the default run stays active-only and fast.

Every other flag runs the workflow below.

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

Read `.claude/docs/effort-lifecycle.md → Classifier Blind Spots` before acting on either. **Repair every `likely-delivery` hint in place, without asking**: canonical `PR opened` label keeping the row's own PR number, fix the prose that merge falsified (delivery notes still reading "all five are open"), re-run `effort-state.py`, apply the transition it returns. The sweep already classified it; handing it back as a question parks a known-wrong doc. Every other hint is a legitimate exclusion - classify, do not bulk-relabel. A revert means ancestry is lying: grep a symbol the PR *added* at the ring commit.

Keep delivery, report-only, and dependency PR sets separate: only the delivery set feeds the transition, and folding the other two into it is how a merely-mentioned PR turns into merge evidence. Jira: read-only status read if an MCP is available. If a tracked Jira issue cannot be read, mark its transition input `unreadable` and report the effort as unresolved.

After live reads, compute the **unblocked** flag per `.claude/docs/effort-lifecycle.md → Dependency & Discovery Fields`, which owns the resolver rules and the computed-view definition. Name the skipped check in the blocked reason when a PR or Jira blocker could not be read. This set answers "what can I actually pick up right now"; it sits beside the stage classifier and does not replace it.

Pass the live delivery PR states, Jira state, and unresolved-blocker flag to the `effort-state.py` command in `.claude/docs/effort-lifecycle.md -> Drift Auto-Sync`. Apply its `transition` output exactly - `transition.status`, `transition.destination_dir` on `action: move` (never assume `done/`), and `transition.stale_canonical_rows`. Stage the frontmatter change and the checkbox flips as one proposed file so one guarded `apply` / `apply-move` covers both, no per-item prompt, matching `/nase:today` Step 1.

An `action: none` transition can still carry `stale_canonical_rows`: `reason: already-awaiting-deploy` means the frontmatter is right and only the row lags. Apply the flips there too, otherwise the drift survives every run.

Record each transition and each row flip applied for the Step 5 report. Report-only signals (no mutation):
- effort with **no PR and no mtime change in 14+ days** → **stalled**, may need attention or a `/nase:design --review {slug}` pass.
- **doc drift**, split into repair-without-asking and report-for-a-human by `.claude/docs/effort-doc-audit.md → Part 1`. Apply that split rather than re-deriving it; name the exact line and the suggested edit for everything it routes to a human, and check the sweep's `delivery_owners` before repairing any invisible PR - a `sibling-delivery` hint means another effort's delivery set already claims it.
- **structural defects** from `effort-state.py`'s `structure` block, per the same doc. These never raise `needs_live_verification`, so nothing else surfaces them.
- transition `reason: undelivered-lifecycle-rows` → **held back**. Report each `transition.undelivered` row verbatim with its line number: a real outstanding PR means the effort correctly stayed active, a stale plan row means edit that row (`.claude/docs/effort-lifecycle.md → Multi-Deliverable Efforts`). Never paraphrase them away - an unexplained hold reads as a bug and gets worked around.

### Step 4: Count

Count **after** the Step 3 transitions so active/`done/` totals reflect post-sync reality.

- By stage (Planning / Implementing / In review / Awaiting deploy / Follow-up).
- By raw frontmatter `status:` value (shows vocabulary spread).
- Unblocked vs blocked (from Step 3): count of unblocked active efforts and the list of blocked ones with their blocker.
- Totals: active, `done/`, `archive/*/`, plus this run's transitioned, Lifecycle rows ticked, PRs relabelled, held-back, stalled and doc-drift counts.
- If `$ARGUMENTS` has `--by-scope` or `--by-repo`, add a count grouped by that frontmatter field.

### Step 5: Write report + chat summary

Write the full report to `workspace/stats/effort-status-{YYYY-MM-DD}.md` (re-run overwrites). Structure:

```markdown
# Effort Status — {YYYY-MM-DD}

## Counts
| Stage | Count |  + by-status table, active/done/archive/transitioned/stalled totals

## Transitioned this run   ← omit section if none
- {effort} - {evidence} -> status: {awaiting-deploy|completed|wontfix}{; moved to {destination_dir} if terminal}{; ticked L{line} `Merged`}

## Invisible PRs relabelled   ← omit section if none
- {effort} - L{line}: `{old label}` -> `PR opened` for {owner/repo#n} ({live state}){; prose fixed}{; transition fired}

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
Unblocked: {U} · Blocked: {B} · Transitions: {K} applied · Rows ticked: {T} · PRs relabelled: {L} · Held back: {H} · Stalled: {S} · Doc drift: {X}
```
With `--full`, also echo the per-effort table inline (otherwise it lives only in the file).

### Step 6: Log

Append one line to `workspace/logs/{YYYY-MM-DD}.md` per `.claude/docs/daily-log-format.md`:
```
- {HH:MM} | efforts: {N} active, {K} transitions applied, {T} Lifecycle rows ticked, {L} invisible PRs relabelled, {H} held back, {X} doc drift
```

</workflow>

## Notes

Two things auto-write: the Drift Auto-Sync transition (`/nase:today` applies the same rule) and the `likely-delivery` relabel. Everything else is reported for a human. The dividing line is not how risky the edit is but **whether the live reads determined the repair or someone still has to decide what the row means** - guessing the second kind from prose is what this skill must not do unsupervised.

Effort docs get edited by other sessions while this runs. Use exact-string edits for row repairs rather than staging a whole file, re-`stat` before any guarded write, and if the active count moved mid-run, say so in the report instead of publishing a count that was true at Step 1.

Before calling any effort complete, read the full text of its unchecked rows - `.claude/docs/effort-lifecycle.md → Classifier Blind Spots` explains why `pending_followups: 0` is not evidence.
