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

import argparse
import hashlib
import json
import os
import re
import shutil
import base64
import subprocess
import sys
import urllib.error
import urllib.request
from html import unescape
from html.parser import HTMLParser

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

EXIT_OVERSIZE = 3
EXIT_NESTING = 4

CAP_BYTES = 70000
DEFAULT_THRESHOLD = {"html": 55000, "markdown": 35000}

# html.parser reports a starttag and never an endtag for these, so counting them
# as nesting leaves the element stack permanently unbalanced. A depth counter
# that trips on `<meta charset="utf-8">` never leaves <head> and emits nothing.
VOID = frozenset(
    "area base br col embed hr img input link meta param source track wbr".split()
)

PASSTHROUGH = frozenset(
    "p h1 h2 h3 h4 h5 h6 strong em code table thead tbody tr th td ul ol li "
    "blockquote pre details summary a".split()
)

# Elements that belong inside a paragraph rather than beside one. Emitting one
# of these at block level makes Confluence wrap it in a paragraph of its own,
# which is how a sentence carrying inline <code> ends up shattered into
# one-word lines.
INLINE_PASSTHROUGH = frozenset("strong em code a br".split())

DROP_TREE = frozenset(
    "style script head nav footer canvas svg button select textarea form "
    "dialog noscript template".split()
)

UNWRAP = frozenset("div span section article main header aside figure figcaption".split())

# Unwrapped wrappers that are inline. They neither open nor close the implicit
# paragraph their siblings share: closing on `</span>` puts a label/value strip
# back to one line per piece, and closing on `</small>` splits the sentence that
# carries it. Every other unwrapped wrapper is block-level and does both.
UNWRAP_INLINE = frozenset(
    "span small abbr sup sub mark kbd samp var time cite q u s strike big tt "
    "del ins label font nobr data dfn output bdi bdo".split()
)

# `<b>`/`<i>` are the presentational spellings of emphasis. Unwrapping them threw
# the emphasis away, which is what left a metadata strip's labels
# indistinguishable from its values once the grid was gone.
TAG_ALIAS = {"b": "strong", "i": "em"}

CHART_CLASS = re.compile(r"(?:^|[\s-])(bar|bars|track|spark|sparkline|meter|gauge)(?:$|[\s-])")
PANEL_CLASS = (
    ("panel-warning", re.compile(r"(?:^|[\s-])(warn|warning|caution)(?:$|[\s-])")),
    ("panel-error", re.compile(r"(?:^|[\s-])(bad|crit|critical|error|danger)(?:$|[\s-])")),
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
    ("li", ("table", "details") + HEADINGS, "heading/table/expand inside a list item"),
    ("panel", ("table", "details", "blockquote", "panel"), "table/expand/blockquote/panel inside a panel"),
    ("cell", ("table",), "table inside a table cell"),
)

DEFAULT_CONTENT_WIDTH = 1080

GRID_RULE = re.compile(r"\.([a-z0-9_-]+)[^{]*\{([^}]*)\}", re.I)
CLASS_ATTR = re.compile(r"""class=["']([^"']*)["']""")


def layout_classes(source: str) -> set[str]:
    """Classes the source lays out with CSS grid.

    These carry the report's visual language - KPI boards, before/after cards,
    incident grids - and unwrapping them to semantic HTML yields paragraph soup,
    because the meaning lives in the two-dimensional placement, not the markup.
    They are rasterized instead.
    """
    found = set()
    for style in re.findall(r"<style[^>]*>(.*?)</style>", source, re.S):
        for match in GRID_RULE.finditer(style):
            if re.search(r"display:\s*grid", match.group(2)):
                found.add(match.group(1).lower())
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


def content_width(source: str) -> int:
    widths = [int(w) for w in re.findall(r"max-width:\s*(\d{3,4})px", source)]
    return max(widths) if widths else DEFAULT_CONTENT_WIDTH


def escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


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


class NestingViolation(Exception):
    def __init__(self, description: str, context: str) -> None:
        super().__init__(description)
        self.description = description
        self.context = context


class Block:
    __slots__ = ("html", "level", "heading", "visuals")

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


