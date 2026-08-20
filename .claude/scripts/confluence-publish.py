#!/usr/bin/env python3
"""Convert a local Markdown/HTML artifact into Confluence-ready page bodies.

Two subcommands, and the split between them is deliberate:

    plan    parse, classify visuals, emit page bodies, measure, split
    render  rasterize the SVG charts the placeholders point at

`plan` owns the split because it owns the measurement. Emitting needs no
browser, so it produces the real bodies and splits on real bytes; a split
computed from an estimate and only checked later would let a user confirm
"single page" and then hard-fail with no re-split path.

Neither subcommand touches the network or the Atlassian MCP. That boundary is
what makes the conversion testable without Confluence credentials.

See .claude/docs/confluence-publish-conversion.md for the mapping contract.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from html.parser import HTMLParser

EXIT_OVERSIZE = 3
EXIT_NESTING = 4

CAP_BYTES = 60000
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

DROP_TREE = frozenset("style script head nav footer canvas svg".split())

UNWRAP = frozenset("div span section article main header aside figure figcaption i b".split())

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

MIN_CHART_TEXT = 20


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
    def __init__(self, source_text: str, rasterize: list[str], no_rasterize: bool):
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
        self.pending_text: list[str] = []
        self.last_char = " "
        self.gap_pending = False
        self.visual_seq = 0
        self.dropped_subtrees = 0
        self.current_heading = ""

        self.svg_start: int | None = None
        self.svg_depth = 0

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

    def open_block(self, level=None, heading="") -> None:
        if self.block.html or self.block.visuals:
            self.blocks.append(Block(level, heading))
        else:
            self.block.level = level
            self.block.heading = heading

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

        if self.svg_start is not None:
            if tag == "svg":
                self.svg_depth += 1
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
                self.svg_start = self.abs_offset()
                self.svg_depth = 1
            else:
                self.drop_depth = 1
            return

        if tag in VOID:
            if tag in ("br", "hr"):
                self.emit("<%s />" % tag)
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
                self.check_nesting("panel")
                self.stack.append("panel")
                if not self.stack[:-1]:
                    self.open_block()
                self.emit('<div data-type="%s">' % panel)
            else:
                self.stack.append("~unwrap")
                self.emit_gap()
            return

        if tag not in PASSTHROUGH:
            self.stack.append("~unwrap")
            self.emit_gap()
            return

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
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.svg_start is None and not self.drop_depth:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if self.svg_start is not None:
            if tag == "svg":
                self.svg_depth -= 1
                if self.svg_depth == 0:
                    end = self.source_text.find(">", self.abs_offset()) + 1
                    self.capture_visual(self.source_text[self.svg_start:end])
                    self.svg_start = None
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

        if self.stack and self.stack[-1] == "panel" and tag == "div":
            self.stack.pop()
            self.emit("</div>")
            return
        if tag in UNWRAP or tag not in PASSTHROUGH:
            if self.stack and self.stack[-1] == "~unwrap":
                self.stack.pop()
            self.emit_gap()
            return
        if tag in self.stack:
            while self.stack and self.stack[-1] != tag:
                self.stack.pop()
            if self.stack:
                self.stack.pop()
        self.emit("</%s>" % tag)
        if tag in HEADINGS and not self.block.heading:
            self.block.heading = self.current_heading

    def handle_data(self, data):
        if self.svg_start is not None:
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
        if not self.stack:
            self.open_block()
            self.emit("<p>%s</p>" % escape(data.strip()))
            return
        if self.stack[-1] in HEADINGS:
            self.current_heading += data.strip()
        self.emit(escape(data))

    # ---- visuals ----------------------------------------------------------
    def capture_visual(self, svg_markup: str) -> None:
        self.visual_seq += 1
        name = "chart-%02d.png" % self.visual_seq
        width, height = viewbox_dimensions(svg_markup)
        chart_text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", svg_markup)).strip()

        placeholder = (
            '<div data-type="panel-info"><p><strong>Chart:</strong> %s'
            " &mdash; attach <code>%s</code> here.</p></div>"
            % (escape(self.current_heading or "chart %d" % self.visual_seq), name)
        )
        if len(chart_text) >= MIN_CHART_TEXT:
            placeholder += (
                "<details><summary>Chart data (text)</summary><p>%s</p></details>"
                % escape(chart_text)
            )
        if not self.stack:
            self.open_block()
        self.emit(placeholder)
        self.block.visuals.append(
            {
                "id": self.visual_seq,
                "png": name,
                "width": width,
                "height": height,
                "text_chars": len(chart_text),
                "placeholder": placeholder,
                "markup": svg_markup,
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
    return cut.rstrip(" ,;:—-") + "…"


def page_title(base: str, page: list[Block], index: int, carried: str) -> tuple[str, str]:
    """Return (title, heading to carry forward). A page produced by a
    block-boundary break has no heading of its own, so it continues the last
    heading seen rather than degrading to "part N"."""
    own = next((b.heading for b in page if b.heading), "")
    heading = own or carried
    if index == 0:
        return clamp(base, TITLE_LIMIT), heading
    if own:
        title = "%s — %s" % (base, clamp(own, HEADING_FRAGMENT_LIMIT))
    elif carried:
        title = "%s — %s (cont. %d)" % (base, clamp(carried, HEADING_FRAGMENT_LIMIT), index + 1)
    else:
        title = "%s — part %d" % (base, index + 1)
    return clamp(title, TITLE_LIMIT), heading


def cmd_plan(args) -> int:
    source_path = os.path.abspath(args.source)
    raw = open(source_path, encoding="utf-8").read()
    kind = "markdown" if source_path.lower().endswith((".md", ".markdown")) else "html"
    threshold = args.split_threshold or DEFAULT_THRESHOLD[kind]
    warnings: list[str] = []

    if kind == "markdown":
        head_title, blocks, warnings = markdown_blocks(raw)
        dropped = 0
    else:
        emitter = HtmlPlusEmitter(raw, args.rasterize or [], args.no_rasterize)
        try:
            emitter.feed(raw)
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
    pages = []
    carried_heading = ""
    for index, page in enumerate(pages_blocks):
        body = "".join(b.text() for b in page)
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
                    {k: v[k] for k in ("id", "png", "width", "height", "text_chars", "status")}
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


def cmd_render(args) -> int:
    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    markup = plan.get("_visual_markup", {})
    if not markup:
        print("no visuals to render")
        return 0

    out_dir = os.path.dirname(os.path.abspath(args.plan))
    assets = os.path.join(out_dir, "assets")
    os.makedirs(assets, exist_ok=True)
    chrome = find_chrome()
    style = plan.get("_style", "")

    for page in plan["pages"]:
        for visual in page["visuals"]:
            svg = markup.get(str(visual["id"]), "")
            width = visual["width"] or 1040
            height = visual["height"] or 600
            target = os.path.join(assets, visual["png"])

            if not chrome:
                visual["status"] = "skipped:no-renderer"
                continue

            # The source sizes its charts through CSS that dies the moment the
            # element leaves its ancestor chain, so pin the viewBox dimensions
            # onto the element instead of inheriting them.
            sized = re.sub(r"<svg\b", '<svg width="%d" height="%d"' % (width, height), svg, count=1)
            doc = (
                '<!doctype html><html data-theme="light"><head><meta charset="utf-8">'
                "<style>%s\nbody{margin:0;background:#fff}</style></head><body>%s</body></html>"
                % (style, sized)
            )
            html_path = os.path.join(assets, "visual-%02d.html" % visual["id"])
            with open(html_path, "w", encoding="utf-8") as handle:
                handle.write(doc)

            argv = [
                chrome,
                "--headless",
                "--disable-gpu",
                "--disable-javascript",
                "--hide-scrollbars",
                "--force-device-scale-factor=2",
                "--default-background-color=ffffffff",
                "--window-size=%d,%d" % (width, height),
                "--screenshot=%s" % target,
                "file://%s" % html_path,
            ]
            try:
                subprocess.run(argv, capture_output=True, timeout=30, check=False)
            except subprocess.TimeoutExpired:
                visual["status"] = "skipped:render-timeout"
                continue
            visual["status"] = "rendered" if os.path.exists(target) else "skipped:no-output"
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


LEDGER = "workspace/confluence-publications.jsonl"


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
    record = {
        "published_at": args.published_at,
        "source_path": os.path.abspath(args.source),
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
    append_parser.set_defaults(func=cmd_ledger_append)

    lookup_parser = sub.add_parser("ledger-lookup")
    lookup_parser.add_argument("--ledger", default=LEDGER)
    lookup_parser.add_argument("--source", required=True)
    lookup_parser.add_argument("--pages", type=int, required=True)
    lookup_parser.set_defaults(func=cmd_ledger_lookup)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
