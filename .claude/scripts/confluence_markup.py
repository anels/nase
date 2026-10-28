#!/usr/bin/env python3
"""Convert a local Markdown/HTML artifact into Confluence-ready page bodies.

Subcommands:

    plan            parse, classify visuals, emit page bodies, measure, split
    render          rasterize the captured charts and layout blocks
    attach          upload the PNGs and swap placeholders for media nodes
    ledger-append   record one published page
    ledger-lookup   resolve create/update per page for a re-publish

`plan` owns the split because it owns the measurement. Emitting needs no
browser, so it produces the real bodies and splits on real bytes; a split
computed from an estimate and only checked later would let a user confirm
"single page" and then hard-fail with no re-split path.

`plan` and `render` never touch the network, which is what lets
tests/scripts/test-confluence-publish.sh run without credentials. `attach` is
the one networked subcommand: Confluence exposes attachment upload only on
REST v1, so it cannot go through the Atlassian MCP.

See .claude/docs/confluence-publish-conversion.md for the mapping contract.
"""

from __future__ import annotations

import os
import re
from html import unescape

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

EXIT_OVERSIZE = 3
EXIT_NESTING = 4
EXIT_BLANK_VISUAL = 5
# A keychain lookup that has not answered in this long is waiting on a GUI prompt,
# not on disk.
KEYCHAIN_TIMEOUT_SECONDS = 15

CAP_BYTES = 70000
DEFAULT_THRESHOLD = {"html": 55000, "markdown": 35000}

# html.parser reports a starttag and never an endtag for these, so counting them
# as nesting leaves the element stack permanently unbalanced. A depth counter
# that trips on `<meta charset="utf-8">` never leaves <head> and emits nothing.
VOID = frozenset(
    [
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    ]
)

PASSTHROUGH = frozenset(
    [
        "p",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "strong",
        "em",
        "code",
        "table",
        "thead",
        "tbody",
        "tr",
        "th",
        "td",
        "ul",
        "ol",
        "li",
        "blockquote",
        "pre",
        "details",
        "summary",
        "a",
    ]
)

# Elements that belong inside a paragraph rather than beside one. Emitting one
# of these at block level makes Confluence wrap it in a paragraph of its own,
# which is how a sentence carrying inline <code> ends up shattered into
# one-word lines.
INLINE_PASSTHROUGH = frozenset(["strong", "em", "code", "a", "br"])

DROP_TREE = frozenset(
    [
        "style",
        "script",
        "head",
        "nav",
        "footer",
        "canvas",
        "svg",
        "button",
        "select",
        "textarea",
        "form",
        "dialog",
        "noscript",
        "template",
    ]
)

UNWRAP = frozenset(
    [
        "div",
        "span",
        "section",
        "article",
        "main",
        "header",
        "aside",
        "figure",
        "figcaption",
    ]
)

# Unwrapped wrappers that are inline. They neither open nor close the implicit
# paragraph their siblings share: closing on `</span>` puts a label/value strip
# back to one line per piece, and closing on `</small>` splits the sentence that
# carries it. Every other unwrapped wrapper is block-level and does both.
UNWRAP_INLINE = frozenset(
    [
        "span",
        "small",
        "abbr",
        "sup",
        "sub",
        "mark",
        "kbd",
        "samp",
        "var",
        "time",
        "cite",
        "q",
        "u",
        "s",
        "strike",
        "big",
        "tt",
        "del",
        "ins",
        "label",
        "font",
        "nobr",
        "data",
        "dfn",
        "output",
        "bdi",
        "bdo",
    ]
)

# `<b>`/`<i>` are the presentational spellings of emphasis. Unwrapping them threw
# the emphasis away, which is what left a metadata strip's labels
# indistinguishable from its values once the grid was gone.
TAG_ALIAS = {"b": "strong", "i": "em"}

CHART_CLASS = re.compile(
    r"(?:^|[\s-])(bar|bars|track|spark|sparkline|meter|gauge)(?:$|[\s-])"
)

