---
name: nase:publish-confluence
description: "Publish a local Markdown or HTML artifact to Confluence with tables, code, and charts preserved. Use for publish to Confluence, share this report, put this on the wiki, or a local report path."
argument-hint: "<path-to-md-or-html> [--space KEY] [--parent ID] [--no-rasterize]"
pattern: pipeline
category: Reporting
---

Publish a finished local `.md`/`.html` artifact as a Confluence page, preserving structure and rendering charts that Confluence cannot express. Triggers: "publish to Confluence", "share this report on the wiki", "put this doc on Confluence", or a path to a local report.

**Input:** `$ARGUMENTS` - an absolute path to a local `.md` or `.html` file. Optional: `--title`, `--space`, `--parent`, `--no-rasterize`, `--rasterize <selector>`.

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/external-mutation-policy.md` - every Confluence write goes through draft-first plus an `AskUserQuestion` showing the concrete payload. Conversion rules live in `.claude/docs/confluence-publish-conversion.md`; format selection and ADF mechanics in `.claude/docs/confluence-adf-pattern.md`; the ledger write follows `.claude/docs/workspace-write-guard.md` (append-only exception).

## Step 1 - Input guard

If `$ARGUMENTS` has no readable file path, use `AskUserQuestion` to collect one. Do not guess a source. The file may live outside this workspace (a sibling repo's `workspace/reports/**` is normal); it is only ever read.

## Step 2 - Pre-publish gates (all block)

```bash
gitleaks detect --no-git --source "{source}" --redact --no-banner
grep -l '\[CONFIDENTIAL' "{source}"
```

A `gitleaks` finding or a `[CONFIDENTIAL]` marker stops the run. Report the redacted rule and line, never the value.

**Say plainly in the confirm that the scan is partial.** Verified: `gitleaks` flags `ghp_*` and `xoxb-*` but missed a SQL connection-string password in the same fixture. It is a lead, not a clean bill.

## Step 3 - Convert and measure

```bash
python3 .claude/scripts/confluence-publish.py plan \
  --source "{source}" --out-dir "workspace/tmp/confluence-{slug}"
```

Exit 3 = a single block exceeds the cap; exit 4 = a nesting construct Confluence rejects. Both name the cause - relay it and stop; do not restructure the user's document.

Read `plan.json` for `title`, `pages[]`, `split_differs_without_visuals`, and `warnings`.

## Step 4 - Find the target (before asking anything)

Work this ladder, then ask once:

1. **Ledger** - `python3 .claude/scripts/confluence-publish.py ledger-lookup --source "{source}" --pages {N}`. Per-page `create`/`update`, `orphans`, and the prior month's page family.
2. **cloudId** - `workspace/config.md` `## Jira → cloudId` (same site), confirmed with `getAccessibleAtlassianResources`.
3. **KB** - resolve a Confluence-map file through `workspace/kb/.domain-map.md` for a topical parent. Skip silently if the domain map has no such entry; this rung is an optimisation, not a requirement.
4. **CQL by title** - `title ~ "{stem}" AND type = page`. Also pre-empts the title conflict in Step 6.
5. **CQL by author** - `creator = currentUser() AND type = page ORDER BY lastmodified DESC`, limit 10.
6. **Spaces** - `getConfluenceSpaces` as the fallback list.

For every `update` candidate, fetch `getConfluencePage(contentFormat:"html")` and compare against the ledger's `published_body_sha256`.

## Step 5 - One confirmation

A single batched `AskUserQuestion` presenting a decision-ready brief - never the draft body:

| Question | Content |
|---|---|
| Target | ranked candidates as `{space key} · {space name}` so the audience is explicit; recommended first with its evidence |
| Create or update | for an update, quote the page id, title and `lastModified`. If the page is **not** in the ledger, or its body hash differs, say *this replaces content this skill did not publish* |
| Page structure | measured byte counts. When the ledger holds one page and this run splits, add *content moves to {M} children, so inbound links land on page 1 of N* |
| Visuals | `{K}` charts → PNG + placeholders. When `split_differs_without_visuals` is set, state the page count each answer produces. `adjust selectors` re-runs Step 3 and re-shows this confirm |

State that space permissions were **not** verified - the MCP exposes no permission field - and that the secret scan is partial. The audience call stays with the user.

## Step 6 - Publish

```bash
python3 .claude/scripts/confluence-publish.py render --plan "workspace/tmp/confluence-{slug}/plan.json"
```

Then per page, parent (index 0) before children, because a child needs its parent's ID:

1. Create or update the page with its `page-{i}.body.html`, `contentFormat: "html"` for an HTML source and `"markdown"` for a Markdown one - never `storage`.
2. If that page has visuals, upload them and rewrite the body in place. An attachment needs a content ID, so this only works after the page exists:
   ```bash
   python3 .claude/scripts/confluence-publish.py attach \
     --plan "workspace/tmp/confluence-{slug}/plan.json" \
     --page-index {i} --page-id {id} --account "{atlassian-email}"
   ```
   `--account` is the Atlassian account email; read it from `atlassianUserInfo` rather than guessing. Then update the page again with the rewritten body file. `attach` is re-runnable: it reuses an already-uploaded filename and retries anything still pending.
3. Append the ledger record for that page **as it lands**, so an interrupted fan-out leaves an accurate trail:
   ```bash
   python3 .claude/scripts/confluence-publish.py ledger-append \
     --source "{source}" --page-index {i} --page-id {id} --page-url "{url}" \
     --published-at "{ISO-8601}" --published-body-sha256 "{sha}" --format html
   ```

**Credential.** `attach` reads an Atlassian API token from the macOS keychain, falling back to `$CONFLUENCE_API_TOKEN` off macOS. Absent, it stops and prints both setup commands; relay them and let the user store the token. Never ask for the token in chat, never echo it, and never put it on a command line.

**Site.** `--site` defaults to the host in `workspace/config.md` → `## Jira` → `baseUrl`. Pass `--site` explicitly when publishing to a different Atlassian tenant.

**Title conflict.** Confluence titles are unique per space, so a create can fail on a page someone made by hand. Surface the error and the conflicting page and let the user pick update-or-rename. Never auto-append a `(2)` suffix - that is how duplicates accumulate.

**Orphans.** If `ledger-lookup` reported orphans, name them with their URLs. Never delete Confluence content.

## Step 7 - Report and clean up

Per `.claude/docs/skill-contract.md`: pointer plus ≤ 5 lines. Include the page URLs, and group any PNGs **by the page they attach to** - an attachment belongs to one page, so a flat list sends the reader to the wrong one. Then delete `workspace/tmp/confluence-{slug}/` so emitted bodies of a sensitive report do not reach the next backup.

Append a daily-log line per `.claude/docs/daily-log-format.md`.

## Notes

- Report any visual whose `status` is not `attached`; its placeholder panel is still on the page naming the PNG, so the reader is not left with a silent gap.
- Each placeholder carries a collapsed `Chart data (text)` expand. Keep it: it is the only searchable copy of the numbers once the chart becomes an image.
- `updateConfluencePage` replaces the whole body; this skill does not merge sections, and the confirm says so.
- Markdown passthrough cannot express panels, expands, or inline cards, and is never rasterized. Use an HTML source when charts or those constructs matter.

## Portability

Nothing here is pinned to one person or one organisation, so the skill can be shared as-is:

- The Atlassian host comes from `workspace/config.md`, never a hard-coded tenant.
- Step 4's KB rung resolves through `.domain-map.md` and is skipped when absent.
- The credential is read from the keychain or the environment; none is stored in the repo.
- `tests/scripts/test-confluence-publish.sh` is fixture-driven and needs no credentials, no network, and no `workspace/`.
- Chrome and `gitleaks` are optional: without Chrome a visual reports `skipped:no-renderer` and keeps its placeholder; without `gitleaks` say so in the confirm rather than claiming the source was scanned.
