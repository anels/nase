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
import base64
import hashlib
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from confluence_html_emitter import HtmlPlusEmitter
from confluence_markup import (
    CAP_BYTES,
    CLASS_ATTR,
    DEFAULT_CONTENT_WIDTH,
    DEFAULT_TABLE_WIDTH,
    DEFAULT_THRESHOLD,
    EXIT_BLANK_VISUAL,
    EXIT_NESTING,
    EXIT_OVERSIZE,
    KEYCHAIN_TIMEOUT_SECONDS,
    REPO_ROOT,
    TOC_EXPAND,
    Block,
    NestingViolationError,
    blank_svg_count,
    content_width,
    ensure_blockquote_paragraphs,
    group_note_runs,
    has_chart_primitive,
    layout_classes,  # noqa: F401  (re-exported for tests/scripts/test-confluence-publish.sh)
    size_tables,
    source_has_toc,
    unresolving_font_stacks,
)


def markdown_blocks(text: str) -> tuple[str, list[Block], list[str]]:
    warnings = []
    body = text
    if body.startswith("---\n"):
        end = body.find("\n---", 4)
        if end != -1:
            body = body[body.find("\n", end + 1) + 1 :]

    title = ""
    lines = body.splitlines(keepends=True)
    if lines and lines[0].startswith("# "):
        title = lines[0][2:].strip()
        lines = lines[1:]

    for pattern, message in (
        (
            r"^!\[[^\]]*\]\(",
            "local image reference: markdown passthrough cannot carry it",
        ),
        (
            r"^```mermaid",
            "mermaid fence: markdown passthrough renders it as plain code",
        ),
    ):
        if re.search(pattern, body, re.MULTILINE):
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


def page_title(
    base: str, page: list[Block], index: int, carried: str
) -> tuple[str, str]:
    """Return (title, heading to carry forward). A page produced by a
    block-boundary break has no heading of its own, so it continues the last
    heading seen rather than degrading to "part N"."""
    own = next((b.heading for b in page if b.heading), "")
    heading = own or carried
    if index == 0:
        return clamp(base, TITLE_LIMIT), heading
    if own:
        title = f"{base} - {clamp(own, HEADING_FRAGMENT_LIMIT)}"
    elif carried:
        title = (
            f"{base} - {clamp(carried, HEADING_FRAGMENT_LIMIT)} (cont. {index + 1})"
        )
    else:
        title = f"{base} - part {index + 1}"
    return clamp(title, TITLE_LIMIT), heading