SVG_ELEMENT = re.compile(r"<svg\b[^>]*>(.*?)</svg>", re.IGNORECASE | re.DOTALL)
SVG_SELF_CLOSING = re.compile(r"<svg\b[^>]*/>", re.IGNORECASE)
SVG_DRAWS = re.compile(
    r"<(?:path|rect|circle|ellipse|line|polyline|polygon|text|textPath|image|use"
    r"|foreignObject)\b",
    re.IGNORECASE,
)

# Measured in headless Chrome 153 on macOS: these six families resolve on their
# own. `ui-sans-serif`, `ui-serif`, `ui-monospace`, `ui-rounded`, `math` and the
# `-apple-system` vendor keyword all fall back to the serif default instead, so a
# stack that ends in one of them publishes a serif chart from a sans-serif source
# and looks correct in the authoring browser the whole time.
RESOLVING_GENERIC = frozenset(
    {"serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui"}
)
FONT_DECL = re.compile(r"(?<![-\w])(?:font-family|font)\s*:\s*([^;}]+)", re.IGNORECASE)
CSS_WIDE = frozenset({"inherit", "initial", "unset", "revert", "revert-layer"})
STYLE_ELEMENT = re.compile(r"<style[^>]*>(.*?)</style>", re.DOTALL)
STYLE_ATTR = re.compile(r"""style=["']([^"']*)["']""")
CUSTOM_PROP = re.compile(r"(--[a-z0-9_-]+)\s*:\s*([^;}]+)", re.IGNORECASE)
VAR_REF = re.compile(r"var\(\s*(--[a-z0-9_-]+)\s*(?:,([^()]*))?\)", re.IGNORECASE)
PANEL_CLASS = (
    ("panel-warning", re.compile(r"(?:^|[\s-])(warn|warning|caution)(?:$|[\s-])")),
    (
        "panel-error",
        re.compile(r"(?:^|[\s-])(bad|crit|critical|error|danger)(?:$|[\s-])"),
    ),
    ("panel-success", re.compile(r"(?:^|[\s-])(good|ok|success|pass)(?:$|[\s-])")),
    ("panel-note", re.compile(r"(?:^|[\s-])(note|callout|aside)(?:$|[\s-])")),
)
JIRA_URL = re.compile(r"https://[a-z0-9-]+\.atlassian\.net/browse/[A-Z][A-Z0-9]+-\d+")
LANGUAGE_CLASS = re.compile(r"(?:^|\s)language-([A-Za-z0-9+#-]+)")

HEADINGS = ("h1", "h2", "h3", "h4", "h5", "h6")

# Constructs the MCP rejects outright. Detected and reported, never rewritten:
# no real source triggers any of them, so four untested transformations would
# first execute on someone's report, and a wrong transformation ships a quietly
# mangled page where a clear error would not.
NESTING_RULES = (
    ("li", ("table", "details", *HEADINGS), "heading/table/expand inside a list item"),
    (
        "panel",
        ("table", "details", "blockquote", "panel"),
        "table/expand/blockquote/panel inside a panel",
    ),
    ("cell", ("table",), "table inside a table cell"),
)

DEFAULT_CONTENT_WIDTH = 1080

# Confluence's default page measure. A page set to wide or max is the author's
# call in the UI; the converter sizes against the measure every page starts at.
DEFAULT_TABLE_WIDTH = 760

# One `selector { body }` pair. Neither half may contain a brace, which is what
# keeps a rule from being read across its own boundary and makes an `@media`
# wrapper fail to match while the rules nested inside it still do.
CSS_RULE = re.compile(r"([^{}]+)\{([^{}]*)\}")
# A class selector, anchored on a character an identifier may actually start
# with. Anchoring on `[a-z0-9_-]` instead is what let the `.5` in a preceding
# `font: 15px/1.5` pass as a class name.
CLASS_IN_SELECTOR = re.compile(r"\.(-?[_a-z][_a-z0-9-]*)", re.IGNORECASE)
CSS_STRING = re.compile(r"""("[^"]*"|'[^']*')""")
CLASS_ATTR = re.compile(r"""class=["']([^"']*)["']""")