class HtmlPlusEmitter(HTMLParser):
    def __init__(self, source_text: str, rasterize: list[str], no_rasterize: bool,
                 rasterize_only: list[str] | None = None):
        super().__init__(convert_charrefs=True)
        self.source_text = source_text
        self.line_offsets = [0]
        for line in source_text.splitlines(keepends=True):
            self.line_offsets.append(self.line_offsets[-1] + len(line))
        self.rasterize = rasterize
        self.no_rasterize = no_rasterize

        self.blocks: list[Block] = [Block()]
        self.stack: list[str] = []
        self.drop_depth = 0
        self.title_from_head = ""
        self.in_title = False
        self.last_char = " "
        self.gap_pending = False
        self.stray_table_text: list[str] = []
        self.auto_cells: set[int] = set()
        self.panel_starts: list[int] = []
        self.autop_starts: list[int] = []
        self.visual_seq = 0
        self.dropped_subtrees = 0
        self.matched_grid_classes: set[str] = set()
        self.current_heading = ""

        if no_rasterize:
            self.grid_classes: set[str] = set()
        elif rasterize_only:
            self.grid_classes = {name.lstrip(".").lower() for name in rasterize_only}
        else:
            self.grid_classes = layout_classes(source_text)
        self.capture_start: int | None = None
        self.capture_tag = ""
        self.capture_depth = 0

    # ---- position helpers -------------------------------------------------
    def abs_offset(self) -> int:
        line, col = self.getpos()
        return self.line_offsets[line - 1] + col

    # ---- emit helpers -----------------------------------------------------
    @property
    def block(self) -> Block:
        return self.blocks[-1]

    def structural_depth(self) -> int:
        """Depth counting only elements that survive into the output. Layout
        wrappers are unwrapped, so an <h2> inside <div class="wrap"> is still a
        top-level heading and still starts a new splittable block."""
        return sum(1 for entry in self.stack if entry != "~unwrap")

    def emit(self, chunk: str) -> None:
        if not chunk:
            return
        self.gap_pending = False
        self.block.html.append(chunk)
        self.last_char = chunk[-1]

    def emit_gap(self) -> None:
        """Unwrapping inline elements concatenates their text: the source relied
        on CSS gaps for separation, so `<span>1,643,173</span><span>-></span>`
        would weld into one run. Record that a separator may be needed and let
        the next text decide - emitting the space eagerly doubles it whenever
        the following run already starts with whitespace, which corrupts <pre>."""
        self.gap_pending = True

    def flush_gap(self) -> None:
        """Settle a deferred separator that an inline tag, not a text run, follows.
        `emit_gap` lets the next text decide, but a run can also end at a tag -
        `</span><strong>Measurement basis</strong>` - and leaving it to the text
        welds the two pairs into `2026-09-03Measurement basis`. Only reachable
        while a paragraph already holds content: opening one emits `<p>`, and
        every emit clears the pending gap."""
        if not self.gap_pending:
            return
        self.gap_pending = False
        if self.last_char and not self.last_char.isspace():
            self.emit(" ")

    def open_block(self, level=None, heading="") -> None:
        if self.block.html or self.block.visuals:
            self.blocks.append(Block(level, heading))
        else:
            self.block.level = level
            self.block.heading = heading

    # ---- implicit paragraphs ---------------------------------------------
    def bare_run_context(self) -> bool:
        """Whether a bare inline run here needs a paragraph of its own. True in
        the page body and inside a panel - the two places ADF puts block content
        directly. An open `~autop` counts as structure, so a nested wrapper never
        opens a second paragraph."""
        structural = [entry for entry in self.stack if entry != "~unwrap"]
        return not structural or structural == ["panel"]

    def in_auto_p(self) -> bool:
        return "~autop" in self.stack

    def open_auto_p(self) -> None:
        """Open one paragraph for a run of bare inline content.

        A card laid out with CSS put its label, its value and its inline
        `<code>` in sibling wrappers and let the grid place them. Unwrapping
        those wrappers leaves the run at the top level of the body, where every
        piece needs to sit inside a paragraph - but closing a paragraph around
        each piece is what shattered a sentence into one-word lines and pushed
        inline `<code>` to block level, where Confluence renders it as its own
        paragraph. So the paragraph opens once and stays open until a real block
        element, a rasterized subtree or the end of the document closes it.
        """
        if not self.bare_run_context():
            return
        if self.structural_depth() == 0:
            # Only body-level content starts a splittable block; a paragraph
            # inside a panel belongs to the block that panel already opened.
            self.open_block()
        self.stack.append("~autop")
        self.emit("<p>")
        self.autop_starts.append(len(self.block.html))

    def close_auto_p(self) -> None:
        if not (self.stack and self.stack[-1] == "~autop"):
            return
        self.stack.pop()
        start = self.autop_starts.pop() if self.autop_starts else len(self.block.html)
        if "".join(self.block.html[start:]).strip():
            self.emit("</p>")
        else:
            # Nothing but whitespace landed in it - a wrapper that held only
            # another wrapper. Drop the paragraph rather than ship an empty one.
            del self.block.html[start - 1:]

    def open_unwrapped(self, tag: str) -> None:
        """Enter a wrapper that emits nothing of its own.

        A block-level wrapper ends the implicit paragraph on the way in, not
        only on the way out: `<span>Draft</span><div>Body</div>` otherwise welds
        two blocks into one paragraph, while the same pair in the other order
        splits correctly. An inline wrapper leaves the paragraph alone at both
        ends, which is what keeps `was <small>p95</small> above` one sentence.
        """
        if tag not in UNWRAP_INLINE:
            self.close_auto_p()
        self.stack.append("~unwrap")
        self.emit_gap()

    # ---- nesting detection ------------------------------------------------
    def check_nesting(self, tag: str) -> None:
        probe = "panel" if tag == "panel" else tag
        for container, forbidden, description in NESTING_RULES:
            if container == "cell":
                present = "td" in self.stack or "th" in self.stack
            else:
                present = container in self.stack
            if present and probe in forbidden:
                raise NestingViolation(description, self.current_heading or "(before the first heading)")

    # ---- parser callbacks -------------------------------------------------
    def handle_starttag(self, tag, attrs):
        attrs = {k: (v or "") for k, v in attrs}
        tag = TAG_ALIAS.get(tag, tag)

        if self.capture_start is not None:
            if tag == self.capture_tag and tag not in VOID:
                self.capture_depth += 1
            return
        if tag == "title" and not self.in_title:
            # Checked before drop_depth: <title> lives inside <head>, which is a
            # dropped subtree, so a later check never sees it.
            self.in_title = True
            self.drop_depth += 1
            return
        if self.drop_depth:
            if tag not in VOID:
                self.drop_depth += 1
            return

        if tag == "svg":
            if "viewbox" in {k.lower() for k in attrs} and not self.no_rasterize:
                self.begin_capture(tag)
            else:
                self.drop_depth = 1
            return

        class_set = set((attrs.get("class") or "").lower().split())
        matched = class_set & self.grid_classes
        if matched:
            self.matched_grid_classes |= matched
            self.begin_capture(tag)
            return

        if tag in VOID:
            if tag == "br":
                self.open_auto_p()
                self.emit("<br />")
            elif tag == "hr":
                self.close_auto_p()
                self.emit("<hr />")
            return

        if tag in DROP_TREE:
            self.drop_depth = 1
            return

        classes = attrs.get("class", "")
        if attrs.get("aria-hidden") == "true":
            self.drop_depth = 1
            return
        if CHART_CLASS.search(classes) or any(
            simple_selector_match(sel, tag, attrs) for sel in self.rasterize
        ):
            self.dropped_subtrees += 1
            self.drop_depth = 1
            return

        if tag in UNWRAP:
            panel = None
            if tag == "div":
                for kind, pattern in PANEL_CLASS:
                    if pattern.search(classes):
                        panel = kind
                        break
            if panel:
                self.close_auto_p()
                self.check_nesting("panel")
                self.stack.append("panel")
                if self.structural_depth() == 1:
                    self.open_block()
                self.emit('<div data-type="%s">' % panel)
                self.panel_starts.append(len(self.block.html))
            else:
                self.open_unwrapped(tag)
            return

        if tag not in PASSTHROUGH:
            self.open_unwrapped(tag)
            return

        if tag in INLINE_PASSTHROUGH:
            self.open_auto_p()
            self.flush_gap()
        else:
            self.close_auto_p()

        if self.stack and self.stack[-1] in ("table", "thead", "tbody", "tr") and tag not in (
            "tr", "td", "th", "thead", "tbody"
        ):
            # An element orphaned inside a row, outside any cell. Malformed
            # source, but the content is real - a dropped <td> around a PR link
            # is the usual cause - so wrap it in a cell rather than losing it.
            self.stack.append("td")
            self.auto_cells.add(len(self.stack) - 1)
            self.emit("<td>")

        self.check_nesting(tag)

        if self.structural_depth() == 0:
            if tag in HEADINGS:
                self.open_block(level=int(tag[1]))
                self.current_heading = ""
            else:
                self.open_block()

        self.stack.append(tag)
        self.emit(self.open_tag_html(tag, attrs))

    def open_tag_html(self, tag: str, attrs: dict) -> str:
        if tag == "a":
            href = attrs.get("href", "")
            if JIRA_URL.fullmatch(href.strip()):
                return '<a href="%s" data-card-appearance="inline">' % escape(href)
            return '<a href="%s">' % escape(href)
        if tag in ("td", "th"):
            extra = ""
            for key in ("colspan", "rowspan"):
                value = attrs.get(key, "")
                if value.isdigit() and int(value) > 1:
                    extra += ' %s="%s"' % (key, value)
            return "<%s%s>" % (tag, extra)
        if tag == "code":
            match = LANGUAGE_CLASS.search(attrs.get("class", ""))
            if match and "pre" in self.stack:
                return '<code class="language-%s">' % match.group(1)
            return "<code>"
        if tag == "table":
            return "<table>"
        return "<%s>" % tag

    def handle_startendtag(self, tag, attrs):
        """Self-closing non-void tags must leave no state behind.

        `handle_starttag` can open a capture, a dropped subtree, or a stack
        entry, and no end tag is coming to close any of them. A leaked
        `drop_depth` is the dangerous one: `<button><i class="icon"/></button>`
        leaves the counter at 1 forever, so every element after it is silently
        discarded and the page publishes truncated.
        """
        if tag in VOID:
            self.handle_starttag(tag, attrs)
            return
        before_drop = self.drop_depth
        before_capture = self.capture_start
        before_capture_depth = self.capture_depth
        self.handle_starttag(tag, attrs)
        if before_capture is not None:
            self.capture_depth = before_capture_depth
            return
        if self.capture_start is not None:
            # It opened a capture on an element that closes immediately, so
            # there is no content to rasterize. Abandon it.
            self.capture_start = None
            return
        if self.drop_depth != before_drop:
            self.drop_depth = before_drop
            return
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        tag = TAG_ALIAS.get(tag, tag)
        if self.capture_start is not None:
            if tag == self.capture_tag:
                self.capture_depth -= 1
                if self.capture_depth == 0:
                    end = self.source_text.find(">", self.abs_offset()) + 1
                    markup = self.source_text[self.capture_start:end]
                    self.capture_start = None
                    self.capture_visual(markup)
            return
        if tag == "title":
            self.in_title = False
            self.drop_depth = max(0, self.drop_depth - 1)
            return
        if self.drop_depth:
            self.drop_depth -= 1
            return
        if tag in VOID:
            return

        if tag == "div" and self.stack[-1:] == ["~autop"] and self.stack[-2:-1] == ["panel"]:
            # The panel's own implicit paragraph. Close it before the branch
            # below looks at the top of the stack, or the panel never closes and
            # the next panel reads as a panel nested inside this one.
            self.close_auto_p()
        if self.stack and self.stack[-1] == "panel" and tag == "div":
            self.stack.pop()
            start = self.panel_starts.pop() if self.panel_starts else len(self.block.html)
            inner = "".join(self.block.html[start:])
            # Fallback for a panel whose content the implicit-paragraph rule did
            # not reach: bare inline runs get one paragraph per run from
            # Confluence, which fragments a sentence across lines. Wrap the whole
            # run in a single <p> instead. Panels containing real blocks are left
            # alone - nesting a <p> around them would be invalid.
            if inner.strip() and not re.search(r"<(p|table|ul|ol|blockquote|details|h[1-6])[ >]", inner):
                del self.block.html[start:]
                self.block.html.append("<p>%s</p>" % inner.strip())
            self.emit("</div>")
            return
        if tag in UNWRAP or tag not in PASSTHROUGH:
            # Pop the wrapper's marker from under any open implicit paragraph
            # rather than off the top: the paragraph deliberately outlives the
            # wrapper so consecutive siblings stay in one paragraph, and popping
            # the top here would strand the marker and corrupt the depth count.
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i] == "~unwrap":
                    del self.stack[i]
                    break
            if tag not in UNWRAP_INLINE:
                self.close_auto_p()
            self.emit_gap()
            return
        if tag == "tr" and self.stack and self.stack[-1] == "td" \
                and (len(self.stack) - 1) in self.auto_cells:
            self.auto_cells.discard(len(self.stack) - 1)
            self.stack.pop()
            self.emit("</td>")
        if tag in self.stack:
            while self.stack and self.stack[-1] != tag:
                self.stack.pop()
            if self.stack:
                self.stack.pop()
        self.emit("</%s>" % tag)
        if tag in HEADINGS and not self.block.heading:
            self.block.heading = self.current_heading

    def handle_data(self, data):
        if self.capture_start is not None:
            return
        if self.in_title:
            self.title_from_head += data
            return
        if self.drop_depth:
            return
        if not data.strip():
            if self.last_char and not self.last_char.isspace():
                self.emit(" ")
            return
        if self.gap_pending:
            self.gap_pending = False
            if not data[:1].isspace() and self.last_char and not self.last_char.isspace():
                self.emit(" ")
        if self.stack and self.stack[-1] in ("table", "thead", "tbody", "tr"):
            # Text directly inside a table but outside any cell is invalid HTML.
            # Real sources do produce it - a broken generator can leave literal
            # text where a <td> should be - and forwarding it risks the MCP
            # rejecting the whole page, so drop it and surface it as a warning
            # rather than silently shipping malformed markup.
            self.stray_table_text.append(data.strip()[:40])
            return
        if self.bare_run_context() or self.in_auto_p():
            # Bare text with only unwrapped layout wrappers above it still needs
            # a paragraph; emitting it loose leaves inline text at the top level
            # of the page body. One paragraph for the whole run, not one per run.
            self.open_auto_p()
            start = self.autop_starts[-1] if self.autop_starts else len(self.block.html)
            if "".join(self.block.html[start:]).strip():
                # Mid-paragraph: the trailing space before an inline <code> is
                # load-bearing, so only the paragraph's first run is trimmed.
                self.emit(escape(data))
            else:
                self.emit(escape(data.lstrip()))
            return
        if self.stack[-1] in HEADINGS:
            self.current_heading += data.strip()
        self.emit(escape(data))

    def close(self) -> None:
        """Flush a paragraph the document ended inside, so the body never ships
        an unclosed <p>."""
        super().close()
        self.close_auto_p()

    # ---- visuals ----------------------------------------------------------
    def begin_capture(self, tag: str) -> None:
        self.close_auto_p()
        self.capture_start = self.abs_offset()
        self.capture_tag = tag
        self.capture_depth = 1

    def capture_visual(self, markup: str) -> None:
        self.visual_seq += 1
        name = "chart-%02d.png" % self.visual_seq
        is_svg = markup.lstrip().startswith("<svg")
        width, height = viewbox_dimensions(markup) if is_svg else (0, 0)
        chart_text = unescape(re.sub(r"<[^>]+>", " ", markup))
        chart_text = re.sub(r"\s+", " ", chart_text).strip()

        placeholder = (
            '<div data-type="panel-info"><p><strong>Chart:</strong> %s'
            " - attach <code>%s</code> here.</p></div>"
            % (escape(self.current_heading or "chart %d" % self.visual_seq), name)
        )
        if self.structural_depth() == 0:
            self.open_block()
        self.emit(placeholder)
        self.block.visuals.append(
            {
                "id": self.visual_seq,
                "png": name,
                "width": width,
                "height": height,
                "text_chars": len(chart_text),
                "kind": "svg" if is_svg else "block",
                "placeholder": placeholder,
                "markup": markup,
                "status": "pending",
            }
        )


