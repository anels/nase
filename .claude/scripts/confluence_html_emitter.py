#!/usr/bin/env python3
"""HtmlPlusEmitter extracted from confluence-publish.py."""

from __future__ import annotations

import re
from html import unescape
from html.parser import HTMLParser

from confluence_markup import (
    CHART_CLASS,
    DROP_TREE,
    HEADINGS,
    INLINE_PASSTHROUGH,
    JIRA_URL,
    LANGUAGE_CLASS,
    NESTING_RULES,
    PANEL_CLASS,
    PASSTHROUGH,
    TAG_ALIAS,
    UNWRAP,
    UNWRAP_INLINE,
    VOID,
    Block,
    NestingViolationError,
    escape,
    heading_anchors,
    layout_classes,
    simple_selector_match,
    viewbox_dimensions,
)


class HtmlPlusEmitter(HTMLParser):
    def __init__(
        self,
        source_text: str,
        rasterize: list[str],
        no_rasterize: bool,
        rasterize_only: list[str] | None = None,
    ):
        super().__init__(convert_charrefs=True)
        self.source_text = source_text
        self.anchors = heading_anchors(source_text)
        self.unlinked = 0
        self.open_links: list[bool] = []
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
            del self.block.html[start - 1 :]

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
                raise NestingViolationError(
                    description, self.current_heading or "(before the first heading)"
                )

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
                self.emit(f'<div data-type="{panel}">')
                self.panel_starts.append(len(self.block.html))
            else:
                self.open_unwrapped(tag)
            return

        if tag not in PASSTHROUGH:
            self.open_unwrapped(tag)
            return

        if tag == "a":
            destination = self.resolve_href(attrs.get("href", ""))
            self.open_links.append(destination is None)
            if destination is None:
                # A link with nowhere to land: an in-page href whose target is
                # not a heading Confluence can address, or an `<a id=...>`
                # anchor carrying no href at all. Keep the label and drop the
                # link. The alternative is worse twice over - an empty
                # `<a href="">` is the exact shape ADF rejects on publish, and a
                # link that survives publication but goes nowhere is a defect
                # the reader finds instead of us.
                self.unlinked += 1
                self.open_auto_p()
                # Unwrap as an inline wrapper, not as `a`: the label sits mid
                # sentence, and closing the implicit paragraph around it would
                # break that sentence into three.
                self.open_unwrapped("span")
                return
            attrs = dict(attrs, href=destination)

        if tag in INLINE_PASSTHROUGH:
            self.open_auto_p()
            self.flush_gap()
        else:
            self.close_auto_p()

        if (
            self.stack
            and self.stack[-1] in ("table", "thead", "tbody", "tr")
            and tag not in ("tr", "td", "th", "thead", "tbody")
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

    def resolve_href(self, href: str) -> str | None:
        """The destination to publish for this link, or None if it has none.

        An external URL passes through. An in-page `#slug` only works once it is
        rewritten to the heading anchor Confluence derives from the heading's own
        text, and a slug that names no heading - a paragraph-level `<a id=...>`
        target, say - has no equivalent at all on a Confluence page.
        """
        href = href.strip()
        if not href:
            return None
        if not href.startswith("#"):
            return href
        anchor = self.anchors.get(href[1:])
        return f"#{anchor}" if anchor else None

    def open_tag_html(self, tag: str, attrs: dict) -> str:
        if tag == "a":
            href = attrs.get("href", "")
            if JIRA_URL.fullmatch(href.strip()):
                return f'<a href="{escape(href)}" data-card-appearance="inline">'
            return f'<a href="{escape(href)}">'
        if tag in ("td", "th"):
            extra = ""
            for key in ("colspan", "rowspan"):
                value = attrs.get(key, "")
                if value.isdigit() and int(value) > 1:
                    extra += f' {key}="{value}"'
            return f"<{tag}{extra}>"
        if tag == "code":
            match = LANGUAGE_CLASS.search(attrs.get("class", ""))
            if match and "pre" in self.stack:
                return f'<code class="language-{match.group(1)}">'
            return "<code>"
        if tag == "table":
            return "<table>"
        return f"<{tag}>"

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
                    markup = self.source_text[self.capture_start : end]
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

        if (
            tag == "div"
            and self.stack[-1:] == ["~autop"]
            and self.stack[-2:-1] == ["panel"]
        ):
            # The panel's own implicit paragraph. Close it before the branch
            # below looks at the top of the stack, or the panel never closes and
            # the next panel reads as a panel nested inside this one.
            self.close_auto_p()
        if self.stack and self.stack[-1] == "panel" and tag == "div":
            self.stack.pop()
            start = (
                self.panel_starts.pop() if self.panel_starts else len(self.block.html)
            )
            inner = "".join(self.block.html[start:])
            # Fallback for a panel whose content the implicit-paragraph rule did
            # not reach: bare inline runs get one paragraph per run from
            # Confluence, which fragments a sentence across lines. Wrap the whole
            # run in a single <p> instead. Panels containing real blocks are left
            # alone - nesting a <p> around them would be invalid.
            if inner.strip() and not re.search(
                r"<(p|table|ul|ol|blockquote|details|h[1-6])[ >]", inner
            ):
                del self.block.html[start:]
                self.block.html.append(f"<p>{inner.strip()}</p>")
            self.emit("</div>")
            return
        dropped_link = False
        if tag == "a" and self.open_links:
            dropped_link = self.open_links.pop()

        if dropped_link or tag in UNWRAP or tag not in PASSTHROUGH:
            # Pop the wrapper's marker from under any open implicit paragraph
            # rather than off the top: the paragraph deliberately outlives the
            # wrapper so consecutive siblings stay in one paragraph, and popping
            # the top here would strand the marker and corrupt the depth count.
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i] == "~unwrap":
                    del self.stack[i]
                    break
            if not dropped_link and tag not in UNWRAP_INLINE:
                self.close_auto_p()
            self.emit_gap()
            return
        if (
            tag == "tr"
            and self.stack
            and self.stack[-1] == "td"
            and (len(self.stack) - 1) in self.auto_cells
        ):
            self.auto_cells.discard(len(self.stack) - 1)
            self.stack.pop()
            self.emit("</td>")
        if tag in self.stack:
            while self.stack and self.stack[-1] != tag:
                self.stack.pop()
            if self.stack:
                self.stack.pop()
        self.emit(f"</{tag}>")
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
            if (
                not data[:1].isspace()
                and self.last_char
                and not self.last_char.isspace()
            ):
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
        name = f"chart-{self.visual_seq:02d}.png"
        is_svg = markup.lstrip().startswith("<svg")
        width, height = viewbox_dimensions(markup) if is_svg else (0, 0)
        chart_text = unescape(re.sub(r"<[^>]+>", " ", markup))
        chart_text = re.sub(r"\s+", " ", chart_text).strip()

        label = escape(self.current_heading or f"chart {self.visual_seq}")
        placeholder = (
            f'<div data-type="panel-info"><p><strong>Chart:</strong> {label}'
            f" - attach <code>{name}</code> here.</p></div>"
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


