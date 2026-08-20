---
name: nase:publish-confluence
description: "Publish a local Markdown or HTML artifact to Confluence with tables, code, and charts preserved. Use for publish to Confluence, share this report, put this on the wiki, or a local report path."
argument-hint: "<path-to-md-or-html> [--space KEY] [--parent ID] [--no-rasterize]"
pattern: pipeline
category: Reporting
---

Publish a finished local `.md`/`.html` artifact as a Confluence page, preserving structure and rendering charts that Confluence cannot express. Triggers: "publish to Confluence", "share this report on the wiki", "put this doc on Confluence", or a path to a local report.

**Input:** `$ARGUMENTS` — an absolute path to a local `.md` or `.html` file. Optional: `--title`, `--space`, `--parent`, `--no-rasterize`, `--rasterize <selector>`.

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/external-mutation-policy.md` — every Confluence write goes through draft-first plus an `AskUserQuestion` showing the concrete payload. Conversion rules live in `.claude/docs/confluence-publish-conversion.md`; format selection and ADF mechanics in `.claude/docs/confluence-adf-pattern.md`; the ledger write follows `.claude/docs/workspace-write-guard.md` (append-only exception).

## Step 1 — Input guard

If `$ARGUMENTS` has no readable file path, use `AskUserQuestion` to collect one. Do not guess a source. The file may live outside this workspace (a sibling repo's `workspace/reports/**` is normal); it is only ever read.

## Step 2 — Pre-publish gates (all block)

```bash
gitleaks detect --no-git --source "{source}" --redact --no-banner
grep -l '\[CONFIDENTIAL' "{source}"
```

A `gitleaks` finding or a `[CONFIDENTIAL]` marker stops the run. Report the redacted rule and line, never the value.

**Say plainly in the confirm that the scan is partial.** Verified: `gitleaks` flags `ghp_*` and `xoxb-*` but missed a SQL connection-string password in the same fixture. It is a lead, not a clean bill.

## Step 3 — Convert and measure

```bash
python3 .claude/scripts/confluence-publish.py plan \
  --source "{source}" --out-dir "workspace/tmp/confluence-{slug}"
```

Exit 3 = a single block exceeds the cap; exit 4 = a nesting construct Confluence rejects. Both name the cause — relay it and stop; do not restructure the user's document.

Read `plan.json` for `title`, `pages[]`, `split_differs_without_visuals`, and `warnings`.

## Step 4 — Find the target (before asking anything)

Work this ladder, then ask once:

1. **Ledger** — `python3 .claude/scripts/confluence-publish.py ledger-lookup --source "{source}" --pages {N}`. Per-page `create`/`update`, `orphans`, and the prior month's page family.
2. **cloudId** — `workspace/config.md` `## Jira → cloudId` (same site), confirmed with `getAccessibleAtlassianResources`.
3. **KB** — `workspace/kb/cross-project/insights-rpaap-confluence-map.md` for a topical parent.
4. **CQL by title** — `title ~ "{stem}" AND type = page`. Also pre-empts the title conflict in Step 6.
5. **CQL by author** — `creator = currentUser() AND type = page ORDER BY lastmodified DESC`, limit 10.
6. **Spaces** — `getConfluenceSpaces` as the fallback list.

For every `update` candidate, fetch `getConfluencePage(contentFormat:"html")` and compare against the ledger's `published_body_sha256`.

## Step 5 — One confirmation

A single batched `AskUserQuestion` presenting a decision-ready brief — never the draft body:

| Question | Content |
|---|---|
| Target | ranked candidates as `{space key} · {space name}` so the audience is explicit; recommended first with its evidence |
| Create or update | for an update, quote the page id, title and `lastModified`. If the page is **not** in the ledger, or its body hash differs, say *this replaces content this skill did not publish* |
| Page structure | measured byte counts. When the ledger holds one page and this run splits, add *the existing page becomes a link-list index; its content moves to {M} children, so inbound links land on the index* |
| Visuals | `{K}` charts → PNG + placeholders. When `split_differs_without_visuals` is set, state the page count each answer produces. `adjust selectors` re-runs Step 3 and re-shows this confirm |

State that space permissions were **not** verified — the MCP exposes no permission field — and that the secret scan is partial. The audience call stays with the user.

## Step 6 — Publish

```bash
python3 .claude/scripts/confluence-publish.py render --plan "workspace/tmp/confluence-{slug}/plan.json"
```

Then, in order: create/update the parent, create/update each child, then update the parent with the link list (a child's ID does not exist until it is created). Send `contentFormat: "html"` for an HTML source and `"markdown"` for a Markdown one — never `storage`.

Append one ledger record **per page as it lands**, so an interrupted fan-out leaves an accurate trail:

```bash
python3 .claude/scripts/confluence-publish.py ledger-append \
  --source "{source}" --page-index {i} --page-id {id} --page-url "{url}" \
  --published-at "{ISO-8601}" --published-body-sha256 "{sha}" --format html
```

**Title conflict.** Confluence titles are unique per space, so a create can fail on a page someone made by hand. Surface the error and the conflicting page and let the user pick update-or-rename. Never auto-append a `(2)` suffix — that is how duplicates accumulate.

**Orphans.** If `ledger-lookup` reported orphans, name them with their URLs. Never delete Confluence content.

## Step 7 — Report and clean up

Per `.claude/docs/skill-contract.md`: pointer plus ≤ 5 lines. Include the page URLs, and group any PNGs **by the page they attach to** — an attachment belongs to one page, so a flat list sends the reader to the wrong one. Then delete `workspace/tmp/confluence-{slug}/` so emitted bodies of a sensitive report do not reach the next backup.

Append a daily-log line per `.claude/docs/daily-log-format.md`.

## Notes

- Charts are rendered locally and attached **by hand** — there is no attachment-upload path: the MCP has no such tool, REST v2 is GET/DELETE only, and `acli confluence page` exposes only `view`. Each placeholder carries a collapsed `Chart data (text)` expand so the page stays searchable before and after attaching.
- `updateConfluencePage` replaces the whole body; this skill does not merge sections, and the confirm says so.
- Markdown passthrough cannot express panels, expands, or inline cards. Use an HTML source when those matter.