def cmd_plan(args) -> int:
    source_path = os.path.abspath(args.source)
    raw = Path(source_path).read_text(encoding="utf-8")
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
        except NestingViolationError as exc:
            sys.stderr.write(
                f"NESTING: {exc.description}, under {exc.context}.\n"
                "Confluence rejects this construct. Restructure the source, or "
                "publish that section separately.\n"
            )
            return EXIT_NESTING
        head_title = emitter.title_from_head
        blocks = [b for b in emitter.blocks if b.text().strip() or b.visuals]
        dropped = emitter.dropped_subtrees

        if emitter.unlinked:
            warnings.append(
                f"{emitter.unlinked} in-page link(s) pointed at something Confluence "
                "cannot address - a paragraph-level anchor rather than a heading - so "
                "the label was kept and the link dropped. Anchor the target on a "
                "heading in the source if those jumps matter."
            )
        if emitter.stray_table_text:
            warnings.append(
                f"dropped {len(emitter.stray_table_text)} text run(s) sitting inside "
                "a table but outside any cell - the source markup is malformed "
                f"there: {', '.join(emitter.stray_table_text[:6])}"
            )
        prose_images = [
            visual["png"]
            for block in emitter.blocks
            for visual in block.visuals
            if not has_chart_primitive(visual["markup"]) and visual["text_chars"]
        ]
        if prose_images:
            warnings.append(
                f"{len(prose_images)} rasterized block(s) contain no bar, track, "
                "spark, meter or svg, so they are most likely prose being turned into "
                "an image - and an imaged block stops being searchable, copyable and "
                f"clickable: {', '.join(prose_images)}. Scope the capture with "
                "--rasterize-only <class> if that is not intended."
            )
        blank_visuals = [
            visual["png"]
            for block in emitter.blocks
            for visual in block.visuals
            if blank_svg_count(visual["markup"])
        ]
        if blank_visuals:
            sys.stderr.write(
                f"BLANK VISUAL: {len(blank_visuals)} captured chart(s) hold an "
                "<svg> with nothing drawable inside it: "
                f"{', '.join(blank_visuals)}.\n"
                "The capture pass runs with --disable-javascript, so a chart drawn at "
                "page load images as a blank rectangle while `render` still reports "
                "`rendered`. Emit the shapes into the markup at build time "
                "(.claude/scripts/chart-svg.py does this), or remove the element.\n"
            )
            return EXIT_BLANK_VISUAL
        if not args.no_rasterize:
            unresolving = unresolving_font_stacks(raw)
            if unresolving:
                warnings.append(
                    f"{len(unresolving)} font stack(s) do not end in a family "
                    "headless Chrome resolves, so the rasterized charts publish in "
                    "serif while the source looks sans-serif in a browser: "
                    f"{'; '.join(unresolving[:6])}. End each stack with sans-serif, "
                    "serif, monospace, cursive, fantasy or system-ui - note that "
                    "ui-sans-serif, ui-serif, ui-monospace and -apple-system do not "
                    "resolve on their own."
                )
        if args.rasterize_only:
            # A named class that exists but never captured sits inside another named
            # container - redundant, not a typo - so `present` excuses it.
            present = {
                token.lower()
                for value in CLASS_ATTR.findall(raw)
                for token in value.split()
            }
            missing = sorted(
                emitter.grid_classes - emitter.matched_grid_classes - present
            )
            if missing:
                warnings.append(
                    f"--rasterize-only named {', '.join(missing)}, which matched "
                    "nothing in the source - a typo leaves the real charts unwrapped "
                    "into label soup with no image to replace them"
                )

    title = resolve_title(args.title, head_title, blocks, source_path)
    if (
        kind == "html"
        and blocks
        and blocks[0].level == 1
        and blocks[0].heading.strip() == title.strip()
    ):
        # Strip only the duplicated <h1> element. The block also carries the
        # content that follows it, including any chart placeholder, so dropping
        # the whole block silently deletes the top of the document.
        first = blocks[0]
        without_h1 = re.sub(
            r"^\s*<h1>.*?</h1>\s*", "", first.text(), count=1, flags=re.DOTALL
        )
        first.html = [without_h1]
        first.level = None
        first.heading = ""
        blocks = [b for b in blocks if b.text().strip() or b.visuals]

    # `auto` mirrors the source: a report that shipped a navigation sidebar was
    # written to be navigated, and that sidebar is a fixed-position container the
    # converter drops - so without this the longest documents lose the only way
    # through them. A report that never had one does not get one invented.
    want_toc = kind == "html" and (
        args.toc == "always"
        or (args.toc == "auto" and source_has_toc(raw) and len(blocks) > 2)
    )

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
        if kind == "html":
            # Shaping runs after the split because the split threshold measures
            # content, and these add presentation: folding notes and stamping
            # column widths must not be what decides a report ships as two pages
            # with inbound links landing on page 1 of 2. The CAP_BYTES check
            # below still sees the shaped bytes, so a page that genuinely
            # overflows is still refused rather than published broken.
            if not args.no_group_notes:
                body = group_note_runs(body, args.note_run)
            body = ensure_blockquote_paragraphs(body)
            if not args.no_colwidth:
                body = size_tables(body, DEFAULT_TABLE_WIDTH)
            if index == 0 and want_toc:
                body = TOC_EXPAND + body
        nbytes = len(body.encode("utf-8"))
        if nbytes > CAP_BYTES:
            heading = next((b.heading for b in page if b.heading), "(untitled section)")
            biggest = max(b.nbytes() for b in page)
            sys.stderr.write(
                f"OVERSIZE: page {index} ({heading!r}) is {nbytes} bytes, over the "
                f"{CAP_BYTES} cap, and its largest single block is {biggest} bytes so "
                "no boundary can break it.\n"
                "Split that block in the source - a long table or code listing is the "
                "usual cause - or publish it as its own document.\n"
            )
            return EXIT_OVERSIZE
        body_file = os.path.join(args.out_dir, f"page-{index:03d}.body.{ext}")
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
                "bytes_without_visuals": sum(
                    b.nbytes(with_visuals=False) for b in page
                ),
                "visuals": [
                    {
                        k: v[k]
                        for k in (
                            "id",
                            "png",
                            "width",
                            "height",
                            "text_chars",
                            "kind",
                            "status",
                        )
                    }
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
        "_content_width": content_width(raw)
        if kind == "html"
        else DEFAULT_CONTENT_WIDTH,
    }
    plan_path = os.path.join(args.out_dir, "plan.json")
    with open(plan_path, "w", encoding="utf-8") as handle:
        json.dump(plan, handle, indent=2)

    total_visuals = sum(len(p["visuals"]) for p in pages)
    print(f"source      {source_path} ({kind})")
    print(f"title       {title}")
    print(f"pages       {len(pages)} (threshold {threshold} B)")
    for page in pages:
        print(
            f"  [{page['index']}] {page['title'][:58]:<58} {page['bytes']:7d} B  "
            f"{len(page['visuals'])} chart(s)"
        )
    print(
        f"charts      {total_visuals} to rasterize, {dropped} chart-class subtrees dropped"
    )
    print(f"without visuals: {without_total} B total")
    for warning in warnings:
        print(f"warning     {warning}")
    print(f"plan        {plan_path}")
    return 0


