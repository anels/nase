---
name: nase:kb-review
description: "Audit KB and workspace hygiene, apply repairs. Use for review KB, curate KB, stale data, or clean up KB. Missing topics: the user runs --gaps."
argument-hint: "[workspace/path] [--kb-only] [--report-only|--repair] | --gaps [flags]"
category: Knowledge base
model: sonnet
effort: medium
---
Audit the KB and the workspace mechanisms that keep it trustworthy, apply the repairs whose correct value is already decided, and gate the rest. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/skill-contract.md` and `.claude/docs/workspace-write-guard.md`.
Content rules: kb-lifecycle-layers.md. This file owns scope, scanning, repair authority, and the report.

**Gap mode.** `--gaps [--days N] [--since D] [--until D] [--min-recurrence N] [--repo NAME] [--auto] [--verbose]` finds *missing* KB topics instead of stale ones. It runs only when the user explicitly asks for it, never from model routing or another command. Follow `.claude/docs/kb-gap-detect.md` and skip every section below.

## Scope and mode

1. Default to the full `workspace/` health review. A path argument narrows the content review, but full-scope trust checks still cover credentials, task and effort indexes, backup metadata, and the writers that can corrupt durable state. Reject paths outside the repository.
   - `--kb-only` is the fast path. Restrict content, structure, relationship, searchability, and writer-contract checks to `workspace/kb/` plus the scripts/docs/skills that read or write it. Run `python3 .claude/scripts/kb-usage-report.py` and cite its consumer-unread count (`Mapped KB files never read by a consumer`), not the plain unread and unobserved lines, which count maintenance reads as use and read 0. Follow `.claude/docs/kb-hygiene.md → Write budget and size review` and its report summary. Skip unrelated task, effort, backup, restore, and journal lifecycle checks. The full ignored-workspace credential scan remains mandatory because credential safety is not scope-limited.
2. Run in one of three modes.

   | Invocation | Behavior |
   |---|---|
   | no flag (default), reported as `mode: auto` | Scan, apply every *decided* repair from `## Repair classes`, write the report. |
   | `--report-only` | Zero writes. Report only. |
   | `--repair` | Adds one late approval checkpoint that also covers judgment-bearing rewrites. |

   Mode MUST NOT narrow discovery. A narrower mode changes what gets written, never what gets looked at.
3. `workspace/` is git-ignored, so the undo path is the backup, not git. Read the newest good backup before the first write and record its name and timestamp in the report frontmatter and chat summary. A backup older than a deletion target's mtime does not cover that target, so that deletion drops to judgment-bearing. The `workspace/tmp/` prune is exempt because no backup ever covers it (see `## Repair classes`). The degrade is per target: a stale backup demotes only the deletions it fails to cover, while **no** backup degrades the whole run to `--report-only`. Say which happened.
4. For broad reviews, dispatch read-only `nase-context-kb-researcher` slices for disjoint KB domains. The main thread owns KB edits and report writes, security triage, state reconciliation, and every mutation.
5. When the reviewed root must remain untouched, store machine-readable before and after SHA-256 manifests outside that root and require them to match.

## Deterministic preflight

Capture results under `workspace/tmp/`; never paste full scanner output into chat.

1. Run `python3 .claude/scripts/workspace-quality-scan.py --root . --days 30 --json` and parse every finding. A zero exit from `.claude/scripts/validate-workspace.sh` is wiring evidence, not proof of health.
2. Run `python3 .claude/scripts/kb-hygiene-scan.py --workspace-scan --root . --json`, then scan each in-scope project KB against its repository `HEAD` where the repo is available. Record the helper path and explicit root override used.
3. Run `bash tests/check-local-sensitive-artifacts.sh --workspace`. This full ignored-workspace pass reports only path, line, and secret kind. Classify a match only through bounded local inspection whose output is redacted before it reaches a tool result, report, or chat. Never quote, copy, diff, or store the matched value.
4. Take the counts in `.claude/docs/kb-lifecycle-layers.md → Over-breadth needs a count`. It is not a judgment call.
5. Run `bash .claude/scripts/validate-workspace.sh` plus the focused tests for whatever the scans flagged, typically `bash tests/check-effort-pointer-integrity.sh`. Record each command, its exit status, and the shortest decisive output.

## Deep review

Work `.claude/docs/kb-review-deep-scan.md` top to bottom. It carries the content-and-relationship
inventory, the security-and-propagation triage, the authoritative-state checks, and the operational
contract checks, each with the shared doc it applies. Discovery is mode-independent: run every check
there even under `--report-only`.

Two of its checks are non-negotiable and stated here so they cannot be lost in a pointer. Verify every
documented command from its exact documented working directory in a fixture or dry-run before reporting
it as working; reading it is not evidence it runs. And when exercising the backup writer against
unchanged content, changed content inside one timestamp granularity, and concurrent runs,
archive names must be collision-safe, because a collision silently replaces the undo path this command
depends on.

## Repair classes

Classify the class yourself by the four definitions below. A credential or an out-of-`workspace/` path is never sent to an external classifier.

### Decided - apply without asking

Every condition holds, or the repair drops to the next class. Target inside `workspace/`, correct value fixed by a scanner finding plus your own re-read of the source, no credential involved, backup from `## Scope and mode` step 3 named. It writes under the default mode and under `--repair` (which only *adds* a checkpoint for the judgment-bearing class); `--report-only` lists each qualifying item as a finding.

