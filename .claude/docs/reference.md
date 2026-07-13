# nase Reference Guide

Read this file on demand. It points to the maintained source instead of repeating workspace and helper inventories.

## Navigation

- [Architecture](../../docs/architecture.md) owns the workspace layout, hooks, runtime configuration, and model routing.
- [README](../../README.md) owns the command overview and setup guidance.
- Slack draft styling routes through `voice-profile-routing.md`; read `workspace/communication-style.md` only for high-stakes or ambiguous drafts.
- Use `rg --files .claude/docs .claude/scripts` to discover a shared doc or helper, then read only the needed file.
- FSD delivery gates: `fsd-delivery-gates.md` owns the conditional self-review, pre-push, PR, verification-matrix, and KB controls.
- FSD progressive loading: `fsd-intake-and-setup.md` owns Phases 1-3.7; `fsd-implementation-loop.md` owns Phases 3.5-6. The command entrypoint owns the interface, state contract, delivery routing, and final report.
- Address-comments progressive loading: `address-comments-analysis.md` owns Phases 1-4; `address-comments-delivery.md` owns Phases 5-12. Load delivery only after the user confirms execution.
- Discuss-pr progressive loading: `discuss-pr-analysis.md` owns Steps 1-5.7; `discuss-pr-output.md` owns Step 6 through final logging. The command remains read-only.
- PR next-step handoff: `pr-next-step-handoff.md` owns the explicit follow-on workflow choices after comment resolution.

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
`stop-backup.sh` creates timestamped zip archives (`nase-backup-YYYYMMDD-HHMMSS.zip`) via `7z a -tzip` (`scoop install 7zip`). Retention policy (`count:N` or `days:N`) from `backup_retention:` in `workspace/config.md` (default: `count:100`). Old flat-copy backups are auto-migrated on first run. Restore (`restore.md`) lists available zip backups and extracts with `unzip`. Supersedes earlier flat-copy and rsync approaches.