def extract_styles(raw: str) -> str:
    return "\n".join(re.findall(r"<style[^>]*>(.*?)</style>", raw, re.DOTALL))


def find_chrome() -> str | None:
    for candidate in (
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ):
        if os.path.exists(candidate):
            return candidate
    return shutil.which("google-chrome") or shutil.which("chromium")


DARK_MEDIA = re.compile(r"@media[^{]*prefers-color-scheme\s*:\s*dark[^{]*\{")

# Breathing room the capture block puts around a visual on every side. A block
# whose height is measured absorbs it; an `<svg>` whose size is pinned from its
# viewBox does not, so the capture window has to account for it explicitly.
BLOCK_PADDING = 12


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
        if measure
        else ""
    )
    return (
        '<!doctype html><html data-theme="light"><head><meta charset="utf-8">'
        f"<style>{force_light(style)}\nhtml,body{{margin:0;padding:0;background:#fff}}"
        f".__shim{{width:{width}px;padding:0;margin:0;max-width:none}}"
        f".__block{{display:inline-block;width:{width}px;padding:{BLOCK_PADDING}px;"
        "box-sizing:border-box}"
        f"</style>{probe}</head>"
        f'<body><div class="wrap __shim"><div class="__block">{markup}</div></div></body></html>'
    )


def measure_height(chrome: str, path: str, width: int) -> int:
    """Chrome screenshots a viewport, not an element, so the height has to be
    read back before the capture or every PNG carries a tail of blank page."""
    argv = [
        chrome,
        "--headless",
        "--disable-gpu",
        "--hide-scrollbars",
        "--virtual-time-budget=4000",
        f"--window-size={width},800",
        "--dump-dom",
        f"file://{path}",
    ]
    try:
        done = subprocess.run(
            argv, capture_output=True, timeout=30, text=True, check=False
        )
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
                svg_width = visual["width"] or page_width
                svg_height = visual["height"] or 600
                markup = re.sub(
                    r"<svg\b",
                    f'<svg width="{svg_width}" height="{svg_height}"',
                    markup,
                    count=1,
                )
                # A window sized to the viewBox alone loses BLOCK_PADDING off
                # the right and bottom edge, because the block's padding shifts
                # the element down and right inside it - taking the chart's own
                # frame, its last x tick and its bottom row of cells with it.
                # The grown size is recorded because the media node declares it.
                doc_width = svg_width + 2 * BLOCK_PADDING
                height = svg_height + 2 * BLOCK_PADDING
                visual["width"], visual["height"] = doc_width, height
            else:
                doc_width = page_width
                height = 0

            html_path = os.path.join(assets, f"visual-{visual['id']:02d}.html")
            if not height:
                with open(html_path, "w", encoding="utf-8") as handle:
                    handle.write(
                        render_document(style, markup, doc_width, measure=True)
                    )
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
                f"--window-size={doc_width},{height}",
                f"--screenshot={target}",
                f"file://{html_path}",
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
        print(f"{status:<24} {count}")
    print(f"assets      {assets}")
    return 0