def viewbox_dimensions(svg_markup: str) -> tuple[int, int]:
    match = re.search(r'viewBox\s*=\s*["\']\s*[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)', svg_markup)
    if not match:
        return (0, 0)
    return (int(float(match.group(1))), int(float(match.group(2))))


def markdown_blocks(text: str) -> tuple[str, list[Block], list[str]]:
    warnings = []
    body = text
    if body.startswith("---\n"):
        end = body.find("\n---", 4)
        if end != -1:
            body = body[body.find("\n", end + 1) + 1:]

    title = ""
    lines = body.splitlines(keepends=True)
    if lines and lines[0].startswith("# "):
        title = lines[0][2:].strip()
        lines = lines[1:]

    for pattern, message in (
        (r"^!\[[^\]]*\]\(", "local image reference: markdown passthrough cannot carry it"),
        (r"^```mermaid", "mermaid fence: markdown passthrough renders it as plain code"),
    ):
        if re.search(pattern, body, re.M):
            warnings.append(message)

    blocks = [Block()]
    for line in lines:
        if line.startswith("## "):
            if blocks[-1].html:
                blocks.append(Block(level=2, heading=line[3:].strip()))
            else:
                blocks[-1].level = 2
                blocks[-1].heading = line[3:].strip()
        blocks[-1].html.append(line)
    return title, [b for b in blocks if b.text().strip()], warnings