def layout_classes(source: str) -> set[str]:
    """Classes the source lays out with CSS grid.

    These carry the report's visual language - KPI boards, before/after cards,
    incident grids - and unwrapping them to semantic HTML yields paragraph soup,
    because the meaning lives in the two-dimensional placement, not the markup.
    They are rasterized instead.

    Discovery reads whole rules rather than scanning for a dot, because a class
    missed here is a silent total loss: the container is not captured, then
    `CHART_CLASS` drops the bars inside it, and `--rasterize-only <class>`
    reports the author's correct class as matching nothing. Every selector in a
    grid rule counts, so `.a, .b { display: grid }` registers both.

    Quoted strings are stripped from the selector first: a dot inside an
    attribute value (`[data-version="1.5"]`) is not a class.
    """
    found = set()
    for style in STYLE_ELEMENT.findall(source):
        for selector, body in CSS_RULE.findall(style):
            if not re.search(r"display:\s*grid", body):
                continue
            bare = CSS_STRING.sub(" ", selector)
            found |= {name.lower() for name in CLASS_IN_SELECTOR.findall(bare)}
    return found


def has_chart_primitive(markup: str) -> bool:
    """Whether a captured subtree contains anything that draws.

    No bar, track, meter or inline svg means the block is prose that merely
    happens to be laid out with CSS grid, and rasterizing prose costs the page
    full-text search - so `plan` warns instead of imaging it silently.
    """
    if "<svg" in markup:
        return True
    return any(CHART_CLASS.search(value) for value in CLASS_ATTR.findall(markup))


def blank_svg_count(markup: str) -> int:
    """How many `<svg>` elements in a captured subtree draw nothing at all.

    The capture pass runs with `--disable-javascript`, so a chart whose shapes
    are added at page load is an empty `<svg>` in the markup and images as a
    blank rectangle - while `render` still reports `rendered` and `plan` reports
    no warning, because the subtree does hold an inline `<svg>`. Markup is the
    only place this is visible before the blank PNG reaches a published page.

    A nested `<svg>` closes the outer match early, so a chart built from nested
    SVG is judged on its innermost element. That direction is safe: the outer
    element is then never counted as blank.
    """
    empty = sum(1 for inner in SVG_ELEMENT.findall(markup) if not SVG_DRAWS.search(inner))
    return empty + len(SVG_SELF_CLOSING.findall(markup))


def unresolving_font_stacks(source: str) -> list[str]:
    """Font stacks that end in a family headless Chrome does not resolve.

    Only matters for a source that gets rasterized: the text path takes
    Confluence's own fonts, but a captured chart carries whatever the screenshot
    resolved. A stack with no generic terminator - or one terminated by a
    `ui-*` keyword - renders serif in the PNG and sans-serif in the browser the
    chart was authored in, so nothing short of opening the image reveals it.

    Every report here spells its stacks as `font-family: var(--sans)`, so a check
    that skipped custom properties would inspect nothing that matters. One level
    of substitution is resolved from the same stylesheet; a reference that is
    still unresolved after that is skipped, because its value is not here to
    judge.
    """
    found: list[str] = []
    styles = STYLE_ELEMENT.findall(source) + STYLE_ATTR.findall(source)
    props = {
        name.lower(): " ".join(value.split())
        for style in styles
        for name, value in CUSTOM_PROP.findall(style)
    }

    def resolve(text: str) -> str:
        def swap(match: re.Match[str]) -> str:
            fallback = (match.group(2) or "").strip()
            return props.get(match.group(1).lower(), fallback or match.group(0))

        return VAR_REF.sub(swap, text)

    for style in styles:
        for value in FONT_DECL.findall(style):
            decl = " ".join(resolve(value).split())
            lowered = decl.lower()
            if "var(" in lowered or lowered in CSS_WIDE:
                continue
            # `font: 600 13px system-ui` carries weight and size in the same
            # value, so the family is that segment's final whitespace token.
            tokens = lowered.split(",")[-1].strip().strip("'\"").split()
            tail = tokens[-1].strip("'\"") if tokens else ""
            if tail in RESOLVING_GENERIC:
                continue
            if decl not in found:
                found.append(decl)
    return found


