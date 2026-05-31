# Confluence ADF Pattern — Shared Reference

Shared rules for reading and writing Confluence pages via Atlassian MCP. Referenced by skills that touch Confluence pages (runbook-from-incident, kb-teamshare, investigate-sre-jira, alert-rule-quality-checker).

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