def page_bytes(page, with_visuals=True) -> int:
    return sum(b.nbytes(with_visuals=with_visuals) for b in page)


def pack(blocks, threshold, level, with_visuals) -> list[list[Block]]:
    """Greedily pack blocks into pages, breaking only where a block starts a
    section at `level` or shallower. `level=None` breaks at any block."""
    pages: list[list[Block]] = [[]]
    size = 0
    for block in blocks:
        nbytes = block.nbytes(with_visuals=with_visuals)
        can_break = level is None or (block.level is not None and block.level <= level)
        if can_break and size and size + nbytes > threshold:
            pages.append([])
            size = 0
        pages[-1].append(block)
        size += nbytes
    return [p for p in pages if p]


def split_blocks(blocks, threshold, with_visuals=True) -> list[list[Block]]:
    """Break at h2, then re-break any still-oversized page at h3, then at any
    block boundary. Real reports are not evenly distributed - one h2 section of
    effort-rollup-2026-07.html carries 65% of the document with a single h3
    inside it, so heading boundaries alone cannot produce compliant pages. A
    paragraph-boundary break loses no content; only a single block larger than
    the cap is genuinely unsplittable, and that is what exits 3."""
    pages = pack(blocks, threshold, 2, with_visuals)
    for level in (3, None):
        regrouped: list[list[Block]] = []
        for page in pages:
            if page_bytes(page, with_visuals) > threshold and len(page) > 1:
                regrouped.extend(pack(page, threshold, level, with_visuals))
            else:
                regrouped.append(page)
        pages = regrouped
    return pages


def resolve_title(explicit, from_head, blocks, source_path) -> str:
    if explicit:
        return explicit
    if from_head.strip():
        return from_head.strip()
    for block in blocks:
        if block.level == 1 and block.heading:
            return block.heading
    return os.path.splitext(os.path.basename(source_path))[0]


TITLE_LIMIT = 255
HEADING_FRAGMENT_LIMIT = 60


def clamp(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0] or text[:limit]
    return cut.rstrip(" ,;:-") + "…"


def page_title(base: str, page: list[Block], index: int, carried: str) -> tuple[str, str]:
    """Return (title, heading to carry forward). A page produced by a
    block-boundary break has no heading of its own, so it continues the last
    heading seen rather than degrading to "part N"."""
    own = next((b.heading for b in page if b.heading), "")
    heading = own or carried
    if index == 0:
        return clamp(base, TITLE_LIMIT), heading
    if own:
        title = "%s - %s" % (base, clamp(own, HEADING_FRAGMENT_LIMIT))
    elif carried:
        title = "%s - %s (cont. %d)" % (base, clamp(carried, HEADING_FRAGMENT_LIMIT), index + 1)
    else:
        title = "%s - part %d" % (base, index + 1)
    return clamp(title, TITLE_LIMIT), heading


