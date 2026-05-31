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

## Self-logging rule (mandatory for tracked skills)

Skills that need to show up in `/nase:stats` and `/nase:skill-usage` MUST append their own bullet on completion. The `PostToolUse:Skill` hook misses any skill invoked as a slash-command (e.g. typed `/nase:today`), so the daily-log bullet is the only reliable tracking source.

Format: the standard entry shape above (`- {HH:MM} | {skill-tag}: {summary}`), using the skill's canonical tag from the rename table. Skip the bullet and the skill becomes invisible to tracking.
