# Confluence ADF Pattern - Shared Reference

## Contents

- Accepted write formats by MCP generation
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

## Accepted write formats by MCP generation

Which formats a page body may carry depends on the MCP generation you are on - see *The current MCP generation* below. The current `createConfluenceContent` / `updateConfluenceContent` pair takes `html` or `markdown`; the older `createConfluencePage` / `updateConfluencePage` pair also takes `adf`. All of them go through the MCP's own converter. `adf` and `html` are lossless for `inlineCard` Jira links, panels, tables, expands, and attachment references; **`markdown` is not** - measured on the round-trip, it cannot express any of those, and a markdown Jira link stays a plain `<a href>`. Pick by what you are holding:

| You are | Use | Why |
|---|---|---|
| Editing a page you fetched as ADF, on the older MCP | `adf` | Modify the fetched tree in memory and send it back; no conversion in either direction. On the current MCP, fetch and send `html` instead. |
| Publishing converted HTML | `html` (Confluence HTML+) | The source is already HTML, and HTML+ is exactly what `getConfluenceContent(contentFormat:"html")` returns, so it is the server's own shape. It is also far more compact than ADF for the same content, which matters against the size cap below. |
| Publishing a Markdown document | `markdown` | Passthrough, no local converter. Lossy: no panels, expands, or inline cards - use `html` when those matter. Markdown is also terser than the other two, so it expands further into storage format; split well below the cap. |

`.claude/hooks/confluence-size-guard.sh` enforces the set - it matches both generations and blocks a page write whose `contentFormat` is unset, `storage`, or anything outside the enum that generation accepts. The same hook caps a body at 70000 bytes, which is the size cap referred to throughout this document. If a page genuinely cannot be expressed in one of them, save a draft to `workspace/tmp/` and ask the user to paste it manually rather than downgrading the format.

### The current MCP generation: `*ConfluenceContent`

The Atlassian MCP renamed these tools and changed the body shape. Read the live tool schema before writing; do not assume this doc's older spelling is what is installed.

| | Older MCP | Current MCP |
|---|---|---|
| Tools | `create/updateConfluencePage`, `getConfluencePage` | `create/updateConfluenceContent`, `getConfluenceContent` |
| Body | top-level `contentFormat` + string `body` | `body: {format, value}` |
| Doc formats | `adf`, `html`, `markdown` | `html`, `markdown`, **no `adf`** |
| Other formats | none | `svg` (whiteboard), `csv` (database), `url` (embed / smart link / synced folder) |
| Concurrency | no version field | `snapshotToken` from a prior `getConfluenceContent` is required for doc-body updates |

The guard matches both generations and applies each one's own format enum, so an `adf` body sent to `updateConfluenceContent` is blocked. On the current MCP, use `html` wherever this doc says `adf`, because it is the server's own shape and round-trips `inlineCard`, panels, tables, and attachments. The ADF node recipes below are written as ADF JSON, so they apply to the older MCP and to anyone hand-building a tree; on the current MCP, fetch the page as `html` and edit the markup the server already returned for that node rather than translating the JSON by hand.

`updateConfluenceContent` also accepts granular `edits` instead of a whole body, and a title-only or width-only update with neither. Those carry no format to gate; the guard still applies the size cap to whatever they send.

`/nase:publish-confluence` owns the HTML → HTML+ conversion rules; see `.claude/docs/confluence-publish-conversion.md`. The ADF mechanics in the rest of this doc still govern every caller working in ADF.

This is the **opposite** of Jira, where bodies must be `markdown` (see `.claude/docs/jira-write-pattern.md`). The format gate is write-only - reading a page as `markdown` for human-readable internalization (e.g. `confluence-doc-internalize`) is unaffected.

---

## Update vs Create

- **Existing page**: use `updateConfluenceContent` - always fetch the current page first, then send the full modified body back.
- **New page**: use `createConfluenceContent`. Ask the user to confirm the target parent page URL or space key before creating.

---

## Full Body Requirement

`updateConfluenceContent` requires the **entire** page body - no partial updates. Always:

