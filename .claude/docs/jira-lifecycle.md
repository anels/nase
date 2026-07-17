# Jira Lifecycle — Shared Reference

Standard patterns for reading and transitioning Jira issues via Atlassian MCP. Referenced by skills that check or update Jira status (today, wrap-up, investigate-sre-jira, address-comments, request-review).

---

## Prerequisites

Read `cloudId` from `workspace/config.md` → `## Jira` section before any MCP call. If `cloudId` is missing or Atlassian MCP is unavailable, skip all Jira operations silently — never block the skill on Jira access.

---

## Fetch a Single Ticket

```
getJiraIssue(cloudId, issueIdOrKey)
```

Extract from response: `fields.status.statusCategory.name`, `fields.summary`, `fields.description`, `fields.comment.comments`.

---

## Bulk Search

```
searchJiraIssuesUsingJql(cloudId, jql, fields, maxResults)
```

Common JQL patterns:

```
# My open tickets, recently updated
assignee = currentUser() AND status in ("In Progress", "To Do", "Open") AND updated >= -7d ORDER BY updated DESC

# Prior closed tickets for the same alert/component
project = SRE AND summary ~ "<keyword>" AND status in (Canceled, Resolved) AND created >= -90d ORDER BY created DESC
```

Limit to 10 results unless a broader sweep is needed.

---

## Transitions

Do not hardcode transition IDs — they vary by project and workflow. Always look them up:

```
getTransitionsForJiraIssue(cloudId, issueIdOrKey)
```

Find the transition whose `name` matches the target status, then:

```
transitionJiraIssue(cloudId, issueIdOrKey, {transition: {id: "<id>"}})
```

### Confirmation rules

- **Any transition** — require explicit user confirmation before calling `transitionJiraIssue`. Present the ticket key, summary, current status, and target status.
- **Done / Resolved / Canceled / Closed** — treat as high-risk closure. Never silently close.
- **Write-token backstop** — every Jira mutation must publish a fresh `workspace/.jira-write-token` immediately after the payload-showing `AskUserQuestion` approval and immediately before the MCP call. Use `python3 .claude/scripts/jira-write-token.py --root . --content-file <approved-token.json>` so token publication shares the workspace mutation lock with consumption. Follow `.claude/docs/external-mutation-policy.md` for token shape.

For SRE tickets specifically: see KB `workspace/kb/ops/oncall-runbooks.md` → Transition IDs for the known IDs and per-transition confirmation requirements.

---

## Graceful Degradation

Wrap every Jira MCP call in a silent-skip pattern:

- Atlassian MCP unavailable → skip, continue skill
- `cloudId` missing from config → skip, continue skill
- `getJiraIssue` returns 404 → skip that ticket, continue with others
- Transition fails → log the error, do not retry silently; surface to user if transition was user-confirmed
