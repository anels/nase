---
name: nase:publish-confluence
description: "Publish a local Markdown or HTML artifact to Confluence with tables, code, and charts preserved. Use for publish to Confluence, share this report, put this on the wiki, or a local report path."
argument-hint: "<path-to-md-or-html> [--space KEY] [--parent ID] [--rasterize-only CLASS]"
category: Reporting
---

Publish a finished local `.md`/`.html` artifact as a Confluence page, preserving structure and rendering charts that Confluence cannot express. Triggers: "publish to Confluence", "share this report on the wiki", "put this doc on Confluence", or a path to a local report.

**Input:** `$ARGUMENTS` - an absolute path to a local `.md` or `.html` file. Optional: `--title`, `--rasterize-only <class>`, `--no-rasterize`, `--rasterize <selector>`, all of which pass straight through to `confluence-publish.py plan`. Two more are consumed here rather than by the script: `--space KEY` and `--parent ID` pin the destination, so the targeting ladder skips its search rungs and the confirm presents that space and parent as the only candidate.

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/external-mutation-policy.md` - every Confluence write goes through draft-first plus an `AskUserQuestion` showing the concrete payload. Conversion rules live in `.claude/docs/confluence-publish-conversion.md`; format selection and ADF mechanics in `.claude/docs/confluence-adf-pattern.md`; the ledger write follows `.claude/docs/workspace-write-guard.md` (append-only exception).

## Step 1 - Input guard

If `$ARGUMENTS` has no readable file path, use `AskUserQuestion` to collect one. Do not guess a source. The file may live outside this workspace (a sibling repo's `workspace/reports/**` is normal); it is only ever read.

## Step 2 - Pre-publish gates (all block)

Run the two gates separately and branch on each exit code. The two use opposite conventions - `gitleaks` is clean on 0, `grep -l` is clean on 1 - so a single compound call cannot tell a finding from a clean run. Branch on `command -v` explicitly too, because `&&` collapses a missing binary onto the same exit code as a finding.

```bash
if command -v gitleaks >/dev/null; then
  gitleaks detect --no-git --source "{source}" --redact --no-banner; echo "gitleaks exit=$?"
else
  echo "gitleaks exit=absent"
fi
grep -l '\[CONFIDENTIAL' "{source}"; echo "confidential exit=$?"
```

`gitleaks` exit 0 is clean and 1 is a finding that stops the run; a **missing** `gitleaks` is neither, so say in the confirm that the source was not scanned rather than reporting it clean or treating the absence as a finding. For the marker, exit 0 means `[CONFIDENTIAL]` was found and stops the run, while exit 1 is the clean case. Report the redacted rule and line, never the value.

**Say plainly in the confirm that the scan is partial.** Verified: `gitleaks` flags `ghp_*` and `xoxb-*` but missed a SQL connection-string password in the same fixture. It is a lead, not a clean bill.

## Step 3 - Convert and measure

```bash
python3 .claude/scripts/confluence-publish.py plan \
  --source "{source}" --out-dir "workspace/tmp/confluence-{slug}"
```

**Scope what becomes an image.** With no flags, `plan` rasterizes every class the source lays out with `display: grid`, which cannot tell a bar chart from a grid-laid-out incident card - and an imaged card loses full-text search, copy-paste, and its inline links. Read the source's `<style>` and decide per grid class whether it is a chart container. Try jev first for that call (`jev-judgment-points.md` point `publish-confluence.is-chart-container`, `--type Noul`, yes = rasterize this class / no = convert it as HTML; state = the class name, its CSS rule, and the first 200 characters of one matching element's text content); confidence < 0.9 or unavailable → judge it yourself, where text content means prose and an `<svg>` or canvas means a chart. Pass `--rasterize-only <class>` (repeatable) naming just the chart containers so everything else converts to ordinary HTML. Report in the confirm how many visuals each choice produces.

Exit 3 = a single block exceeds the cap; exit 4 = a nesting construct Confluence rejects. Both name the cause - relay it and stop; do not restructure the user's document.

Exit 5 = a captured chart holds an `<svg>` that draws nothing, so it would publish as a blank rectangle: the capture pass runs with JavaScript disabled, and a chart drawn at page load has no shapes in the markup. Relay it and stop. The source has to emit its geometry at build time - `.claude/scripts/chart-svg.py` does that for treemaps and time-axis lines - and that is the author's change to make, not a conversion flag.

**Relay the font-stack warning.** `plan` warns when a stack ends in a family headless Chrome does not resolve (`ui-sans-serif`, `ui-serif`, `ui-monospace`, `-apple-system`, …): those charts publish in serif while the source looks sans-serif in a browser, so the author cannot see it without opening the PNG.

**Shaping is on by default.** `plan` rewrites in-page links to the heading anchors Confluence answers to, folds runs of consecutive side-notes into one collapsed `ℹ️ Note`, stamps table column widths from each column's own content, and mirrors a source's navigation sidebar as a collapsed `Table of Contents`. Turn any of it off with `--no-group-notes`, `--no-colwidth`, `--toc never`. `.claude/docs/confluence-publish-conversion.md → In-page links and anchors` and `→ Note runs, contents and table widths` carry the rules; do not hand-patch the emitted body to get these effects, because the next month's run would need the same patch again.

Read `plan.json` for `title`, `pages[]`, `split_differs_without_visuals`, and `warnings` - `plan` flags a captured block that draws nothing (prose about to become an image), a `--rasterize-only` class that matched nothing (a typo that images nothing at all), and in-page links dropped because their target is a paragraph anchor rather than a heading. Relay any of them in the confirm; all three otherwise look like a clean plan.

## Steps 4-5 - Find the target, then confirm once

Work `.claude/docs/confluence-publish-targeting.md`: the six-rung ladder that resolves the destination
page, and the single batched `AskUserQuestion` that presents target, create-or-update, page structure,
and visuals. Run the ladder to completion before asking - an early rung producing a candidate does not
stop it, because the confirm ranks all candidates and shows the runner-up. Do not publish anything
until that confirm returns.

## Step 6 - Publish

**Re-check the source first.** Compare its current size and mtime against what Step 3 planned from:

```bash
stat -f '%m %z' "{source}"   # Linux: stat -c '%Y %s'
```

Anything between Step 3 and here - a credential prompt, this confirmation, a conversion bug worth fixing - is time the author can spend editing the file. Verified: a run that planned at 18:46 published a page at 19:29 carrying the 18:44 text, and the author had rewritten four sections at 19:10. The page said what the report used to say. If the source moved, re-run Step 3 and re-confirm rather than publishing what you hold.

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
   `--account` is the Atlassian account email; read it from `atlassianUserInfo` rather than guessing. `attach` is re-runnable: it retries anything still pending, and refreshes a filename the page already carries instead of re-uploading it. **Then update the page again from the body file `attach` just rewrote** - a refresh mints a new media id, so a body assembled before `attach` ran points at the superseded version and the page renders the old chart while every status says `attached`.
3. Append the ledger record for that page **as it lands**, so an interrupted fan-out leaves an accurate trail:
   ```bash
   python3 .claude/scripts/confluence-publish.py ledger-append \
     --source "{source}" --page-index {i} --page-id {id} --page-url "{url}" \
     --published-at "{ISO-8601}" --published-body-sha256 "{sha}" --format html
   ```
   `--source` must be the **durable** artifact, even when you planned from a derived copy (a redaction-scrubbed sidecar, a hand-split file). Re-publishes key on that exact path, so a scratch key stops matching once tmp is cleaned and the next run re-creates the whole family beside the old one. `ledger-append` refuses a `workspace/tmp/` source for that reason; pass `--allow-transient-source` only for a throwaway probe page.

**Credential.** `attach` reads an Atlassian API token from the macOS keychain, falling back to `$CONFLUENCE_API_TOKEN` off macOS. Absent, it stops and prints both setup commands; relay them and let the user store the token. Never ask for the token in chat, never echo it, and never put it on a command line.

**Site.** `--site` defaults to the host in `workspace/config.md` → `## Jira` → `baseUrl`. Pass `--site` explicitly when publishing to a different Atlassian tenant.

**Title conflict.** Confluence titles are unique per space, so a create can fail on a page someone made by hand. Surface the error and the conflicting page and let the user pick update-or-rename. Never auto-append a `(2)` suffix - that is how duplicates accumulate.

**Orphans.** If `ledger-lookup` reported orphans, name them with their URLs. Never delete Confluence content.

## Step 7 - Report and clean up

Per `.claude/docs/skill-contract.md`: pointer plus ≤ 5 lines. Include the page URLs, and group any PNGs **by the page they attach to** - an attachment belongs to one page, so a flat list sends the reader to the wrong one. Then delete `workspace/tmp/confluence-{slug}/` so emitted bodies of a sensitive report do not reach the next backup.

Append a daily-log line per `.claude/docs/daily-log-format.md`.

## Notes

- Report any visual whose `status` is not `attached`; its placeholder panel is still on the page naming the PNG, so the reader is not left with a silent gap.
- A rasterized subtree leaves no text duplicate on the page; the image carries its own labels. That is why the Step 3 scope matters - whatever gets imaged stops being searchable.
- `updateConfluenceContent` replaces the whole body; this skill does not merge sections, and the confirm says so.
- Markdown passthrough cannot express panels, expands, or inline cards, and is never rasterized. Use an HTML source when charts or those constructs matter.

## Portability

Nothing here is pinned to one person or one organisation, so the skill can be shared as-is:

- The Atlassian host comes from `workspace/config.md`, never a hard-coded tenant.
- The targeting ladder's KB rung resolves through `.domain-map.md` and is skipped when absent.
- The credential is read from the keychain or the environment; none is stored in the repo.
- `tests/scripts/test-confluence-publish.sh` is fixture-driven and needs no credentials, no network, and no `workspace/`.
- Chrome and `gitleaks` are optional: without Chrome a visual reports `skipped:no-renderer` and keeps its placeholder; without `gitleaks` say so in the confirm rather than claiming the source was scanned.