1. `getConfluenceContent(pageId)` - fetch the current body in the format you intend to send back, plus the `snapshotToken` the update needs
2. Modify only the target sections in memory
3. Send the full modified body back with the fetched `snapshotToken` and no `version` field - see *Draft Pages*

Never reconstruct the body from scratch - you will lose screenshots, custom formatting, and manually added content.

---

## Jira Links: always `inlineCard`

Never use plain URLs or markdown links for Jira references in Confluence. Use `inlineCard` - it renders as a Smart Link with title and status badge:

```json
{"type": "inlineCard", "attrs": {"url": "https://your-org.atlassian.net/browse/PROJ-XXXXXX"}}
```

Multiple tickets in one cell - separate with `hardBreak`:

```json
{"type": "inlineCard", "attrs": {"url": "https://your-org.atlassian.net/browse/PROJ-111"}},
{"type": "hardBreak"},
{"type": "inlineCard", "attrs": {"url": "https://your-org.atlassian.net/browse/PROJ-222"}}
```

---

## GitHub & other external links

`inlineCard` accepts any URL (`attrs.url`), so the same node works for GitHub PRs/issues, Bitbucket, Google Drive, etc. But a **smart card only renders for a viewer whose account is connected** to that service - GitHub in particular prompts each reader to "connect your account to preview links." Until then it falls back to a plain inline link. Jira, Confluence, and Bitbucket cards render natively (Atlassian-owned).

So: use `inlineCard` for GitHub links and accept the graceful link fallback. Do not assume readers see a card. If a plain hyperlink is preferable, use a normal `link` mark instead.

---

## People mentions: `mention` node

Never type `@name` as plain text - it does not resolve or notify. Use a `mention` node with the Atlassian account ID:

```json
{"type": "mention", "attrs": {"id": "<accountId>", "text": "@Display Name"}}
```

Only `type` and `attrs.id` are required. Resolve the account ID with `lookupJiraAccountId` / `atlassianUserInfo` (the ID is shared across Jira and Confluence) - never guess it. Confluence stores this as `<ac:link><ri:user account-id="…"/></ac:link>`; sending the ADF `mention` node lets the MCP do that conversion.

---

## Draft Pages

If a page has never been published (draft), pass `status: "draft"` on every `updateConfluenceContent` call:

```json
{"status": "draft", ...}
```

Without it the API auto-increments to version 2 and returns `400: "Version number must be 1 when publishing a page for the first time"`. Draft pages stay at version 1 until explicitly published.

**Do not send a `version` field.** The current `updateConfluenceContent` tool schema has no `version` parameter - the MCP manages versioning itself. An earlier revision of this doc showed `{"status": "draft", "version": {"number": 1}}`; the `version` half no longer corresponds to anything the tool accepts. Likewise, `getConfluenceContent` returns `lastModified` (e.g. `"Jul 31, 2026"`) and no version number, so quote that when a skill needs to show the user which revision it is about to replace.

---

## Preserve Existing Content

- Do not remove, reformat, or restructure anything already on the page - including screenshots, embedded images, hand-curated notes, and custom table attributes.
- Only modify the specific sections your change targets; leave everything else byte-identical.
- If you cannot safely preserve a section, save a local draft to `workspace/tmp/` and ask the user to paste it manually.

---

## Batch All Changes

Each `updateConfluenceContent` call requires a full fetch + send cycle. Accumulate all pending changes (new rows, cell appends, section edits) and apply them in a single call - never make multiple sequential updates to the same page.

---

## Runbook Search Pattern

When searching for a runbook by alert name, use noun fragments rather than the full hyphenated rule name:

```
searchConfluence: text ~ "<noun1>" AND text ~ "<noun2>" AND space = "RPAAP"
```

Also check the oncall handoff tree: `ancestor = 2921399304 AND text ~ "<alert keyword>"`.

---

## ADF Format Details

For deeper mechanics (node types, table row structure, cell attribute schemas) - see KB `workspace/kb/ops/oncall-runbooks.md` → Confluence ADF Mechanics.
