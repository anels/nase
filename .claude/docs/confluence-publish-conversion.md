# Confluence Publish - Conversion Contract

## Contents

- Scope
- Measured baselines
- Formats and thresholds
- HTML → HTML+ mapping
- Void elements
- Self-closing tags
- The whitespace rule
- Nesting violations: detect, do not rewrite
- Rasterization
- Attaching the images
- Splitting
- The publication ledger
- What markdown cannot express

Owned by `/nase:publish-confluence`; the script that implements it is
`.claude/scripts/confluence-publish.py`. Format-selection rules and ADF mechanics stay in
`.claude/docs/confluence-adf-pattern.md`.

---

## Scope

Converts a finished local `.md`/`.html` artifact into Confluence page bodies. It does not
author, summarize, or restyle content.

`plan` and `render` never touch the network, which is what lets
`tests/scripts/test-confluence-publish.sh` run without credentials. `attach` is the one
networked subcommand, and it never calls the Atlassian MCP either - attachment upload exists
only on Confluence REST v1.

| Subcommand | Does |
|---|---|
| `plan` | parse, classify visuals, emit page bodies, measure, split |
| `render` | rasterize the captured charts and layout blocks to PNG |
| `attach` | upload the PNGs and swap each placeholder for a media node |
| `ledger-append` | record one published page |
| `ledger-lookup` | resolve create/update per page for a re-publish |

## Measured baselines

Measured 2026-08-19 against real reports. These live under a git-ignored `workspace/` and
are **not** in the repo, so they are historical evidence rather than a runnable check - the
runnable regressions are in `tests/fixtures/confluence-publish/`. On the same inputs, expect
`plan` to land within **+3 %**; investigate a deviation beyond **±10 %**.

| Source | Emitted | Pages | Visuals |
|---|---|---|---|
| `retro-q2-2026-share.html` | 30 569 B (23 657 B without placeholders) | 1 | 7 |
| `Insights_Cost_Report-2026-07.html` | 40 720 B (34 581 B without placeholders) | 1 | 11 |
| `effort-rollup-2026-07.html` | 133 893 B (119 338 B without placeholders) | 4 | 11 |
| `tech-digest-2026-08-09.md` | 14 116 B | 1 | 0 |

Every visual in all three HTML reports is a **grid block**, not a bare `<svg>`: these reports
wrap their charts in a CSS-grid container, and the container is captured first, so the `<svg>`
inside it never reaches the SVG path. `tests/fixtures/confluence-publish/chart-viewbox.html` is
what keeps the bare-SVG path covered.

**Format ratio** (measured on one scratch page, identical content posted in each format): markdown is
**0.668 ×** the bytes of HTML+. An at-cap markdown body therefore carries ~1.5 × more
content, and expands correspondingly further into storage format.

## Formats and thresholds

`.claude/hooks/confluence-size-guard.sh` caps any page body at **60 000 bytes** and accepts
`adf`, `html`, `markdown`. Split thresholds leave headroom under that cap:

| Kind | `contentFormat` | Threshold | Why |
|---|---|---|---|
| `.html` | `html` (Confluence HTML+) | 55 000 | 5 KB headroom under the cap. |
| `.md` | `markdown` (passthrough) | 35 000 | Derived from the 0.668 ratio (equivalent point is 37 000), rounded down for margin. |

## HTML → HTML+ mapping

Rules are applied in this order; the first match wins.

| Source | Emitted |
|---|---|
| `h1`-`h6` | same; a leading `h1` matching the page title has **the element** stripped, never the block |
| `p`, `strong`, `em`, `code` | same |
| `a[href]` matching `…atlassian.net/browse/KEY-123` | `<a href … data-card-appearance="inline">` → renders as a real Jira macro |
| `a` (other) | plain `<a href>` |
| `table`/`thead`/`tbody`/`tr`/`th`/`td` | same; `colspan`/`rowspan` > 1 preserved |
| `ul`/`ol`/`li`, nested | same |
| `blockquote` | same |
| `pre > code[class*="language-X"]` | `<pre><code class="language-X">`; inner markup flattened to escaped text |
| `details` / `summary` | same → `expand` macro |
| `div` whose class matches `warn\|caution` / `bad\|crit\|error\|danger` / `good\|ok\|success\|pass` / `note\|callout\|aside` | `<div data-type="panel-warning\|panel-error\|panel-success\|panel-note">`, first match wins in that order |
| `svg` **with a `viewBox`** | rasterize → placeholder panel + `Chart data (text)` expand |
| any element whose class the source lays out with `display: grid` | rasterize the whole subtree, same placeholder |
| class matching `bar\|bars\|track\|spark\|sparkline\|meter\|gauge` | **dropped** - decorative, and counted in `dropped_chart_subtrees` |
| `svg` without a `viewBox`, `[aria-hidden=true]`, `style`, `script`, `head`, `nav`, `footer`, `canvas`, `button`, `select`, `textarea`, `form`, `dialog`, `noscript`, `template` | dropped |
| any other `div`/`span`/`section`/`article`/`main`/`header`/`aside`/`figure`/`figcaption`/`i`/`b` | unwrapped, children kept |
| any remaining unknown tag | unwrapped, children kept |