KEYCHAIN_SERVICE = "nase-confluence"
ATTACH_PATH = "/wiki/rest/api/content/%s/child/attachment"


TOKEN_ENV = "CONFLUENCE_API_TOKEN"  # noqa: S105 - the variable name, not its value


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
    keychain_timed_out = False
    if shutil.which("security"):
        try:
            # `security` normally answers instantly, but an item whose ACL requires
            # confirmation makes it sit on a GUI prompt that a headless run can never
            # answer. Time out into the environment path instead of hanging the publish.
            done = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-w",
                    "-s",
                    service,
                    "-a",
                    account,
                ],
                capture_output=True,
                text=True,
                timeout=KEYCHAIN_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired:
            # Bound no name to the exception: its captured stdout holds a partial read
            # of this buffer, which is a fragment of the token.
            keychain_timed_out = True
        else:
            if done.returncode == 0 and done.stdout.strip():
                return done.stdout.strip()

    from_env = os.environ.get(TOKEN_ENV, "").strip()
    if from_env:
        return from_env

    if keychain_timed_out:
        # The stored item is very likely fine, so telling the user to add one would send
        # them to fix the wrong thing.
        raise RuntimeError(
            f"the keychain lookup for {account!r} did not answer within "
            f"{KEYCHAIN_TIMEOUT_SECONDS}s, and {TOKEN_ENV} is unset.\n"
            "  A keychain item whose ACL asks for confirmation blocks until someone clicks the\n"
            "  prompt, which a headless run cannot do. Either approve it once in the GUI and\n"
            "  choose Always Allow, or bypass the keychain for this run:\n"
            f"    export {TOKEN_ENV}=<token>"
        )

    raise RuntimeError(
        f"no Atlassian API token found for {account!r}.\n"
        f"  macOS:     security add-generic-password -U -s {service} -a {account} -w\n"
        "             (then paste the token at the prompt)\n"
        f"  elsewhere: export {TOKEN_ENV}=<token>\n"
        "Create the token at https://id.atlassian.com/manage-profile/security/api-tokens"
    )


def multipart(fields: dict, filename: str, payload: bytes) -> tuple[bytes, str]:
    boundary = "----nase" + hashlib.sha256(filename.encode()).hexdigest()[:24]
    out = []
    for key, value in fields.items():
        out.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode()
        )
    out.append(
        (
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            "Content-Type: image/png\r\n\r\n"
        ).encode()
    )
    out.append(payload)
    out.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


def open_https(request: urllib.request.Request, timeout: int):
    """Open an https request, refusing any other scheme.

    Every URL here is built from an `https://{site}/...` literal today. The check
    costs nothing and catches the call site that one day takes a URL from data,
    where `file:` would turn an upload into a local-file read.
    """
    if request.type != "https":
        raise RuntimeError(f"refusing a non-https request: {request.full_url}")
    return urllib.request.urlopen(request, timeout=timeout)  # noqa: S310