def content_width(source: str) -> int:
    widths = [int(w) for w in re.findall(r"max-width:\s*(\d{3,4})px", source)]
    return max(widths) if widths else DEFAULT_CONTENT_WIDTH


def escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def heading_anchors(source: str) -> dict[str, str]:
    """Map each heading id in the source to the anchor Confluence answers to.

    Confluence builds a heading's anchor from the rendered text with runs of
    whitespace turned into hyphens, and disambiguates a repeated heading with
    `.1`, `.2`. A source's own slug ids mean nothing to it, so `href="#2-breakdown"`
    points at nothing until it is rewritten into that form. This failure is
    invisible at publish time - every link renders, none of them go anywhere -
    so the mapping is built once here and every in-page href is checked against
    it rather than trusted.
    """
    anchors: dict[str, str] = {}
    seen: dict[str, int] = {}
    for match in re.finditer(r"<(h[1-6])\b([^>]*)>(.*?)</\1>", source, re.S | re.I):
        text = unescape(re.sub(r"<[^>]+>", "", match.group(3)))
        text = re.sub(r"\s+", " ", text).strip()
        if not text:
            continue
        count = seen.get(text, 0)
        seen[text] = count + 1
        anchor = re.sub(r"\s+", "-", text) + (f".{count}" if count else "")
        ident = re.search(r"""\bid\s*=\s*["']([^"']+)["']""", match.group(2))
        if ident:
            anchors[ident.group(1)] = anchor
    return anchors


NOTE_RUN = re.compile(r"(?:<blockquote>.*?</blockquote>\s*){2,}", re.DOTALL)


def group_note_runs(html: str, minimum: int = 2) -> str:
    """Fold a run of consecutive blockquotes into one collapsed note.

    A report's side-notes are small grey print in the browser; Confluence has no
    equivalent register, so each one lands as a full-weight blockquote and a run
    of four buries the paragraph they annotate. Collapsing the run keeps every
    word on the page and out of the reading line - the reader opens it when the
    caveat matters. Single notes stay inline: one blockquote reads as an aside
    already, and hiding it behind a click costs more than it saves.
    """

    def fold(match: re.Match) -> str:
        quotes = re.findall(r"<blockquote>(.*?)</blockquote>", match.group(0), re.S)
        if len(quotes) < minimum:
            return match.group(0)
        items = "".join(f"<li><p>{q.strip()}</p></li>" for q in quotes)
        return (
            # The information-source glyph is the label Confluence renders on
            # a collapsed note; the Latin `i` ruff suggests is a different one.
            "<details><summary>ℹ️ Note</summary>"  # noqa: RUF001
            f"<blockquote><ul>{items}</ul></blockquote></details>"
        )

    # A source that already collapses its own notes needs no help, and folding
    # inside its expand would nest one inside another. Only runs standing on
    # their own are candidates.
    out, cursor = [], 0
    for existing in re.finditer(r"<details\b.*?</details>", html, re.DOTALL):
        out.append(NOTE_RUN.sub(fold, html[cursor : existing.start()]))
        out.append(existing.group(0))
        cursor = existing.end()
    out.append(NOTE_RUN.sub(fold, html[cursor:]))
    return "".join(out)


BLOCK_TAG_PREFIXES = (
    "<p",
    "<ul",
    "<ol",
    "<table",
    "<div",
    "<blockquote",
    "<details",
    "<pre",
    "<h1",
    "<h2",
    "<h3",
    "<h4",
    "<h5",
    "<h6",
)