def cmd_plan(args) -> int:
    source_path = os.path.abspath(args.source)
    raw = open(source_path, encoding="utf-8").read()
    kind = "markdown" if source_path.lower().endswith((".md", ".markdown")) else "html"
    threshold = args.split_threshold or DEFAULT_THRESHOLD[kind]
    warnings: list[str] = []

    if args.rasterize_only and args.no_rasterize:
        sys.stderr.write(
            "--rasterize-only and --no-rasterize contradict each other: one names what to "
            "image, the other images nothing. Pick one.\n"
        )
        return 2
    if args.rasterize_only and kind == "markdown":
        warnings.append(
            "--rasterize-only was ignored: a Markdown source carries no <style>, so nothing "
            "is ever rasterized. Publish the HTML edition when the charts matter."
        )

    if kind == "markdown":
        head_title, blocks, md_warnings = markdown_blocks(raw)
        warnings.extend(md_warnings)
        dropped = 0
    else:
        emitter = HtmlPlusEmitter(
            raw, args.rasterize or [], args.no_rasterize, args.rasterize_only or []
        )
        try:
            emitter.feed(raw)
            emitter.close()
        except NestingViolation as exc:
            sys.stderr.write(
                "NESTING: %s, under %s.\n"
                "Confluence rejects this construct. Restructure the source, or "
                "publish that section separately.\n" % (exc.description, exc.context)
            )
            return EXIT_NESTING
        head_title = emitter.title_from_head
        blocks = [b for b in emitter.blocks if b.text().strip() or b.visuals]
        dropped = emitter.dropped_subtrees
        if emitter.stray_table_text:
            warnings.append(
                "dropped %d text run(s) sitting inside a table but outside any cell - "
                "the source markup is malformed there: %s"
                % (len(emitter.stray_table_text), ", ".join(emitter.stray_table_text[:6]))
            )
        prose_images = [
            visual["png"]
            for block in emitter.blocks
            for visual in block.visuals
            if not has_chart_primitive(visual["markup"]) and visual["text_chars"]
        ]
        if prose_images:
            warnings.append(
                "%d rasterized block(s) contain no bar, track, spark, meter or svg, so they "
                "are most likely prose being turned into an image - and an imaged block "
                "stops being searchable, copyable and clickable: %s. Scope the capture with "
                "--rasterize-only <class> if that is not intended."
                % (len(prose_images), ", ".join(prose_images))
            )
        if args.rasterize_only:
            # A named class that exists but never captured sits inside another named
            # container - redundant, not a typo - so `present` excuses it.
            present = {
                token.lower()
                for value in CLASS_ATTR.findall(raw)
                for token in value.split()
            }
            missing = sorted(emitter.grid_classes - emitter.matched_grid_classes - present)
            if missing:
                warnings.append(
                    "--rasterize-only named %s, which matched nothing in the source - a typo "
                    "leaves the real charts unwrapped into label soup with no image to "
                    "replace them" % ", ".join(missing)
                )

    title = resolve_title(args.title, head_title, blocks, source_path)
    if kind == "html" and blocks and blocks[0].level == 1 and blocks[0].heading.strip() == title.strip():
        # Strip only the duplicated <h1> element. The block also carries the
        # content that follows it, including any chart placeholder, so dropping
        # the whole block silently deletes the top of the document.
        first = blocks[0]
        without_h1 = re.sub(r"^\s*<h1>.*?</h1>\s*", "", first.text(), count=1, flags=re.S)
        first.html = [without_h1]
        first.level = None
        first.heading = ""
        blocks = [b for b in blocks if b.text().strip() or b.visuals]

    pages_blocks = split_blocks(blocks, threshold)
    pages_dropping_visuals = split_blocks(blocks, threshold, with_visuals=False)

    os.makedirs(args.out_dir, exist_ok=True)
    ext = "md" if kind == "markdown" else "html"

    def tidy(body: str) -> str:
        """Drop rules stranded at the top of a page.

        A separator that sat inside a dropped interactive container (an export
        menu, say) survives as a leading `<hr>` because it is a void element
        emitted before its parent is discarded. A page should not open with a
        horizontal rule.
        """
        while True:
            stripped = re.sub(r"^\s*<hr\s*/?>\s*", "", body)
            if stripped == body:
                return body
            body = stripped

    pages = []
    carried_heading = ""
    for index, page in enumerate(pages_blocks):
        body = tidy("".join(b.text() for b in page))
        nbytes = len(body.encode("utf-8"))
        if nbytes > CAP_BYTES:
            heading = next((b.heading for b in page if b.heading), "(untitled section)")
            biggest = max(b.nbytes() for b in page)
            sys.stderr.write(
                "OVERSIZE: page %d (%r) is %d bytes, over the %d cap, and its largest "
                "single block is %d bytes so no boundary can break it.\n"
                "Split that block in the source - a long table or code listing is the "
                "usual cause - or publish it as its own document.\n"
                % (index, heading, nbytes, CAP_BYTES, biggest)
            )
            return EXIT_OVERSIZE
        body_file = os.path.join(args.out_dir, "page-%03d.body.%s" % (index, ext))
        with open(body_file, "w", encoding="utf-8") as handle:
            handle.write(body)
        visuals = [v for b in page for v in b.visuals]
        title_text, carried_heading = page_title(title, page, index, carried_heading)
        pages.append(
            {
                "index": index,
                "title": title_text,
                "body_file": body_file,
                "bytes": nbytes,
                "bytes_without_visuals": sum(b.nbytes(with_visuals=False) for b in page),
                "visuals": [
                    {k: v[k] for k in ("id", "png", "width", "height", "text_chars", "kind", "status")}
                    for v in visuals
                ],
            }
        )

    without_total = sum(p["bytes_without_visuals"] for p in pages)
    split_differs = len(pages_dropping_visuals) != len(pages_blocks)

    plan = {
        "source": source_path,
        "source_sha256": hashlib.sha256(raw.encode("utf-8")).hexdigest(),
        "kind": kind,
        "title": title,
        "split_threshold": threshold,
        "split_differs_without_visuals": split_differs,
        "dropped_chart_subtrees": dropped,
        "pages": pages,
        "warnings": warnings,
        "_visual_markup": {
            str(v["id"]): v["markup"] for b in blocks for v in b.visuals
        },
        "_style": extract_styles(raw) if kind == "html" else "",
        "_content_width": content_width(raw) if kind == "html" else DEFAULT_CONTENT_WIDTH,
    }
    plan_path = os.path.join(args.out_dir, "plan.json")
    with open(plan_path, "w", encoding="utf-8") as handle:
        json.dump(plan, handle, indent=2)

    total_visuals = sum(len(p["visuals"]) for p in pages)
    print("source      %s (%s)" % (source_path, kind))
    print("title       %s" % title)
    print("pages       %d (threshold %d B)" % (len(pages), threshold))
    for page in pages:
        print("  [%d] %-58s %7d B  %d chart(s)"
              % (page["index"], page["title"][:58], page["bytes"], len(page["visuals"])))
    print("charts      %d to rasterize, %d chart-class subtrees dropped" % (total_visuals, dropped))
    print("without visuals: %d B total" % without_total)
    for warning in warnings:
        print("warning     %s" % warning)
    print("plan        %s" % plan_path)
    return 0


def extract_styles(raw: str) -> str:
    return "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", raw, re.S))


def find_chrome() -> str | None:
    for candidate in (
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ):
        if os.path.exists(candidate):
            return candidate
    return shutil.which("google-chrome") or shutil.which("chromium")


DARK_MEDIA = re.compile(r"@media[^{]*prefers-color-scheme\s*:\s*dark[^{]*\{")


def force_light(style: str) -> str:
    """Disable the source's dark-mode block for rendering only.

    Confluence pages are light, so a chart captured in the dark palette looks
    broken on the page. Forcing `data-theme="light"` is not enough: a report
    whose media query is unguarded (no `:not([data-theme="light"])`) still
    follows the browser preference, and headless Chrome may report dark. The
    rewritten CSS is used for the screenshot only and never written back.
    """
    return DARK_MEDIA.sub("@media not all{", style)