def post_png(url: str, email: str, token: str, path: str) -> dict:
    name = os.path.basename(path)
    body, content_type = multipart(
        {"minorEdit": "true"}, name, Path(path).read_bytes()
    )
    # `open_https` below refuses anything but https, so the scheme is checked before
    # a byte is sent.
    request = urllib.request.Request(url, data=body, method="POST")  # noqa: S310
    request.add_header("Content-Type", content_type)
    request.add_header("X-Atlassian-Token", "nocheck")
    request.add_header(
        "Authorization",
        "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode(),
    )
    with open_https(request, 60) as response:
        return json.loads(response.read().decode())


def upload_attachment(
    site: str, email: str, token: str, page_id: str, path: str
) -> dict:
    return post_png(f"https://{site}{ATTACH_PATH % page_id}", email, token, path)


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
        f"https://{site}{ATTACH_PATH % page_id}/{attachment_id}/data",
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
        f"https://{site}/wiki/api/v2/pages/{page_id}/attachments?limit=250"
    )
    request.add_header(
        "Authorization",
        "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode(),
    )
    try:
        with open_https(request, 30) as response:
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
    r"(?:(?!</div>).)*?attach <code>%s</code>(?:(?!</div>).)*?</p></div>"
)


def replace_placeholder(body: str, png: str, node: str) -> tuple[str, bool]:
    """Swap the placeholder panel for the real media node.

    Matched on the PNG filename rather than a remembered string: the panel text
    is regenerated by `plan` and only the filename is guaranteed stable across
    a re-plan.
    """
    pattern = re.compile(PLACEHOLDER_RE % re.escape(png), re.DOTALL)
    updated, count = pattern.subn(node, body, count=1)
    return updated, bool(count)


SITE_RE = re.compile(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.atlassian\.net", re.IGNORECASE)


def validate_site(site: str) -> str:
    """Return `site` only if it is a bare Atlassian Cloud hostname.

    The host is spliced into `https://{site}/...` beside a Basic-auth token, so a value
    such as `evil.example#` or `a.atlassian.net@evil.example` would send the credential
    to another host.
    """
    if not SITE_RE.fullmatch(site):
        raise ValueError(
            f"invalid Atlassian site {site!r}: expected a bare hostname such as "
            "<your-org>.atlassian.net (no scheme, path, port, or userinfo)"
        )
    return site


def resolve_site(explicit: str) -> str:
    """The Atlassian host to upload to.

    Hard-coding one organisation would make this script unusable for anyone
    else, so the default comes from the same `workspace/config.md` entry the
    Jira flows already read.
    """
    if explicit:
        return validate_site(explicit.removeprefix("https://").rstrip("/"))
    # REPO_ROOT is the checkout holding this script; cwd covers a worktree,
    # where `workspace/` is git-ignored and therefore absent.
    for root in (REPO_ROOT, os.getcwd()):
        config = os.path.join(root, "workspace", "config.md")
        if not os.path.exists(config):
            continue
        found = re.search(
            r"^\s*baseUrl:\s*(?:https://)?([A-Za-z0-9.-]+)",
            Path(config).read_text(encoding="utf-8"),
            re.MULTILINE,
        )
        if found:
            return validate_site(found.group(1).rstrip("/"))
    raise RuntimeError(
        "no Atlassian site to upload to. Pass --site <your-org>.atlassian.net, or add "
        "`baseUrl: https://<your-org>.atlassian.net` under `## Jira` in workspace/config.md"
    )


def cmd_attach(args) -> int:
    try:
        site = resolve_site(args.site)
    except ValueError as exc:
        sys.stderr.write(f"{exc}\n")
        return 2
    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)
    out_dir = os.path.dirname(os.path.abspath(args.plan))
    assets = os.path.join(out_dir, "assets")

    page = next((p for p in plan["pages"] if p["index"] == args.page_index), None)
    if page is None:
        sys.stderr.write(f"no page with index {args.page_index} in the plan\n")
        return 2
    # Retry anything not already attached: a failed upload (auth, network) must
    # be re-runnable without hand-editing the plan, and an already-attached
    # visual must not be uploaded twice.
    pending = [v for v in page["visuals"] if v.get("status") != "attached"]
    if not pending:
        print(f"nothing to attach for page {args.page_index}")
        return 0

    token = api_token(args.keychain_service, args.account)
    already = existing_attachments(site, args.account, token, args.page_id)
    body_path = page["body_file"]
    body = Path(body_path).read_text(encoding="utf-8")

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
            visual["status"] = f"attach-failed:http-{exc.code}"
            sys.stderr.write(f"upload {visual['png']} failed: HTTP {exc.code}\n")
            continue
        except (urllib.error.URLError, OSError) as exc:
            visual["status"] = "attach-failed:network"
            sys.stderr.write(f"upload {visual['png']} failed: {exc}\n")
            continue
        if not media_id:
            visual["status"] = "attach-failed:no-media-id"
            continue

        node = (
            f'<figure data-type="media-single" data-layout="center" '
            f'data-width="{visual["width"]}" data-width-type="pixel">'
            '<div data-type="media" data-media-type="file" '
            f'data-id="{media_id}" data-collection="contentId-{args.page_id}" '
            f'data-width="{visual["width"] * 2}" data-height="{visual["height"] * 2}">'
            "</div></figure>"
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
        print(f"{status:<28} {count}")
    print(f"body        {body_path} ({page['bytes']} B)")
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
        for first, second in itertools.pairwise(parts)
    )