def ensure_blockquote_paragraphs(html: str) -> str:
    """Wrap a blockquote's bare inline content in <p>.

    Confluence's HTML import treats a blockquote's direct children as block
    nodes, so bare text nodes are dropped with no error and only the
    `<a>`/`<code>` elements survive. Blockquotes that `group_note_runs`
    already folded start with `<ul>` and are left as they are.
    """

    def wrap(match: re.Match) -> str:
        inner = match.group(1)
        if inner.lstrip().startswith(BLOCK_TAG_PREFIXES):
            return match.group(0)
        return f"<blockquote><p>{inner.strip()}</p></blockquote>"

    return re.sub(r"<blockquote>(.*?)</blockquote>", wrap, html, flags=re.DOTALL)


# A column narrower than this is unreadable however short its content, and one
# wider than this starves every other column. Clamping before the split is what
# keeps a 250-character prose column from collapsing the numbers beside it.
MIN_COLUMN_WEIGHT = 8
MAX_COLUMN_WEIGHT = 60
MIN_COLUMN_PX = 60
WIDE_TABLE_COLUMNS = 6
WIDE_TABLE_WIDTH = 1011


def size_tables(html: str, width: int = DEFAULT_TABLE_WIDTH) -> str:
    """Give each table explicit column widths derived from its own content.

    Confluence divides a table evenly when no width is declared, so a column of
    two-character deltas gets the same room as a column of prose and the prose
    wraps to six lines. Weighting by the longest cell in each column reproduces
    what a person does by hand: numbers narrow, sentences wide. The weight is
    clamped at both ends because raw proportionality lets one long cell take the
    whole table.

    Tables past `WIDE_TABLE_COLUMNS` get the wide breakout as well - at seven
    columns the default measure leaves nothing usable.
    """

    def cell_text(cell: str) -> int:
        inner = re.sub(r"<[^>]+>", "", cell)
        return len(unescape(inner).strip())

    def size(match: re.Match) -> str:
        table = match.group(0)
        rows = re.findall(r"<tr\b[^>]*>(.*?)</tr>", table, re.S)
        if not rows:
            return table
        grid = [re.findall(r"<(?:td|th)\b[^>]*>(.*?)</(?:td|th)>", r, re.S) for r in rows]
        columns = max((len(r) for r in grid), default=0)
        if columns < 2:
            return table
        weights = []
        for index in range(columns):
            longest = max(
                (cell_text(row[index]) for row in grid if len(row) > index), default=0
            )
            weights.append(min(max(longest, MIN_COLUMN_WEIGHT), MAX_COLUMN_WEIGHT))
        wide = columns >= WIDE_TABLE_COLUMNS
        total = WIDE_TABLE_WIDTH if wide else width
        floor = MIN_COLUMN_PX * columns
        if floor >= total:
            return table
        spare = total - floor
        total_weight = sum(weights)
        pixels = [MIN_COLUMN_PX + round(spare * w / total_weight) for w in weights]
        pixels[-1] += total - sum(pixels)

        column = 0

        def stamp(cell: re.Match) -> str:
            nonlocal column
            tag, attrs = cell.group(1), cell.group(2)
            if "data-colwidth" in attrs:
                return cell.group(0)
            index = column % columns
            column += 1
            span = re.search(r'colspan\s*=\s*["\']?(\d+)', attrs)
            if span:
                column += int(span.group(1)) - 1
            return f'<{tag}{attrs} data-colwidth="{pixels[index]}">'

        sized = re.sub(r"<(td|th)\b([^>]*)>", stamp, table)
        if wide:
            sized = sized.replace(
                "<table", f'<table data-layout="center" data-width="{WIDE_TABLE_WIDTH}"', 1
            )
        return sized

    return re.sub(r"<table\b.*?</table>", size, html, flags=re.DOTALL)


TOC_EXPAND = (
    '<details data-breakout="wide" data-breakout-width="760">'
    "<summary>Table of Contents</summary>"
    '<div data-type="extension" data-extension-key="toc" '
    'data-extension-type="com.atlassian.confluence.macro.core" data-layout="default" '
    "data-parameters='{\"macroParams\":{\"style\":{\"value\":\"none\"}},"
    '"macroMetadata":{"schemaVersion":{"value":"1"},"title":"Table of Contents"}}\''
    "></div></details>"
)