Interactive chrome is in the drop list for a reason: an export menu unwraps into loose
paragraphs reading `Dark`, `Download PNG`, `Copy to clipboard` at the top of the page.

Every `class` is stripped except `language-*`. Entities are decoded on parse and re-escaped
on emit - chart text is sliced from raw markup, so it is unescaped first or `&bull;` ships as
`&amp;bull;`. No `data-local-id` is ever invented. A page body is never allowed to open with a
stranded `<hr>`, which is what a separator inside a dropped container leaves behind.

**Title resolution**: `--title` → `<title>` → first `<h1>` → source filename stem. Markdown
resolves from the leading `# Title`. Titles are clamped to 255 chars, heading fragments to 60.

**Count anything only after `<style>`, `<script>`, and comments are stripped.** A raw regex
over `Insights_Cost_Report-2026-07.html` finds 12 `<svg>`; the twelfth is the literal text
`<svg>` inside a CSS comment.

## Void elements

`area base br col embed hr img input link meta param source track wbr` - `br`/`hr` are
emitted, the rest dropped, and **none of them ever pushes the element stack**.

`html.parser` reports a starttag and never an endtag for these. A depth counter that trips
on `<meta charset="utf-8">` never leaves `<head>` and the emitter produces **an empty
document** - measured, not hypothesized. `tests/fixtures/confluence-publish/void-elements.html`
is the regression.

## Self-closing tags

`<div/>`, `<svg/>`, `<i/>` get a starttag callback and no endtag, exactly like a void element,
but they are *not* void - so a rule that opens a dropped subtree, a rasterization capture, or a
stack entry on them leaves that state open forever.

The drop counter is the dangerous one. `<button><i class="icon"/></button>` leaves it at 1 after
the `</button>`, so **every element in the rest of the document is silently discarded and `plan`
still exits 0**. Measured against the pre-fix script on
`tests/fixtures/confluence-publish/self-closing.html`: 5 of 8 content elements vanished,
including two whole `<h2>` sections, with no warning.

Rule: a self-closing tag must leave the parser exactly as it found it. Whatever
`handle_starttag` opened is closed or rolled back before the next token.

## The whitespace rule

Unwrapping inline elements concatenates their text, because the source relied on CSS gaps:
`<span>1,643,173</span><span>-&gt;</span>` would weld into one run.

Rule: unwrapping records that a separator *may* be needed; the next text decides. Emitting
the space eagerly doubles it whenever the following run already begins with whitespace,
which corrupts `<pre>` content.

## Nesting violations: detect, do not rewrite

The MCP rejects these outright. `plan` **exits 4** naming the construct and its heading
context; it never restructures the author's document.

- heading / table / expand inside a list item
- table / expand / blockquote / panel inside a panel
- table inside a table cell

None occurs in any real source measured, so four transformations would first execute on
someone's real report - and a wrong transformation ships a quietly mangled page where a
clear error would not. Add a repair only when a real document forces one, with that
document as its fixture.

## Rasterization

Two things are captured whole and screenshotted rather than converted:

1. **`<svg>` carrying a `viewBox`.** Dimensions come from the `viewBox`, because the source's
   CSS cannot be trusted for sizing: 8 of the cost report's SVGs carry no `width`/`height` and
   are sized by `.charts svg { width:1040px }`, which dies the moment the element leaves its
   ancestor chain.
2. **Any subtree whose class the source lays out with `display: grid`.** KPI boards,
   before/after cards, incident grids: the meaning lives in the two-dimensional placement, not
   in the markup, so unwrapping them to semantic HTML yields paragraph soup. `plan` reads the
   source's own `<style>` blocks to learn which classes those are - no selector list to
   maintain. `--no-rasterize` turns this off and takes the unwrapped content instead.

`render` writes a standalone document per visual carrying the source `<style>`, and invokes
Chrome through `subprocess` with an argv list - not through Bash, which
`external-cli-write-guard.sh` fails closed on for unparseable command strings.

