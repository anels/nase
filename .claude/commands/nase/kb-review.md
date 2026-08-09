---
name: nase:kb-review
description: "Audit and repair KB plus workspace state for stale data, broken references, credential exposure, unsafe backup or restore behavior, and lifecycle drift. Use for review KB, workspace hygiene, clean up KB, or periodic health checks."
argument-hint: "[workspace/path] [--kb-only] [--report-only|--repair]"
pattern: pipeline
category: Knowledge base
sub-patterns: [fan-out]
---

Audit the KB and the workspace mechanisms that keep it trustworthy, then apply only approved changes. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/skill-contract.md` and `.claude/docs/workspace-write-guard.md`.

## Scope and mode

1. Default to the full `workspace/` health review. A path argument narrows the content review, but full-scope trust checks still cover credentials, task and effort indexes, backup metadata, and the writers that can corrupt durable state. Reject paths outside the repository.
   - `--kb-only` is the fast maintenance path. Restrict content, structure, relationship, searchability, usage, and writer-contract checks to `workspace/kb/` plus the scripts/docs/skills that read or write it. Skip unrelated task, effort, backup, restore, and journal lifecycle checks. The full ignored-workspace credential scan remains mandatory because credential safety is not scope-limited. Default behavior remains the full review.
2. Default to `--report-only`. `--repair` prepares exact patches after discovery, but still uses the approval boundaries below. Do not let repair mode narrow discovery.
3. For broad reviews, dispatch read-only `nase-context-kb-researcher` slices for disjoint KB domains. The main thread owns KB edits and report writes, security triage, state reconciliation, and every mutation.
4. When the reviewed root must remain untouched, store machine-readable before and after SHA-256 manifests outside that root and require them to match.

## Deterministic preflight

Capture results under `workspace/tmp/`; never paste full scanner output into chat.

1. Run `python3 .claude/scripts/workspace-quality-scan.py --root . --days 30 --json` and parse every finding. A zero exit from `.claude/scripts/validate-workspace.sh` is wiring evidence only, not proof that the workspace is healthy.
2. Run `python3 .claude/scripts/kb-hygiene-scan.py --workspace-scan --root . --json`, then scan each in-scope project KB against its repository `HEAD` where the repo is available. Record the helper path and explicit root override used.
3. Run `bash tests/check-local-sensitive-artifacts.sh --workspace`. This full ignored-workspace pass reports only path, line, and secret kind. Classify a match only through bounded local inspection whose output is redacted before it reaches a tool result, report, or chat. Never quote, copy, diff, or store the matched value.
4. Run the normal workspace validation and relevant focused tests. Record command, exit status, and the shortest decisive output.

## Deep review

### Content and relationships

- Index headings, explicit links, domain-map entries, age, size, lesson candidates, effort references, and todo entries.
- Classify contradictions, duplicates, healthy overlaps, missing cross-references, stale content, orphans, sparse files, temporary artifacts, one-sided entries, low-signal platitudes, and lesson-promotion candidates.
- Use `.claude/docs/kb-relationship-graph.md`, `.claude/docs/kb-staleness.md`, and `.claude/docs/kb-template.md -> Verification triad`. Age alone is not evidence that a fact is obsolete. Separate broken Markdown links from inert code-span references.

### Security and propagation

- Treat every credential-like match as P0 until disproved without rendering the value. Trace whether its file enters backups, staged outbound payloads, logs, reports, or already-published comments. Remote checks are read-only.
- A secret in a backup or external comment is a propagation incident, not one local finding. Report each surface separately and name rotation or removal as a gated action.

### Authoritative state

- Validate active, done, and archived effort frontmatter against `.claude/docs/effort-lifecycle.md -> Status Vocabulary` and file location.
- `workspace/efforts/` is authoritative for initiatives. `workspace/tasks/todo.md` contains independent open work only: no checked or dropped items, no duplicate initiative state, and no unresolved effort pointer.
- Check durable indexes and manifests for unique keys, referential integrity, and atomic publication. Exercise writers, optimizers, backup, and restore helpers against a copy fixture so duplicate identifiers or a failed second write cannot delete or split state.

### Operational contracts

- Verify each documented command from its exact documented working directory in a fixture or dry-run, including required arguments and claimed output scope.
- Compare recovery claims with what the restore code actually writes. Compare version pins and targets across runbooks, deploy scripts, and live configuration evidence when available.
- Inventory backups by count, logical bytes, recent creation rate, and bounded recent content hashes. Verify content deduplication plus count or size retention; a time-only retention window does not bound repeated Stop-hook backups. Exercise unchanged content, changed content within the same timestamp granularity, and concurrent runs; archive names must be collision-safe.
- Inventory `workspace/tmp/` by producer, age, size, and recoverability. Do not classify a file as disposable until its producer and restore path are known.
- When both journal and daily log exist, compare freshness and flag lost post-wrap-up entries instead of assuming one source is complete.

## Findings and repair

1. Write `workspace/recaps/kb-review-{YYYY-MM-DD}.md` with severity, evidence path and line, impact, root cause, repair class, verification, and status for every finding. Redact values before the report is drafted.
2. Group repairs as:
   - deterministic local workspace correction,
   - judgment-bearing local rewrite or code fix,
   - external, credential, deletion, or rotation action.
3. Push one late approval checkpoint containing exact local targets and compact diff summaries. Missing evidence stays a finding, not a rewrite.
4. For approved durable workspace changes, stage complete targets, show diffs, and apply through `workspace-write-guard.py` with mtime, source hash, and staged hash checks. Never auto-delete a non-empty file.
5. For approved versioned helper fixes, use the repository branch or worktree workflow and add the smallest fixture-based regression test that reproduces the failure. An exact code proposal is not repair-ready until that test executes successfully in a disposable copy.
6. External, credential, deletion, and rotation actions require separate named approval with the exact target and payload. Never publish, rotate, prune backups, or delete temporary state as part of the local repair batch.

## Verification and output

Before marking an applied repair or exact proposal repair-ready, re-run every deterministic preflight command and focused regression test against the modified target or disposable copy. A green validator does not close remaining scanner findings. Report applied, skipped, drifted, externally gated, and still-open items.

The complete report is the canonical artifact. Chat returns its path and at most five short lines with the highest-severity findings and the approval boundary.

Preserve provenance, project boundaries, and confidential markers.