def read_ledger(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    records = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped:
                try:
                    records.append(json.loads(stripped))
                except json.JSONDecodeError:
                    continue
    return records


def cmd_ledger_append(args) -> int:
    source = os.path.abspath(args.source)
    if transient_source(source) and not args.allow_transient_source:
        sys.stderr.write(
            f"ERROR: transient ledger source: {source}\n"
            "Re-publishes key on this exact path, so a cleaned scratch dir turns every "
            "page back into a create and duplicates the Confluence family. Pass the durable "
            "artifact you published from (the promoted report), or --allow-transient-source "
            "when the publication really is throwaway.\n"
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
    print(f"appended page_index={args.page_index} page_id={args.page_id}")
    return 0


def cmd_ledger_lookup(args) -> int:
    """Resolve what a re-publish should do per page.

    Keyed on (source_path, page_index), not source_path alone: a run that dies
    after child 2 of 4 would otherwise resolve to a single update of the parent
    and silently lose the untouched tail.
    """
    source = os.path.abspath(args.source)
    stem = re.sub(
        r"[-_]?\d{4}-\d{2}(-\d{2})?$", "", os.path.splitext(os.path.basename(source))[0]
    )

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
                "published_body_sha256": prior.get("published_body_sha256")
                if prior
                else None,
            }
        )
    orphans = [
        {
            "page_index": index,
            "page_id": rec.get("page_id"),
            "page_url": rec.get("page_url"),
        }
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
    plan_parser.add_argument(
        "--no-group-notes",
        action="store_true",
        help="keep every blockquote inline instead of collapsing consecutive runs",
    )
    plan_parser.add_argument(
        "--note-run",
        type=int,
        default=2,
        help="how many consecutive blockquotes make a run worth collapsing (default 2)",
    )
    plan_parser.add_argument(
        "--no-colwidth",
        action="store_true",
        help="leave column widths to Confluence's even split",
    )
    plan_parser.add_argument(
        "--toc",
        choices=("auto", "always", "never"),
        default="auto",
        help="emit a collapsed table of contents: auto mirrors the source (default)",
    )
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
