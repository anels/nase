# Skill Permission Profiles

Enforcement reference for `/nase:skill-audit` Category 7 (privilege boundary). Read it
when a scanned skill needs an enforcement recommendation; the audit's own flow does not
need it otherwise.

## Deny rule semantics

Claude Code permissions support allow, ask, and deny rules. Deny rules are evaluated
before ask/allow and are enforced by Claude Code, not by the model. A bare deny rule such
as `Bash` removes that tool from Claude's context; scoped rules such as
`Bash(git push *)` keep the tool available but block matching calls.

## Settings shape

```json
{
  "permissions": {
    "deny": [
      "Bash(git push *)",
      "Bash(curl *)",
      "WebFetch",
      "mcp__plugin_slack_slack__slack_send_message"
    ]
  }
}
```

Rule names match registered tool identifiers (e.g. `Bash`, `Edit`, `Write`, `WebFetch`,
`WebSearch`, and fully-qualified `mcp__<server>__<tool>` form for MCP tools). Prefer
scoped Bash rules over blanket `Bash` when the skill still needs safe read/build commands.

## Recommended profiles

| Skill purpose | Suggested enforcement |
|---|---|
| Read-only KB / search / status report | Run in plan/read-only mode; deny `Edit`, `Write`, external write MCP tools, and risky Bash mutations |
| Local-only mutation (file edits, no network) | Deny `WebFetch`, web-search tools, and external write MCP tools; keep repo-local Bash scoped to build/test/git read commands |
| Web research only (no local writes) | Deny `Edit`, `Write`, repo mutation Bash, and external write MCP tools |
| Single-MCP-server skill (e.g. Slack draft only) | Deny other MCP write tools plus repo mutation Bash; allow only the needed read/draft tools |
| Destructive/local cleanup skill | Prefer sandbox/worktree isolation plus PreToolUse hooks; deny broad filesystem delete commands unless exact paths are guarded |

## Reporting the recommendation

For every Category 7 finding, the audit report should include a ready-to-paste snippet in
the *Settings shape* above, scoped to the tools that finding names, or a hook
recommendation.

If a setting would be too broad for the whole workspace, recommend a PreToolUse hook or
running the skill in a restricted permission mode instead of weakening the rule.