- Broken link whose new target is verified to exist.
- Domain-map gap, meaning an entry pointing at a missing file. Remove it, or repoint it to a verified path.
- Orphan file with no domain-map entry. Add the entry; adding is not deleting.
- Effort frontmatter status outside `Status Vocabulary` whose correct value follows from file location plus live state.
- Anything `check-effort-pointer-integrity.sh` names, repaired the way it names.
- Missing or drifted `last-updated:` where the correct date is derivable.
- A status claim that verification resolved. Write the measured value.
- `**Confidence:** high` (or `**Confidence**: high`) stripped, with any parenthetical evidence moved into the entry's `Verified:` line per `.claude/docs/kb-lifecycle-layers.md`.
- Layer mixing whose correct destination is unambiguous, including a dated gotcha promotion whose re-verification passed. A promotion replaces the dated block's gotcha text with a one-line `Promoted -> ...` pointer; it is an edit, not a deletion, and does not count toward the deletion disclosure below.
- Accretion blocks per `.claude/docs/kb-staleness.md → Step D2`.
- Stale `workspace/tmp/` entries, pruned by `python3 .claude/scripts/tmp-prune.py --apply --manifest workspace/tmp/tmp-prune-{YYYY-MM-DD}.tsv` as the last write of the run. The script's docstring owns which entries it deletes. Under `--report-only`, run `python3 .claude/scripts/tmp-prune.py --json` with no `--manifest` and report `targets`. Skip it under `--kb-only`, when a narrowed `[workspace/path]` excludes `workspace/tmp/`, and when the reviewed root must stay untouched.

Deletion is in this class because the backup is the undo path. **Every deleted path MUST be listed individually in the report and the chat summary, with its line count and its restore route.** An aggregate count is not a disclosure. The one exception is the `workspace/tmp/` prune. Backups exclude `workspace/tmp/`, so it has no undo path; it is decided only because the script deletes nothing that is recent or referenced. Its manifest lists every deleted path with its size, so the report links it with the count and bytes, and chat gives the count and manifest path.

### Judgment-bearing - one late checkpoint

This class covers merging two entries, rewriting wording, dropping a low-signal platitude, promoting a lesson, and any ADR-layer edit. Present exact local targets and compact diff summaries in a single checkpoint. The default mode reports these; `--repair` covers them.

### Separately gated - named approval each

External publication, credential rotation or removal, backup pruning, and any write outside `workspace/` each need their own approval naming the exact target and payload. These MUST NOT ride along in the local batch. Versioned helper fixes go through the repository branch or worktree workflow with the smallest fixture-based regression test that reproduces the failure; an exact code proposal is not repair-ready until that test executes successfully in a disposable copy.

### Never automatic

- A repair where the scanner's classification and your own re-read of the source disagree. Missing or conflicting evidence stays a finding, not a rewrite.
- Anything resting on an `unverified` claim.
- Anything whose correct value you would have to choose rather than read.

Apply every approved durable workspace change through `workspace-write-guard.py` (mtime, source hash, staged hash checks).

## Report contract

Write `workspace/recaps/kb-review-{YYYY-MM-DD}.md`. Redact values before drafting. The report opens with this frontmatter.

```yaml
---
last_curated: YYYY-MM-DD
mode: auto | report-only | repair
backup_relied_on: "<archive name or timestamp>"
coverage:
  reviewed: "<path:line-range>, ..."
  unreviewed: "<path:line-range>, ..."
counts: { applied: N, deleted: N, checkpointed: N, gated: N, unverified: N, open: N }
net_lines: <signed integer across curated content files>
known_stale:
  - "<claim> - unverified as of YYYY-MM-DD"
---
```

Body carries, per finding, severity, evidence path and line, impact, root cause, layer, repair class, verification, and status.

`coverage` keeps batching honest. Review a file over roughly 600 lines in ranges and record each range. **MUST NOT report a file as reviewed when only part of it was read.** A non-empty `coverage.unreviewed` is where the next run starts: read the prior report's frontmatter and resume from those ranges, unless the file's mtime moved since, which forces a full re-read.

## Verification and output

Before marking an applied repair or an exact proposal repair-ready, re-run every deterministic preflight command and focused regression test against the modified target or disposable copy. A green re-run does not close a finding that is still open.

The complete report is the canonical artifact. Chat returns its path and at most five lines carrying the highest-severity findings, the backup relied on, every deleted path (the tmp prune as count plus manifest path), and the approval boundary.

After the report, unless `--report-only`, run `python3 .claude/scripts/maintenance-schedule.py done kb-review`.

### Next-step prompt

When `counts` shows any `checkpointed`, `gated`, or `open` finding, end with one batched `AskUserQuestion` (skill-contract rule 4). Skip it under `--report-only` or when all three are 0. Explain each option first (IDs, files, class). Options: apply the judgment batch (default mode only, `--repair` already asked), apply a subset, start a gated fix via the branch flow, or later. No option approves a gated item, and "later" writes nothing.

Preserve provenance, project boundaries, and confidential markers.

## Unvalidated rules

The 600-line batching threshold is a round number, not a measurement. The rest sit in the shared doc's own `Unvalidated rules`.