def render_document(style: str, markup: str, width: int, measure: bool) -> str:
    """Standalone page holding one visual block.

    `data-theme="light"` is forced because these reports are theme-aware and
    headless Chrome would otherwise render the dark palette onto Confluence's
    light page. The `.wrap` shim reinstates the content width the block's CSS
    assumes, which dies the moment the element leaves its ancestor chain.
    """
    probe = (
        "<script>window.addEventListener('load',function(){"
        "var b=document.querySelector('.__block').getBoundingClientRect();"
        "document.title='H'+Math.ceil(b.height);});</script>"
        if measure else ""
    )
    return (
        '<!doctype html><html data-theme="light"><head><meta charset="utf-8">'
        "<style>%s\nhtml,body{margin:0;padding:0;background:#fff}"
        ".__shim{width:%dpx;padding:0;margin:0;max-width:none}"
        ".__block{display:inline-block;width:%dpx;padding:12px;box-sizing:border-box}"
        "</style>%s</head>"
        '<body><div class="wrap __shim"><div class="__block">%s</div></div></body></html>'
        % (force_light(style), width, width, probe, markup)
    )


def measure_height(chrome: str, path: str, width: int) -> int:
    """Chrome screenshots a viewport, not an element, so the height has to be
    read back before the capture or every PNG carries a tail of blank page."""
    argv = [
        chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
        "--virtual-time-budget=4000", "--window-size=%d,800" % width,
        "--dump-dom", "file://%s" % path,
    ]
    try:
        done = subprocess.run(argv, capture_output=True, timeout=30, text=True)
    except subprocess.TimeoutExpired:
        return 0
    found = re.search(r"<title>H(\d+)</title>", done.stdout or "")
    return int(found.group(1)) if found else 0


def cmd_render(args) -> int:
    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    markup_by_id = plan.get("_visual_markup", {})
    if not markup_by_id:
        print("no visuals to render")
        return 0

    out_dir = os.path.dirname(os.path.abspath(args.plan))
    assets = os.path.join(out_dir, "assets")
    os.makedirs(assets, exist_ok=True)
    chrome = find_chrome()
    style = plan.get("_style", "")
    page_width = int(plan.get("_content_width") or DEFAULT_CONTENT_WIDTH)

    for page in plan["pages"]:
        for visual in page["visuals"]:
            markup = markup_by_id.get(str(visual["id"]), "")
            target = os.path.join(assets, visual["png"])
            if not chrome or not markup:
                visual["status"] = "skipped:no-renderer"
                continue

            if visual.get("kind") == "svg":
                # The source sizes its charts through CSS that dies once the
                # element leaves its ancestor chain, so pin the viewBox
                # dimensions onto the element instead of inheriting them.
                width = visual["width"] or page_width
                height = visual["height"] or 600
                markup = re.sub(
                    r"<svg\b", '<svg width="%d" height="%d"' % (width, height), markup, count=1
                )
                doc_width = width
            else:
                doc_width = page_width
                height = 0

            html_path = os.path.join(assets, "visual-%02d.html" % visual["id"])
            if not height:
                with open(html_path, "w", encoding="utf-8") as handle:
                    handle.write(render_document(style, markup, doc_width, measure=True))
                height = measure_height(chrome, html_path, doc_width)
                if not height:
                    visual["status"] = "skipped:unmeasurable"
                    os.remove(html_path)
                    continue
                visual["width"], visual["height"] = doc_width, height

            with open(html_path, "w", encoding="utf-8") as handle:
                handle.write(render_document(style, markup, doc_width, measure=False))

            argv = [
                chrome,
                "--headless",
                "--disable-gpu",
                "--disable-javascript",
                "--hide-scrollbars",
                "--force-device-scale-factor=2",
                "--default-background-color=ffffffff",
                "--window-size=%d,%d" % (doc_width, height),
                "--screenshot=%s" % target,
                "file://%s" % html_path,
            ]
            try:
                subprocess.run(argv, capture_output=True, timeout=30, check=False)
            except subprocess.TimeoutExpired:
                visual["status"] = "skipped:render-timeout"
            else:
                visual["status"] = (
                    "rendered" if os.path.exists(target) else "skipped:no-output"
                )
            if os.path.exists(html_path):
                os.remove(html_path)

    with open(args.plan, "w", encoding="utf-8") as handle:
        json.dump(plan, handle, indent=2)

    counts: dict[str, int] = {}
    for page in plan["pages"]:
        for visual in page["visuals"]:
            counts[visual["status"]] = counts.get(visual["status"], 0) + 1
    for status, count in sorted(counts.items()):
        print("%-24s %d" % (status, count))
    print("assets      %s" % assets)
    return 0


KEYCHAIN_SERVICE = "nase-confluence"
ATTACH_PATH = "/wiki/rest/api/content/%s/child/attachment"


TOKEN_ENV = "CONFLUENCE_API_TOKEN"


def api_token(service: str, account: str) -> str:
    """Read the Atlassian API token, keychain first and environment second.

    The token is never passed on a command line, never written to the plan, and
    never printed. Confluence attachment upload exists only on REST v1 - the
    MCP exposes no attachment tool and v2 is GET/DELETE only - so this is the
    single credential the publish path needs.

    The keychain is preferred because it survives no shell history and no
    process listing. `security` is macOS-only, so everywhere else the
    environment variable is the supported path; it is read only after the
    keychain lookup fails, so a stale export never shadows the real token.
    """
    if shutil.which("security"):
        done = subprocess.run(
            ["security", "find-generic-password", "-w", "-s", service, "-a", account],
            capture_output=True, text=True,
        )
        if done.returncode == 0 and done.stdout.strip():
            return done.stdout.strip()

    from_env = os.environ.get(TOKEN_ENV, "").strip()
    if from_env:
        return from_env

    raise RuntimeError(
        "no Atlassian API token found for %r.\n"
        "  macOS:     security add-generic-password -U -s %s -a %s -w\n"
        "             (then paste the token at the prompt)\n"
        "  elsewhere: export %s=<token>\n"
        "Create the token at https://id.atlassian.com/manage-profile/security/api-tokens"
        % (account, service, account, TOKEN_ENV)
    )


def multipart(fields: dict, filename: str, payload: bytes) -> tuple[bytes, str]:
    boundary = "----nase" + hashlib.sha256(filename.encode()).hexdigest()[:24]
    out = []
    for key, value in fields.items():
        out.append(
            ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
             % (boundary, key, value)).encode()
        )
    out.append(
        ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
         "Content-Type: image/png\r\n\r\n" % (boundary, filename)).encode()
    )
    out.append(payload)
    out.append(("\r\n--%s--\r\n" % boundary).encode())
    return b"".join(out), "multipart/form-data; boundary=%s" % boundary