- **Light palette is forced.** `<html data-theme="light">` alone is not enough: a report whose
  `@media (prefers-color-scheme: dark)` block is unguarded still follows the browser
  preference, and headless Chrome may report dark. That media query is rewritten to
  `@media not all{` for the screenshot only, never written back to the source.
- **Height is measured, not guessed.** Chrome screenshots a viewport, not an element, so a
  first pass loads the document with JavaScript enabled and reports the block's
  `getBoundingClientRect().height` back through `document.title`. Measuring
  `documentElement.scrollHeight` instead gives every PNG a tail of blank page.
- **PNGs land at 2 ×** via `--force-device-scale-factor=2`. The media node declares the
  logical size and doubled pixel dimensions, so the image stays sharp on a retina display.
- `--disable-javascript` is set on the capture pass; these charts are static.

Chrome is optional. Per-visual `status` ends at `rendered`, or one of `skipped:no-renderer`,
`skipped:unmeasurable`, `skipped:render-timeout`, `skipped:no-output` - and either way the
placeholder still says what to attach.

Each placeholder is followed by a collapsed `Chart data (text)` expand carrying the visual's
text nodes (skipped under 20 characters). This is load-bearing for search, not a courtesy:
Verified by CQL: a phrase that appears only inside a chart returns its page on a full-text
search because the expand carries it, and returns nothing once the expand is removed. It also keeps the numbers reachable for screen
readers, which a PNG is not.

## Attaching the images

Confluence exposes attachment upload **only** on REST v1
(`POST /wiki/rest/api/content/{id}/child/attachment`): the Atlassian MCP has no attachment
tool, REST v2 is GET/DELETE only, and `acli confluence page` exposes only `view`. So `attach`
is the one subcommand that authenticates and writes over the network.

- The API token is read from the macOS keychain (`security find-generic-password`, service
  `nase-confluence` by default), falling back to `$CONFLUENCE_API_TOKEN` where `security` does
  not exist. The keychain wins when both are set, so a stale export cannot shadow the real
  token. It is never passed on a command line, never written to `plan.json`, and never
  printed - including in the not-found error.
- The Atlassian host comes from `--site`, or from `workspace/config.md` → `## Jira` →
  `baseUrl`. No organisation is hard-coded, so the script is shareable as-is.
- The page must exist first - an attachment needs a content ID - so the order is create the
  page, then `attach`, then update the page with the returned body.
- Placeholders are matched on the **PNG filename**, which is the only part of the panel that
  survives a re-plan unchanged.
- Re-runs are safe in both directions: the page's existing attachments are read first and an
  already-uploaded filename reuses its `fileId` instead of creating a second version, while
  anything not yet `attached` is retried without hand-editing the plan.
- Failures are per-visual and named: `attach-failed:missing-png`, `attach-failed:http-{code}`,
  `attach-failed:no-media-id`, `attach-failed:placeholder-not-found`. `attach` exits 1 if any
  pending visual did not land.

## Splitting

Break at `h2`; re-break any still-oversized page at `h3`; then at any block boundary.

Heading boundaries alone are not enough: one `h2` section of `effort-rollup-2026-07.html`
carries **90 855 B - 65 % of the document - with a single `h3` inside it**. A
paragraph-boundary break loses no content. Only a single block larger than the cap is
genuinely unsplittable, and that exits **3**, naming the block size so the author knows a
long table or code listing is the cause.

Page 0 carries real content and is the parent; pages 1..N are its children. A page with no
heading of its own continues the last heading as `… - {heading} (cont. N)` rather than
degrading to `part N`.

Publish order is parent → children, because a child needs its parent's ID. Attachments belong
to one page (`data-collection="contentId-{pageId}"`), so the report groups PNGs by page URL.

## The publication ledger

`workspace/confluence-publications.jsonl`, append-only, one record per page as it lands.

`ledger-lookup` keys on **`(source_path, page_index)`**. Keying on `source_path` alone would
resolve a run that died after child 2 of 4 to a single parent update and silently lose the
tail. It returns a per-page `create`/`update` action, the prior `published_body_sha256` for
drift detection, any `orphans` a shrinking split stranded (reported, never deleted), and the
prior month's page family matched by filename stem.

## What markdown cannot express

Measured on the round-trip: markdown passthrough **cannot** produce panels, expands, or
inline cards - a markdown Jira link stays a plain `<a href>` where the HTML+ path yields a
Jira macro. Reading a page back as markdown is lossy in the same way, and additionally drops
a `colspan` cell. Use `html` whenever those constructs matter.

Markdown sources are also not rasterized: there is no `<style>` to read layout classes from
and no inline SVG to capture. A markdown document with charts should be an HTML document.