TOC_MARKUP = re.compile(r"""class=["'][^"']*\btoc(?:-[a-z]+)?\b""", re.IGNORECASE)


def source_has_toc(source: str) -> bool:
    """Whether the source shipped its own table of contents.

    A report with a navigation sidebar is written to be navigated; the sidebar
    itself is a fixed-position container the converter drops, so without this
    the published page silently loses the only way through a 5,000-word
    document. A report with no such sidebar does not want a contents block
    invented for it.
    """
    return bool(TOC_MARKUP.search(source) or re.search(r"<nav\b", source, re.I))


def simple_selector_match(selector: str, tag: str, attrs: dict) -> bool:
    """Match `tag`, `.class`, `#id`, or `tag.class`. Python has no CSS engine
    and writing one is out of scope for this converter."""
    sel_tag, _, rest = selector.partition(".")
    if rest:
        classes = (attrs.get("class") or "").split()
        if rest not in classes:
            return False
        return not sel_tag or sel_tag == tag
    if selector.startswith("#"):
        return attrs.get("id") == selector[1:]
    return selector == tag


class NestingViolationError(Exception):
    def __init__(self, description: str, context: str) -> None:
        super().__init__(description)
        self.description = description
        self.context = context


class Block:
    __slots__ = ("heading", "html", "level", "visuals")

    def __init__(self, level=None, heading=""):
        self.html: list[str] = []
        self.level = level
        self.heading = heading
        self.visuals: list[dict] = []

    def text(self) -> str:
        return "".join(self.html)

    def nbytes(self, with_visuals: bool = True) -> int:
        body = self.text()
        if not with_visuals:
            for v in self.visuals:
                body = body.replace(v["placeholder"], "")
        return len(body.encode("utf-8"))




__all__ = ['BLOCK_TAG_PREFIXES', 'CAP_BYTES', 'CHART_CLASS', 'CLASS_ATTR', 'CLASS_IN_SELECTOR', 'CSS_RULE', 'CSS_STRING', 'CSS_WIDE', 'CUSTOM_PROP', 'DEFAULT_CONTENT_WIDTH', 'DEFAULT_TABLE_WIDTH', 'DEFAULT_THRESHOLD', 'DROP_TREE', 'EXIT_BLANK_VISUAL', 'EXIT_NESTING', 'EXIT_OVERSIZE', 'FONT_DECL', 'HEADINGS', 'INLINE_PASSTHROUGH', 'JIRA_URL', 'KEYCHAIN_TIMEOUT_SECONDS', 'LANGUAGE_CLASS', 'MAX_COLUMN_WEIGHT', 'MIN_COLUMN_PX', 'MIN_COLUMN_WEIGHT', 'NESTING_RULES', 'NOTE_RUN', 'PANEL_CLASS', 'PASSTHROUGH', 'REPO_ROOT', 'RESOLVING_GENERIC', 'STYLE_ATTR', 'STYLE_ELEMENT', 'SVG_DRAWS', 'SVG_ELEMENT', 'SVG_SELF_CLOSING', 'TAG_ALIAS', 'TOC_EXPAND', 'TOC_MARKUP', 'UNWRAP', 'UNWRAP_INLINE', 'VAR_REF', 'VOID', 'WIDE_TABLE_COLUMNS', 'WIDE_TABLE_WIDTH', 'Block', 'NestingViolationError', 'blank_svg_count', 'content_width', 'ensure_blockquote_paragraphs', 'escape', 'group_note_runs', 'has_chart_primitive', 'heading_anchors', 'layout_classes', 'simple_selector_match', 'size_tables', 'source_has_toc', 'unresolving_font_stacks', 'viewbox_dimensions']
def viewbox_dimensions(svg_markup: str) -> tuple[int, int]:
    match = re.search(
        r'viewBox\s*=\s*["\']\s*[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)', svg_markup
    )
    if not match:
        return (0, 0)
    return (int(float(match.group(1))), int(float(match.group(2))))
