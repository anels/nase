# Jira Write Pattern — Shared Reference

Canonical format rule for skills that create or edit Jira content via Atlassian MCP. Referenced by skills that mutate Jira (investigate-sre-jira, alert-rule-quality-checker, design). Pairs with `.claude/docs/external-mutation-policy.md` (the approval + token gate) and `.claude/docs/confluence-adf-pattern.md` (Confluence is the opposite — ADF there).

---

## Default to `contentFormat: "markdown"`

Body-bearing Jira mutations are `createJiraIssue` (the `description`), `editJiraIssue` (`fields.description` and any rich text field), and `addCommentToJiraIssue` (the `commentBody`). The Atlassian MCP `contentFormat` enum is `["markdown", "adf"]`, and the **default when omitted is ambiguous** — never rely on it. Always set the format explicitly.

For plain text, set `contentFormat: "markdown"`. This is the default choice and pairs with the single-shot sha token.

### Why markdown for plain text

ADF JSON re-serializes between the moment a skill computes the token sha and the moment `jira-write-guard.sh` sees `tool_input` (whitespace + block-tree normalization inside the nested document object). That drifts the canonical `jq -cS .tool_input` sha, so the single-shot token's `payload_sha256` no longer matches, even on bodies stripped of all non-ASCII. This has been observed in real Jira write attempts: equivalent markdown payloads kept the sha stable, while ADF payloads drifted after hashing. A plain-text markdown string has no nested JSON to re-serialize, so its sha is stable.

---

## When you must @mention a person: ADF + batch token

**Markdown cannot render a resolving @mention.** A plain `@name` and Jira wiki `[~accountid:…]` both render as literal text in a markdown body — the user is not linked and not notified. A real mention requires an ADF `mention` node:

```json
{"type": "mention", "attrs": {"id": "<accountId>", "text": "@Display Name"}}
```

Only `type` and `attrs.id` (the Atlassian account ID) are required; `text` should carry the leading `@`. Resolve the account ID with `lookupJiraAccountId` (or `atlassianUserInfo` for yourself) — never guess it.

So when a comment or description must mention/notify someone, send the whole body as `contentFormat: "adf"`. Because ADF drifts the single-shot sha (above), the guard allows ADF **only under a batch / issue-allowlist token**, which binds the approved issue set + an op-count cap instead of the payload bytes. Steps:

1. `AskUserQuestion` showing the target issue(s) and the mention(s).
2. Write a batch token (`approved_issues`, `max_ops`, `created_at`) — see `.claude/docs/external-mutation-policy.md` → batch token.
3. Call `editJiraIssue` / `addCommentToJiraIssue` with `contentFormat: "adf"`.

`createJiraIssue` cannot use a batch token (no issue key exists yet), so it is markdown-only — create the issue in markdown, then add the mention via an ADF `addCommentToJiraIssue` or `editJiraIssue` under a batch token.

### Links render without ADF

A bare Jira key (`PROJ-123`) auto-links natively, and a full URL renders as a clickable link, in a markdown body — so you do not need ADF just for Jira/GitHub references. ADF is only required for **mentions** and other rich nodes (smart cards, panels). Reserve it for those.

---

## Token sha must include `contentFormat`

The single-shot token's `payload_sha256` is computed over the exact `jq -cS .tool_input` that will be sent. Build the full payload — including `contentFormat: "markdown"` — *before* hashing, then send it byte-identical:

- No trailing newline on the body.
- No late edits between hashing and the call.

```bash
PAYLOAD_SHA=$(jq -cS '.tool_input // {}' "$JIRA_TOOL_CALL_JSON" | shasum -a 256 | awk '{print $1}')
```

---

## Hook enforcement

`.claude/hooks/jira-write-guard.sh` gates `editJiraIssue` / `createJiraIssue` / `addCommentToJiraIssue`: `markdown` is always allowed, `adf` is allowed **only when a batch token is present**, and an unset/other format is blocked. The check runs after token-mode detection so it can tell single-shot from batch. `transitionJiraIssue`, `addWorklogToJiraIssue`, and `createIssueLink` carry no rich body and are not format-gated.

---

## Reading is unaffected

This rule is about **writes**. Reading Jira (`getJiraIssue`, `searchJiraIssuesUsingJql`) and choosing `responseContentFormat` is independent — read in whatever format is most useful.
