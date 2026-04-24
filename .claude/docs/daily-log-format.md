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

| Skill | Tag |
|-------|-----|
| `/nase:fsd` | `fsd` |
| `/nase:address-comments` | `address-comments` |
| `/nase:discuss-pr` | `review` |
| `/nase:prep-merge` | `prep-merge` |
| `/nase:design` | `design` |
| `/nase:learn` | `learn` |
| `/nase:kb-review` | `kb-review` |
| `/nase:kb-merge` | `kb-merge` |
| `/nase:kb-teamshare` | `kb-teamshare` |
| `/nase:recap` | `recap` |
| `/nase:onboard` | `onboard` |
| `/nase:estimate-eta` | `estimate` |

Skills not listed: use the command name without `/nase:` prefix.

## Rules

- One line per entry. No multi-line blocks.
- Include repo name or PR number when relevant: `fsd: Insights-monitoring — add watchdog function (#2626)`
- Append immediately when the action completes — do not batch entries.