def post_png(url: str, email: str, token: str, path: str) -> dict:
    name = os.path.basename(path)
    body, content_type = multipart({"minorEdit": "true"}, name, open(path, "rb").read())
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", content_type)
    request.add_header("X-Atlassian-Token", "nocheck")
    request.add_header(
        "Authorization",
        "Basic " + base64.b64encode(("%s:%s" % (email, token)).encode()).decode(),
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode())


def upload_attachment(site: str, email: str, token: str, page_id: str, path: str) -> dict:
    return post_png("https://%s%s" % (site, ATTACH_PATH % page_id), email, token, path)


def update_attachment_data(
    site: str, email: str, token: str, page_id: str, attachment_id: str, path: str
) -> dict:
    """Replace the bytes of an attachment already on the page.

    Confluence refuses a second attachment under an existing filename, and chart
    filenames are positional (`chart-01.png`), so a re-publish reuses every name
    with new content.

    Verified against the live API: the refresh mints a **new** `fileId`, so the
    caller must take the media id from this response. Reusing the id from the
    attachment listing embeds the superseded version - bytes current, page stale.
    """
    return post_png(
        "https://%s%s/%s/data" % (site, ATTACH_PATH % page_id, attachment_id),
        email,
        token,
        path,
    )


def existing_attachments(site: str, email: str, token: str, page_id: str) -> dict:
    """Map filename -> {"id", "file_id"} for attachments already on the page.

    Both ids matter: `file_id` is the media id the body node references, and `id`
    is what addresses the attachment when its bytes need replacing.
    """
    request = urllib.request.Request(
        "https://%s/wiki/api/v2/pages/%s/attachments?limit=250" % (site, page_id)
    )
    request.add_header(
        "Authorization",
        "Basic " + base64.b64encode(("%s:%s" % (email, token)).encode()).decode(),
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.loads(response.read().decode())
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        # Worst case this misses an existing attachment and uploads a second
        # version, which Confluence handles; a traceback here would abort the
        # whole page instead.
        return {}
    return {
        a["title"]: {"id": a.get("id", ""), "file_id": a.get("fileId", "")}
        for a in data.get("results", [])
        if a.get("fileId")
    }


def media_id_of(result: dict) -> str:
    """The media id a body node can reference, or "" when the response has none.

    Only `extensions.fileId` is a media id; the attachment's own `att…` id is not,
    and substituting it embeds a node that renders as a broken image while the
    status still says attached. "" routes to `attach-failed:no-media-id` instead.
    """
    node = (result.get("results") or [result])[0]
    return (node.get("extensions") or {}).get("fileId") or ""


PLACEHOLDER_RE = (
    r'<div data-type="panel-info"><p><strong>Chart:</strong>'
    r'(?:(?!</div>).)*?attach <code>%s</code>(?:(?!</div>).)*?</p></div>'
)


def replace_placeholder(body: str, png: str, node: str) -> tuple[str, bool]:
    """Swap the placeholder panel for the real media node.

    Matched on the PNG filename rather than a remembered string: the panel text
    is regenerated by `plan` and only the filename is guaranteed stable across
    a re-plan.
    """
    pattern = re.compile(PLACEHOLDER_RE % re.escape(png), re.S)
    updated, count = pattern.subn(node, body, count=1)
    return updated, bool(count)


def resolve_site(explicit: str) -> str:
    """The Atlassian host to upload to.

    Hard-coding one organisation would make this script unusable for anyone
    else, so the default comes from the same `workspace/config.md` entry the
    Jira flows already read.
    """
    if explicit:
        return explicit.replace("https://", "").rstrip("/")
    # REPO_ROOT is the checkout holding this script; cwd covers a worktree,
    # where `workspace/` is git-ignored and therefore absent.
    for root in (REPO_ROOT, os.getcwd()):
        config = os.path.join(root, "workspace", "config.md")
        if not os.path.exists(config):
            continue
        found = re.search(
            r"^\s*baseUrl:\s*(?:https://)?([A-Za-z0-9.-]+)",
            open(config, encoding="utf-8").read(), re.M,
        )
        if found:
            return found.group(1).rstrip("/")
    raise RuntimeError(
        "no Atlassian site to upload to. Pass --site <your-org>.atlassian.net, or add "
        "`baseUrl: https://<your-org>.atlassian.net` under `## Jira` in workspace/config.md"
    )


def cmd_attach(args) -> int:
    site = resolve_site(args.site)
    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    out_dir = os.path.dirname(os.path.abspath(args.plan))
    assets = os.path.join(out_dir, "assets")

    page = next((p for p in plan["pages"] if p["index"] == args.page_index), None)
    if page is None:
        sys.stderr.write("no page with index %d in the plan\n" % args.page_index)
        return 2
    # Retry anything not already attached: a failed upload (auth, network) must
    # be re-runnable without hand-editing the plan, and an already-attached
    # visual must not be uploaded twice.
    pending = [v for v in page["visuals"] if v.get("status") != "attached"]
    if not pending:
        print("nothing to attach for page %d" % args.page_index)
        return 0

    token = api_token(args.keychain_service, args.account)
    already = existing_attachments(site, args.account, token, args.page_id)
    body_path = page["body_file"]
    body = open(body_path, encoding="utf-8").read()

    for visual in pending:
        png = os.path.join(assets, visual["png"])
        if not os.path.exists(png):
            visual["status"] = "attach-failed:missing-png"
            continue
        prior = already.get(visual["png"]) or {}
        media_id = prior.get("file_id", "")
        try:
            if media_id:
                media_id = media_id_of(
                    update_attachment_data(
                        site, args.account, token, args.page_id, prior["id"], png
                    )
                )
            else:
                media_id = media_id_of(
                    upload_attachment(site, args.account, token, args.page_id, png)
                )
        except urllib.error.HTTPError as exc:
            visual["status"] = "attach-failed:http-%d" % exc.code
            sys.stderr.write("upload %s failed: HTTP %d\n" % (visual["png"], exc.code))
            continue
        except (urllib.error.URLError, OSError) as exc:
            visual["status"] = "attach-failed:network"
            sys.stderr.write("upload %s failed: %s\n" % (visual["png"], exc))
            continue
        if not media_id:
            visual["status"] = "attach-failed:no-media-id"
            continue

        node = (
            '<figure data-type="media-single" data-layout="center" data-width="%d" '
            'data-width-type="pixel"><div data-type="media" data-media-type="file" '
            'data-id="%s" data-collection="contentId-%s" data-width="%d" data-height="%d">'
            "</div></figure>"
            % (visual["width"], media_id, args.page_id,
               visual["width"] * 2, visual["height"] * 2)
        )
        body, swapped = replace_placeholder(body, visual["png"], node)
        if not swapped:
            visual["status"] = "attach-failed:placeholder-not-found"
            continue
        visual["media_id"] = media_id
        visual["status"] = "attached"

    with open(body_path, "w", encoding="utf-8") as handle:
        handle.write(body)
    page["bytes"] = len(body.encode("utf-8"))
    with open(args.plan, "w", encoding="utf-8") as handle:
        json.dump(plan, handle, indent=2)

    counts: dict[str, int] = {}
    for visual in page["visuals"]:
        counts[visual["status"]] = counts.get(visual["status"], 0) + 1
    for status, count in sorted(counts.items()):
        print("%-28s %d" % (status, count))
    print("body        %s (%d B)" % (body_path, page["bytes"]))
    return 0 if all(v["status"] == "attached" for v in pending) else 1


LEDGER = "workspace/confluence-publications.jsonl"


def transient_source(path: str) -> bool:
    """True when the ledger key would live in scratch space.

    `ledger-lookup` resolves create-vs-update on this exact path, so a key under
    workspace/tmp/ stops matching once scratch is cleaned.
    """
    parts = os.path.normpath(path).split(os.sep)
    return any(
        first == "workspace" and second == "tmp"
        for first, second in zip(parts, parts[1:])
    )


def read_ledger(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    records = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return records


def cmd_ledger_append(args) -> int:
    source = os.path.abspath(args.source)
    if transient_source(source) and not args.allow_transient_source:
        sys.stderr.write(
            "ERROR: transient ledger source: %s\n"
            "Re-publishes key on this exact path, so a cleaned scratch dir turns every "
            "page back into a create and duplicates the Confluence family. Pass the durable "
            "artifact you published from (the promoted report), or --allow-transient-source "
            "when the publication really is throwaway.\n" % source
        )
        return 2
    record = {
        "published_at": args.published_at,
        "source_path": source,
        "source_sha256": args.source_sha256,
        "cloud_id": args.cloud_id,
        "space_key": args.space_key,
        "page_index": args.page_index,
        "page_id": args.page_id,
        "parent_page_id": args.parent_page_id,
        "page_url": args.page_url,
        "format": args.format,
        "body_bytes": args.body_bytes,
        "published_body_sha256": args.published_body_sha256,
        "assets": args.asset or [],
    }
    os.makedirs(os.path.dirname(args.ledger) or ".", exist_ok=True)
    with open(args.ledger, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
    print("appended page_index=%s page_id=%s" % (args.page_index, args.page_id))
    return 0


def cmd_ledger_lookup(args) -> int:
    """Resolve what a re-publish should do per page.

    Keyed on (source_path, page_index), not source_path alone: a run that dies
    after child 2 of 4 would otherwise resolve to a single update of the parent
    and silently lose the untouched tail.
    """
    source = os.path.abspath(args.source)
    stem = re.sub(r"[-_]?\d{4}-\d{2}(-\d{2})?$", "", os.path.splitext(os.path.basename(source))[0])

    latest: dict[int, dict] = {}
    family: list[dict] = []
    for record in read_ledger(args.ledger):
        if record.get("source_path") == source:
            latest[record.get("page_index", 0)] = record
        else:
            other = os.path.splitext(os.path.basename(record.get("source_path", "")))[0]
            if stem and re.sub(r"[-_]?\d{4}-\d{2}(-\d{2})?$", "", other) == stem:
                family.append(record)

    actions = []
    for index in range(args.pages):
        prior = latest.get(index)
        actions.append(
            {
                "page_index": index,
                "action": "update" if prior else "create",
                "page_id": prior.get("page_id") if prior else None,
                "page_url": prior.get("page_url") if prior else None,
                "published_body_sha256": prior.get("published_body_sha256") if prior else None,
            }
        )
    orphans = [
        {"page_index": index, "page_id": rec.get("page_id"), "page_url": rec.get("page_url")}
        for index, rec in sorted(latest.items())
        if index >= args.pages
    ]

    result = {
        "source_path": source,
        "actions": actions,
        "orphans": orphans,
        "prior_family": sorted(
            {(r.get("source_path"), r.get("page_url")) for r in family}
        )[:5],
    }
    print(json.dumps(result, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    plan_parser = sub.add_parser("plan")
    plan_parser.add_argument("--source", required=True)
    plan_parser.add_argument("--out-dir", required=True)
    plan_parser.add_argument("--title")
    plan_parser.add_argument("--rasterize", action="append", default=[])
    plan_parser.add_argument("--no-rasterize", action="store_true")
    plan_parser.add_argument("--rasterize-only", action="append", default=[])
    plan_parser.add_argument("--split-threshold", type=int)
    plan_parser.set_defaults(func=cmd_plan)

    render_parser = sub.add_parser("render")
    render_parser.add_argument("--plan", required=True)
    render_parser.set_defaults(func=cmd_render)

    append_parser = sub.add_parser("ledger-append")
    append_parser.add_argument("--ledger", default=LEDGER)
    append_parser.add_argument("--source", required=True)
    append_parser.add_argument("--source-sha256", default="")
    append_parser.add_argument("--cloud-id", default="")
    append_parser.add_argument("--space-key", default="")
    append_parser.add_argument("--page-index", type=int, required=True)
    append_parser.add_argument("--page-id", required=True)
    append_parser.add_argument("--parent-page-id")
    append_parser.add_argument("--page-url", default="")
    append_parser.add_argument("--format", default="html")
    append_parser.add_argument("--body-bytes", type=int, default=0)
    append_parser.add_argument("--published-body-sha256", default="")
    append_parser.add_argument("--published-at", required=True)
    append_parser.add_argument("--asset", action="append", default=[])
    append_parser.add_argument("--allow-transient-source", action="store_true")
    append_parser.set_defaults(func=cmd_ledger_append)

    attach_parser = sub.add_parser("attach")
    attach_parser.add_argument("--plan", required=True)
    attach_parser.add_argument("--page-index", type=int, default=0)
    attach_parser.add_argument("--page-id", required=True)
    attach_parser.add_argument("--site", default="")
    attach_parser.add_argument("--account", required=True)
    attach_parser.add_argument("--keychain-service", default=KEYCHAIN_SERVICE)
    attach_parser.set_defaults(func=cmd_attach)

    lookup_parser = sub.add_parser("ledger-lookup")
    lookup_parser.add_argument("--ledger", default=LEDGER)
    lookup_parser.add_argument("--source", required=True)
    lookup_parser.add_argument("--pages", type=int, required=True)
    lookup_parser.set_defaults(func=cmd_ledger_lookup)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
