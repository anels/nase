# nase Reference Guide

Read this file on demand. It points to the maintained source instead of repeating workspace and helper inventories.

## Navigation

- [Architecture](../../docs/architecture.md) owns the workspace layout, hooks, runtime configuration, and model routing.
- [README](../../README.md) owns the command overview and setup guidance.
- Slack draft styling routes through `voice-profile-routing.md`; read `workspace/communication-style.md` only for high-stakes or ambiguous drafts.
- Use `rg --files .claude/docs .claude/scripts` to discover a shared doc or helper, then read only the needed file.
- FSD delivery gates: `fsd-delivery-gates.md` owns the mandatory final quality/spec reviews, shared QA state machine, PR, verification-matrix, KB controls, closure ledger, final report, and error handling.
- FSD progressive loading: `fsd-intake-and-setup.md` owns Phases 1-3.7; `fsd-implementation-loop.md` owns Phases 3.5-6.1. The command entrypoint owns the interface, state contract, commit/push tree assertions, delivery routing, and worktree cleanup.
- Address-comments progressive loading: `address-comments-analysis.md` owns Phases 1-4; `address-comments-delivery.md` owns Phases 5-12. Load delivery only after the user confirms execution.
- Discuss-pr progressive loading: `discuss-pr-analysis.md` owns Steps 1-5.7; `discuss-pr-output.md` owns Step 6 through final logging (draft decision, gated review submission, completion). Analysis is investigation-only; the review submission and any reactions/replies are gated through `external-write-action.py` after explicit confirmation.
- Command context budgets: `skill-authoring-contract.md` §12 owns entrypoint, description-catalog, and reference navigation limits; CI enforces them across core and workspace skills.
- PR next-step handoff: `pr-next-step-handoff.md` owns the explicit follow-on workflow choices after comment resolution.
- Worktree cleanup: `worktree-pattern.md` owns remote-OID verification and safe retained-worktree behavior; automated workflows never force-remove worktrees.
- Context moves: `context-boundary.md` owns the phase-boundary tree (continue → clear → hand off → subagent → compact); `CLAUDE.md → Compact instructions` owns what a compaction must preserve.
- Canonical pointer wording: `language-config.md → Canonical pointer` owns the language-preflight spelling every skill copies verbatim; `tests/check-canonical-pointers.sh` fails on any reworded or inlined copy.
- Skill evaluation: `.claude/scripts/skill-eval-run.py` runs isolated routing and fixture-backed output probes, stores private hash-bound receipts, reports separate coverage dimensions, and records explicit human review.
- Citation validation: `.claude/scripts/citation-validator.py` validates GitHub, Jira, Confluence, and multi-root source references with `OK`, `BROKEN`, and `UNKNOWN` outcomes before report promotion.
- Effort-rollup evidence: `effort-rollup-integrity.md` owns staging and promotion; `.claude/scripts/effort-rollup-evidence.py` collects fresh scope-bound GitHub evidence and independently re-derives delivery roles, buckets, coverage, and critical totals.

## Execution Style

<default_to_action>
When a command is triggered, execute the workflow steps directly.
Only pause for user input at explicitly marked checkpoints (e.g., "ask the user", "Pause").
Proceed through git commands, file reads, and data gathering without asking permission.
</default_to_action>

<execution_style>
Engineering commands fall into three categories:
- **Data gathering** (doctor, stats): collect all data first, then present - execute deterministically.
- **Interactive** (kb-update, onboard): gather context automatically, then pause at marked checkpoints for user input.
- **One-pass** (wrap-up): runs non-Jira/non-style-delta-gate steps without pausing - reflect -> learn -> extract-skills -> kb-update -> style-delta -> journal entry, writes output to `workspace/journals/YYYY-MM-DD.md` (overwrites if exists); edit the file afterward as needed.
In both cases, start executing immediately. Reserve deliberation for synthesis steps (writing summaries, identifying patterns).

**Concurrency rule**: independent sub-tasks MUST be dispatched in a single message with multiple Agent/tool calls - never serialized. Sequential execution is only valid when step B's input depends on step A's output.
</execution_style>

## Search Strategy

- Start with semantic or content search when a repository is unfamiliar.
- Use exact `rg` searches once the symbol or phrase is known.
- Read only the relevant symbols or sections rather than large files wholesale.

## Key Decisions & Architecture Notes
<!-- Format: ### YYYY-MM-DD - {topic} -->
<!-- Appended by /nase:learn or /nase:reflect when prompted -->

### 2026-07-09 - Skill telemetry v2 uses activation as usage
`track-skill-prompt.sh` records `requested` when a prompt contains a slash command and `activated` only when Claude Code expands it. `track-skill.sh` separately records `tool_succeeded` and `tool_failed`. Records carry `source` and, when supplied by the hook payload, `session_id`. Usage reports count activations, not prompt recognition or outcome events; old `{skill, ts, status?}` records remain readable with the prior bounded dedupe fallback.

### 2026-03-19 - Zip-based backup with retention
`stop-backup.sh` runs the full workspace credential, coverage, and symlink preflight, copies the source into a private local snapshot, and requires the final archive to match the snapshot's path, mode, and content manifest before publishing a timestamped zip (`nase-backup-YYYYMMDD-HHMMSS.zip`). A failed scan, changed snapshot, incomplete archive, or publish collision creates no external archive. When the snapshot manifest fingerprints identically to the last published archive the run is skipped instead of publishing a byte-different copy of unchanged content; the fingerprint is stored at `.nase-backup-state` (repo root, ignored) and excludes `logs/.backup-status`, which this hook rewrites every run. A skip requires at least one surviving archive, so an expired target always re-publishes. Retention policy comes from `backup_retention:` in `workspace/config.md` and accepts `count:N`, `days:N`, or both (`days:30,count:200`); when both are given, age prunes first and the count cap then bounds a single busy day (default: `count:100`). Legacy flat-copy backups are detected but require manual recovery. Restore (`restore.md`) uses `restore-workspace.py` to bind a preview manifest to the archive and current workspace, validate zip or legacy 7z members, and switch the fully extracted candidate into place with a recoverable rename journal. Supersedes earlier flat-copy, rsync, and delete-then-copy approaches.
