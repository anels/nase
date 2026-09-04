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
| `Platform_Cost_Report-2026-07.html` | 40 720 B (34 581 B without placeholders) | 1 | 11 |
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
| `svg` **with a `viewBox`** | rasterize → placeholder panel naming the PNG |
| any element whose class the source lays out with `display: grid`, or a class named by `--rasterize-only` | rasterize the whole subtree, same placeholder |
| class matching `bar\|bars\|track\|spark\|sparkline\|meter\|gauge` | **dropped** - decorative, and counted in `dropped_chart_subtrees` |
| `svg` without a `viewBox`, `[aria-hidden=true]`, `style`, `script`, `head`, `nav`, `footer`, `canvas`, `button`, `select`, `textarea`, `form`, `dialog`, `noscript`, `template` | dropped |
| `b` / `i` | `strong` / `em` - the presentational spellings of emphasis, aliased rather than unwrapped |
| any other `div`/`span`/`section`/`article`/`main`/`header`/`aside`/`figure`/`figcaption` | unwrapped, children kept |
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
over `Platform_Cost_Report-2026-07.html` finds 12 `<svg>`; the twelfth is the literal text
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

## Implicit paragraphs

Unwrapping a grid container leaves its text and its inline elements at block level, where
Confluence has to wrap each one in a paragraph of its own. A sentence like
`so <code>first_name</code> and <code>user_attributes</code> landed` then ships as five
separate paragraphs, and the reader sees it shattered into one-word lines. Measured on the
published `effort-rollup-2026-08` page, which is why
`tests/fixtures/confluence-publish/inline-run.html` exists.

Rule: in the page body and inside a panel - the two places ADF puts block content directly -
the emitter keeps **one** implicit paragraph open across a run of bare inline content instead
of closing a paragraph per run.

- `INLINE_PASSTHROUGH` (`strong em code a br`) opens the implicit paragraph and stays inside it.
- Any other tag closes it first, so a heading or a table never lands inside a paragraph.
- `UNWRAP_INLINE` (`span`, `small`, `abbr`, `sup`, `sub`, `mark`, `time`, `del`, `ins` and the
  rest of the unwrapped inline set) is the exception at both ends: an inline wrapper neither
  opens nor closes the paragraph its siblings share. Closing on `</span>` puts a label/value
  strip back to one line per piece, and closing on `</small>` splits the sentence carrying it.
- Every other unwrapped wrapper is block-level and ends the paragraph on the way **in** as
  well as on the way out. Only closing it leaves `<span>Draft</span><div>Body</div>` welded
  into one paragraph while the same pair in the other order splits correctly.
- Only the paragraph's **first** run is left-trimmed. The trailing space before an inline
  `<code>` is load-bearing; trimming every run welds `so` onto `first_name`.
- A paragraph that ends up holding nothing but whitespace - a wrapper that held only another
  wrapper - is deleted rather than shipped empty.
- `close()` flushes a paragraph the document ended inside, and `begin_capture` closes one
  before a rasterized subtree opens.
- A panel's own paragraph is closed before its `</div>` is examined. Leaving it open hides
  the `panel` marker under it, the panel never closes, and the **next** panel then reads as a
  panel nested inside it - `plan` exits 4 on a document that is actually valid.
- Only body-level content starts a splittable block. A paragraph inside a panel belongs to
  the block the panel already opened, or a page split can land mid-panel.

This does not resolve a block-level pair the source drew with a grid: a KPI board whose value
and label are separate `<div>`s still converts to two paragraphs, because both are block-level.
Rasterize that class instead of reaching for a semantic guess.

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

   The heuristic is deliberately blunt and over-collects: `display: grid` is as true of an
   incident card or a themes index as of a bar chart, and imaging prose costs the reader
   full-text search, copy-paste, and working links inside it. `--rasterize-only <class>`
   (repeatable) replaces the heuristic with an explicit scope, so a report names its chart
   containers and every other grid block converts to ordinary HTML. Prefer it on any source
   whose visual language is mostly layout: a report with five bar groups and six grid-laid-out
   prose sections otherwise ships as eleven images.

   Two `warnings` keep that choice from failing silently, because both failure modes look like
   a clean plan: a captured subtree holding no bar, track, meter or inline `svg` is reported as
   prose-being-imaged, and a `--rasterize-only` class that matched nothing is reported as a
   probable typo - that one images nothing at all while `CHART_CLASS` still drops the real bars,
   leaving label soup where the chart was.

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

A rasterized subtree leaves **no text duplicate** on the page - the image already carries the
labels a reader needs, and a second copy of the same numbers under every chart is clutter on
every page view.

The cost of that is verified by CQL: a phrase existing only inside a rasterized subtree does
not come back on a full-text search, and a PNG says nothing to a screen reader. For a bar chart
that phrase is a label the image shows anyway. For an incident card, a corrections list, or a
themes index it is the whole content - scope the capture instead (`--rasterize-only`, above).

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
- Re-runs are safe in both directions: anything not yet `attached` is retried without
  hand-editing the plan, and a filename the page already carries is **refreshed in place**
  (`POST .../child/attachment/{attachmentId}/data`) rather than re-uploaded, because Confluence
  refuses a second attachment under the same name. Chart filenames are positional
  (`chart-01.png`), so a re-publish whose charts moved reuses every name with new content -
  trusting the name and skipping the refresh is how a page renders last month's chart under
  this month's caption.
- **A refresh mints a new `fileId`**, verified against the live API, so the body must be
  updated from the file `attach` rewrote *after* it ran. Reusing the id read from the
  attachment listing embeds the superseded version: bytes current, page stale, status
  `attached`.
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
