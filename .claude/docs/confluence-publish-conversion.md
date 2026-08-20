# Confluence Publish — Conversion Contract

## Contents

- Scope
- Measured baselines
- Formats and thresholds
- HTML → HTML+ mapping
- Void elements
- The whitespace rule
- Nesting violations: detect, do not rewrite
- Rasterization
- Splitting
- The publication ledger
- What markdown cannot express

Owned by `/nase:publish-confluence`; the script that implements it is
`.claude/scripts/confluence-publish.py`. Format-selection rules and ADF mechanics stay in
`.claude/docs/confluence-adf-pattern.md`.

---

## Scope

Converts a finished local `.md`/`.html` artifact into Confluence page bodies. It does not
author, summarize, or restyle content, and it never calls the Atlassian MCP — that boundary
is what lets `tests/scripts/test-confluence-publish.sh` run without credentials.

## Measured baselines

Measured 2026-08-19 against the real sources; treat these as regression targets. Expect
`plan` to land within **+3 %**; investigate a deviation beyond **±10 %** rather than
accepting it.

| Source | Emitted | Pages | Charts |
|---|---|---|---|
| `retro-q2-2026-share.html` | 29 919 B | 1 | 0 |
| `Insights_Cost_Report-2026-07.html` | 40 793 B (34 625 B without placeholders) | 1 | 11 |
| `effort-rollup-2026-07.html` | 140 566 B | 4 | 0 (25 chart-class subtrees dropped) |
| `tech-digest-2026-08-09.md` | 14 116 B | 1 | 0 |

**Format ratio** (page `91035828253`, identical content in each format): markdown is
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

| Source | Emitted |
|---|---|
| `h1`–`h6` | same; a leading `h1` matching the page title has **the element** stripped, never the block |
| `p`, `strong`, `em`, `code` | same |
| `a[href]` matching `…atlassian.net/browse/KEY-123` | `<a href … data-card-appearance="inline">` → renders as a real Jira macro |
| `a` (other) | plain `<a href>` |
| `table`/`thead`/`tbody`/`tr`/`th`/`td` | same; `colspan`/`rowspan` > 1 preserved |
| `ul`/`ol`/`li`, nested | same |
| `blockquote` | same |
| `pre > code[class*="language-X"]` | `<pre><code class="language-X">`; inner markup flattened to escaped text |
| `details` / `summary` | same → `expand` macro |
| `div` whose class matches `warn\|caution` / `bad\|crit\|error\|danger` / `good\|ok\|success\|pass` / `note\|callout\|aside` | `<div data-type="panel-warning\|panel-error\|panel-success\|panel-note">`, first match wins in that order |
| `svg` **with a `viewBox`**, `canvas` | rasterize → placeholder panel + `Chart data (text)` expand |
| class matching `bar\|bars\|track\|spark\|meter\|gauge` | **dropped** — decorative |
| `svg` without a `viewBox`, `[aria-hidden=true]`, `style`, `script`, `head`, `nav`, `footer` | dropped |
| any other `div`/`span`/`section`/`article`/`figure`/`i`/`b` | unwrapped, children kept |

Every `class` is stripped except `language-*`. Entities are decoded on parse and re-escaped
on emit. No `data-local-id` is ever invented.

**Title resolution**: `--title` → `<title>` → first `<h1>` → source filename stem. Markdown
resolves from the leading `# Title`. Titles are clamped to 255 chars, heading fragments to 60.

**Count anything only after `<style>`, `<script>`, and comments are stripped.** A raw regex
over `Insights_Cost_Report-2026-07.html` finds 12 `<svg>`; the twelfth is the literal text
`<svg>` inside a CSS comment.

## Void elements

`area base br col embed hr img input link meta param source track wbr` — `br`/`hr` are
emitted, the rest dropped, and **none of them ever pushes the element stack**.

`html.parser` reports a starttag and never an endtag for these. A depth counter that trips
on `<meta charset="utf-8">` never leaves `<head>` and the emitter produces **an empty
document** — measured, not hypothesized. `tests/fixtures/confluence-publish/void-elements.html`
is the regression.

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
someone's real report — and a wrong transformation ships a quietly mangled page where a
clear error would not. Add a repair only when a real document forces one, with that
document as its fixture.

## Rasterization

Only `<svg>` carrying a `viewBox`, plus `<canvas>`.

The source's CSS cannot be trusted for sizing: 8 of the cost report's SVGs carry no
`width`/`height` and are sized by `.charts svg { width:1040px }`, which dies the moment the
element leaves its ancestor chain. Dimensions therefore come from the `viewBox` and are
written onto the hoisted element. PNGs land at `viewBox × 2`.

`render` writes a standalone document carrying the source `<style>`, forces
`<html data-theme="light">` (the reports are theme-aware and would otherwise render dark
against Confluence's light page), and invokes Chrome through `subprocess` with an argv list
— not through Bash, which `external-cli-write-guard.sh` fails closed on for unparseable
command strings. `--disable-javascript` is set; these charts are static SVG.

Chrome is optional: absent → `skipped:no-renderer`, 30 s timeout → `skipped:render-timeout`.
Either way the placeholder still says what to attach.

Each placeholder is followed by a collapsed `Chart data (text)` expand carrying the SVG's
text nodes (skipped under 20 characters). The cost report's 11 charts hold **4 031
characters** of axis labels, months, dollar values and deltas; rasterizing without the
expand makes all of it unsearchable and invisible to screen readers, and the page shows
nothing but a filename until someone manually attaches the PNG.

## Splitting

Break at `h2`; re-break any still-oversized page at `h3`; then at any block boundary.

Heading boundaries alone are not enough: one `h2` section of `effort-rollup-2026-07.html`
carries **90 855 B — 65 % of the document — with a single `h3` inside it**. A
paragraph-boundary break loses no content. Only a single block larger than the cap is
genuinely unsplittable, and that exits **3**, naming the block size so the author knows a
long table or code listing is the cause.

Page 0 is the parent index. A page with no heading of its own continues the last heading as
`… — {heading} (cont. N)` rather than degrading to `part N`.

Publish order is parent → children → parent link-list update, because a child needs its
parent's ID. Attachments belong to one page (`data-collection="contentId-{pageId}"`), so the
report groups PNGs by page URL.

## The publication ledger

`workspace/confluence-publications.jsonl`, append-only, one record per page as it lands.

`ledger-lookup` keys on **`(source_path, page_index)`**. Keying on `source_path` alone would
resolve a run that died after child 2 of 4 to a single parent update and silently lose the
tail. It returns a per-page `create`/`update` action, the prior `published_body_sha256` for
drift detection, any `orphans` a shrinking split stranded (reported, never deleted), and the
prior month's page family matched by filename stem.

## What markdown cannot express

Measured on the round-trip: markdown passthrough **cannot** produce panels, expands, or
inline cards — a markdown Jira link stays a plain `<a href>` where the HTML+ path yields a
Jira macro. Reading a page back as markdown is lossy in the same way, and additionally drops
a `colspan` cell. Use `html` whenever those constructs matter.
