# Confidential Marker

Use `[CONFIDENTIAL]` in daily logs to keep sensitive entries out of automated
KB, journal, recap, export, and report flows. The marker is a routing tag, not
encryption.

## When to write the marker

Prefix a daily-log line with `[CONFIDENTIAL]` when it includes:

- pre-announcement org or staffing changes
- compensation, leveling, legal, or HR-sensitive material
- customer-sensitive content that should not be copied into KB or exports
- private escalation context that should remain in the daily log only
- anything the user explicitly marks as confidential

Format:

```markdown
- HH:MM [CONFIDENTIAL] short description
```

## Skill-side guard

Any skill that scans daily logs and writes to a less-private surface must check
for the marker before copying or summarizing content:

```bash
if grep -q '\[CONFIDENTIAL' "$LOG_FILE"; then
  # exclude or refuse depending on the skill contract
  :
fi
```

## Disposition by skill

- `/nase:wrap-up`: build a sanitized session set first. Use it for reflection,
  learning, skill extraction, journal prose, highlights, and closing text. If
  today's log contains `[CONFIDENTIAL]`, skip automatic KB update from the log
  unless the user explicitly provides a safe summary.
- `/nase:recap`: exclude marked lines. If a marked line is the only signal for a
  topic, omit the topic rather than paraphrasing around the marker.
- `/nase:kb-update` and `/nase:learn`: refuse to persist user input containing
  `[CONFIDENTIAL]`; ask for a sanitized restatement.
- `/nase:kb-teamshare`: exclude marked lines and fail the export if selected
  files still contain the marker after sanitization.
- `/nase:tech-debt-audit`: do not turn people-sensitive daily-log context into
  named blockers or ownership claims.

## What this is not

- Not a permission to feed sensitive material into another model or tool.
- Not retroactive. If content was already promoted before the marker was added,
  remove it manually from the promoted artifact.
- Not a replacement for judgment. If the content is too sensitive for AI, keep
  it out of prompts and workspace files entirely.
