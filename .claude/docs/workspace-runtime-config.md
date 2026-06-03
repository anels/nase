# Workspace Runtime Config

Shared rule for workspace skills that call organization-specific services,
model/tool integrations, Jira/ADO/Confluence/Slack resources, or cloud endpoints.

## Rule

Do not treat hardcoded company IDs, project names, page IDs, model names, or
tool names as the source of truth. They are examples or fallbacks only.

Before using any drift-prone value, read `workspace/config.md` and any
skill-specific registry section first. Recommended keys:

```markdown
## Runtime
- github_org:
- ado_org_url:
- ado_project:
- jira_project:
- confluence_space:
- confluence_runbook_page_id:
- slack_workspace:
- appinsights_default_subscription:
- codex_review_model:
- claude_ultrareview_command:
```

If a key is missing:

1. Use a documented repo-local source if one exists.
2. Otherwise ask once and show the exact value that will be used.
3. Never silently fall back to an old production org/page/pipeline ID for a
   mutation.

## Tool And Model Probing

For tools, MCP servers, and model aliases, probe runtime availability before use
instead of relying on version notes in a skill body. If unavailable, skip the
optional pass cleanly or ask the user to configure it.

Examples:

- Claude Code CLI subcommands: run `claude <subcommand> --help`.
- MCP tools: use `ToolSearch` / available-tool discovery before naming a tool.
- Codex/OpenAI model aliases: read the active MCP/plugin config or official
  model catalog when the exact model matters.
