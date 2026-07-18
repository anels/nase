# Confluence ADF Pattern — Shared Reference

## Contents

- Always write with `contentFormat: "adf"`
- Update vs Create
- Full Body Requirement
- Jira Links: always `inlineCard`
- GitHub & other external links
- People mentions: `mention` node
- Draft Pages
- Preserve Existing Content
- Batch All Changes
- Runbook Search Pattern
- ADF Format Details

Shared rules for reading and writing Confluence pages via Atlassian MCP. Referenced by skills that touch Confluence pages (runbook-from-incident, kb-teamshare, investigate-sre-jira, alert-rule-quality-checker).

---

## Always write with `contentFormat: "adf"`

Every `createConfluencePage` / `updateConfluencePage` body must be sent as `contentFormat: "adf"`. The MCP enum also offers `markdown` and `html`, but ADF is the workspace standard because it is what round-trips `inlineCard` Jira links, panels, tables, and embedded screenshots without loss. Fetch the current page as ADF (`getConfluencePage`), modify in memory, and send ADF back.

`.claude/hooks/confluence-size-guard.sh` enforces this — it blocks a page write whose `contentFormat` is unset, `markdown`, or `html`. If a page genuinely cannot be expressed as ADF, save a draft to `workspace/tmp/` and ask the user to paste it manually rather than downgrading the format.

This is the **opposite** of Jira, where bodies must be `markdown` (see `.claude/docs/jira-write-pattern.md`). The format gate is write-only — reading a page as `markdown` for human-readable internalization (e.g. `confluence-doc-internalize`) is unaffected.

---

## Update vs Create

- **Existing page**: use `updateConfluencePage` — always fetch the current page first, then send the full modified body back.
- **New page**: use `createConfluencePage`. Ask the user to confirm the target parent page URL or space key before creating.

---

## Full Body Requirement

`updateConfluencePage` requires the **entire** page body — no partial updates. Always:

1. `getConfluencePage(pageId)` — fetch current ADF body and version number
2. Modify only the target sections in memory
3. Send the full modified body + incremented version back

Never reconstruct the body from scratch — you will lose screenshots, custom formatting, and manually added content.

---

## Jira Links: always `inlineCard`

Never use plain URLs or markdown links for Jira references in Confluence. Use `inlineCard` — it renders as a Smart Link with title and status badge:

```json
{"type": "inlineCard", "attrs": {"url": "https://your-org.atlassian.net/browse/PROJ-XXXXXX"}}
```

Multiple tickets in one cell — separate with `hardBreak`:

```json
{"type": "inlineCard", "attrs": {"url": "https://your-org.atlassian.net/browse/PROJ-111"}},
{"type": "hardBreak"},
{"type": "inlineCard", "attrs": {"url": "https://your-org.atlassian.net/browse/PROJ-222"}}
```

---

## GitHub & other external links

`inlineCard` accepts any URL (`attrs.url`), so the same node works for GitHub PRs/issues, Bitbucket, Google Drive, etc. But a **smart card only renders for a viewer whose account is connected** to that service — GitHub in particular prompts each reader to "connect your account to preview links." Until then it falls back to a plain inline link. Jira, Confluence, and Bitbucket cards render natively (Atlassian-owned).

So: use `inlineCard` for GitHub links and accept the graceful link fallback. Do not assume readers see a card. If a plain hyperlink is preferable, use a normal `link` mark instead.

---

## People mentions: `mention` node

Never type `@name` as plain text — it does not resolve or notify. Use a `mention` node with the Atlassian account ID:

```json
{"type": "mention", "attrs": {"id": "<accountId>", "text": "@Display Name"}}
```

Only `type` and `attrs.id` are required. Resolve the account ID with `lookupJiraAccountId` / `atlassianUserInfo` (the ID is shared across Jira and Confluence) — never guess it. Confluence stores this as `<ac:link><ri:user account-id="…"/></ac:link>`; sending the ADF `mention` node lets the MCP do that conversion.

---

## Draft Pages

If a page has never been published (draft), pass `status: "draft"` on every `updateConfluencePage` call:

```json
{"status": "draft", "version": {"number": 1}, ...}
```

Without it the API auto-increments to version 2 and returns `400: "Version number must be 1 when publishing a page for the first time"`. Draft pages stay at version 1 until explicitly published.

---

## Preserve Existing Content

- Do not remove, reformat, or restructure anything already on the page — including screenshots, embedded images, hand-curated notes, and custom table attributes.
- Only modify the specific sections your change targets; leave everything else byte-identical.
- If you cannot safely preserve a section, save a local draft to `workspace/tmp/` and ask the user to paste it manually.

---

## Batch All Changes

Each `updateConfluencePage` call requires a full fetch + send cycle. Accumulate all pending changes (new rows, cell appends, section edits) and apply them in a single call — never make multiple sequential updates to the same page.

---

## Runbook Search Pattern

When searching for a runbook by alert name, use noun fragments rather than the full hyphenated rule name:

```
searchConfluenceUsingCql: text ~ "<noun1>" AND text ~ "<noun2>" AND space = "RPAAP"
```

Also check the oncall handoff tree: `ancestor = 2921399304 AND text ~ "<alert keyword>"`.

---

## ADF Format Details

For deeper mechanics (node types, table row structure, cell attribute schemas) — see KB `workspace/kb/ops/oncall-runbooks.md` → Confluence ADF Mechanics.
