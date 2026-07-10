# Daily Log Format — Shared Reference

Standardized format for appending entries to `workspace/logs/{YYYY-MM-DD}.md`.

---

## Path

```
workspace/logs/{YYYY-MM-DD}.md
```

Use today's date. Create the file with a `# Work Log — {YYYY-MM-DD}` header and `## Sessions` section if it doesn't exist.

## Entry Format

Append under `## Sessions`:

```
- {HH:MM} | {skill-tag}: {one-line summary}
```

Only the `## Sessions` section is parsed as the canonical daily-log stream.
Other sections may exist, but they are not counted as skill/session activity.

### Skill Tags (canonical)

Renames only — i.e. tags where the form differs from the command name. Every other `/nase:*` skill uses the command name with the `/nase:` prefix stripped (e.g. `wrap-up`, `today`, `tech-digest`, `reflect`, `kb-update`, `kb-gap-detect`).

| Skill | Tag | Notes |
|-------|-----|-------|
| `/nase:discuss-pr` | `review` | Renamed for log brevity |
| `/nase:estimate-eta` | `estimate` | Renamed for log brevity |
| `/nase:design --auto` | `auto-design` | Sub-mode of design |
| `/nase:design --grill` | `grill` | Sub-mode of design |

Skills not in this rename table: use the command name without the `/nase:` prefix (e.g. `/nase:fsd` → `fsd`, `/nase:wrap-up` → `wrap-up`).

## Rules

- One line per entry. No multi-line blocks.
- Include repo name or PR number when relevant: `fsd: {repo-name} — add watchdog function ({pr_number})`
- Append immediately when the action completes — do not batch entries.
- Deterministic hooks use the same shape, e.g. `- 10:42 | worktree: removed \`/tmp/foo\``.
- Files such as `workspace/logs/{YYYY-MM-DD}-sre-tracker.md` use a separate tracker schema and are excluded from daily-log quality checks.

## Self-logging rule (mandatory for tracked skills)

Skills that need to show up in completion history MUST append their own bullet on completion. Telemetry records slash-command activation and tool outcomes, but the daily-log bullet is the durable completion audit record.

Format: the standard entry shape above (`- {HH:MM} | {skill-tag}: {summary}`), using the skill's canonical tag from the rename table. Skip the bullet and the completed work is absent from the daily audit trail.
