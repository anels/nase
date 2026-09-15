#!/usr/bin/env python3
"""Emit static SVG chart fragments for self-contained HTML reports.

Why this exists: `/nase:effort-rollup`'s HTML edition draws every metric pair as
a CSS paired bar, which is correct and needs no library. What CSS cannot draw is
non-rectangular geometry - a treemap of merged PRs by repo, a time-axis line of
merges per day. Reaching for a JavaScript chart library to get those is a trap:
`confluence-publish.py` captures with `--disable-javascript`, so a chart drawn at
page load rasterizes to a blank rectangle while `render` still says `rendered`.

So the geometry is computed here and the shapes ship in the markup. The output is
an `<svg>` fragment with a `viewBox` and no `<script>`, `<link>`, `src=` or
`@import`, which is what the HTML-edition contract requires and what the publish
path rasterizes cleanly.

The three algorithms are ports of d3's, because their outputs are the reference
every reader already recognizes: `d3-scale`'s tick selection, `d3-hierarchy`'s
squarified treemap, and `d3-shape`'s `curveMonotoneX`. Porting rather than
depending keeps the workspace on its declared runtime - git, gh, jq, python3 -
with no node_modules.

Usage:

    python3 .claude/scripts/chart-svg.py treemap --data repos.json
    python3 .claude/scripts/chart-svg.py line --data merges.json

`--data -` reads stdin. Both kinds print the fragment to stdout; paste it into
the report's HTML. `--check` self-tests the three algorithms against values
captured from d3 7.9.0 and exits non-zero on any drift.

Colors come from CSS custom properties the host report defines
(`--chart-1`..`--chart-3`, `--chart-ink`, `--chart-grid`, `--chart-label`), so a
fragment inherits the report's light and dark palettes instead of carrying its
own. Class names deliberately avoid the `bar|bars|track|spark|sparkline|meter|
gauge` tokens: `confluence-publish.py` drops a subtree whose class matches those
as decorative.
"""

from __future__ import annotations

import argparse
import json
import math
import sys

E10 = math.sqrt(50)
E5 = math.sqrt(10)
E2 = math.sqrt(2)
PHI = (1 + math.sqrt(5)) / 2
TREEMAP_INSET = 1

# Every stack ends in a generic headless Chrome actually resolves. `ui-sans-serif`
# and `-apple-system` do not resolve on their own there, so a stack terminated by
# either publishes a serif chart from a sans-serif source.
SANS = "system-ui,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"


def tick_increment(start: float, stop: float, count: int) -> float:
    """d3-array `tickIncrement`. A negative result means a 1/-step increment."""
    step = (stop - start) / max(1, count)
    power = math.floor(math.log10(step)) if step > 0 else 0
    error = step / 10**power
    if error >= E10:
        factor = 10
    elif error >= E5:
        factor = 5
    elif error >= E2:
        factor = 2
    else:
        factor = 1
    if power >= 0:
        return factor * 10**power
    return -(10**-power) / factor


def ticks(start: float, stop: float, count: int) -> list[float]:
    """d3-array `ticks`, ascending, inclusive of both ends when they land on one."""
    if start == stop:
        return [start]
    if stop < start:
        start, stop = stop, start
    step = tick_increment(start, stop, count)
    if step > 0:
        i1 = math.floor(start / step)
        i2 = math.ceil(stop / step)
        if i1 * step < start:
            i1 += 1
        if i2 * step > stop:
            i2 -= 1
        return [(i1 + i) * step for i in range(int(i2 - i1) + 1)]
    inv = -step
    i1 = math.ceil(start * inv)
    i2 = math.floor(stop * inv)
    if i1 / inv < start:
        i1 += 1
    if i2 / inv > stop:
        i2 -= 1
    return [(i1 + i) / inv for i in range(int(i2 - i1) + 1)]


def nice_domain(lo: float, hi: float, count: int) -> tuple[float, float]:
    """d3-scale `nice`: widen the domain outward to whole tick steps."""
    if lo == hi:
        return lo, hi
    if hi < lo:
        lo, hi = hi, lo
    previous = None
    while True:
        step = tick_increment(lo, hi, count)
        if step == previous or step == 0 or not math.isfinite(step):
            return lo, hi
        if step > 0:
            lo = math.floor(lo / step) * step
            hi = math.ceil(hi / step) * step
        else:
            lo = math.ceil(lo * -step) / -step
            hi = math.floor(hi * -step) / -step
        previous = step


def _dice(rows: list[dict], value: float, x0: float, y0: float, x1: float) -> None:
    k = ((x1 - x0) / value) if value else 0
    for node in rows:
        node["y0"], node["y1"] = y0, node["_y1"]
        node["x0"] = x0
        x0 += node["value"] * k
        node["x1"] = x0


def _slice(rows: list[dict], value: float, x0: float, y0: float, y1: float) -> None:
    k = ((y1 - y0) / value) if value else 0
    for node in rows:
        node["x0"], node["x1"] = x0, node["_x1"]
        node["y0"] = y0
        y0 += node["value"] * k
        node["y1"] = y0


def squarify(
    values: list[float], width: float, height: float, padding: float = 3.0
) -> list[dict]:
    """d3-hierarchy `treemapSquarify` over a flat, descending-sorted list.

    Returns one dict per input value with `x0/y0/x1/y1`, in input order. A flat
    list is all this needs: an effort rollup groups by repo or by theme, never
    deeper. Values must be positive; zero and negative entries get an empty rect.
    """
    nodes = [{"index": i, "value": float(v)} for i, v in enumerate(values)]
    order = sorted(nodes, key=lambda n: -n["value"])
    # d3's `paddingInner` semantics: tile an *outset* box, then inset every cell
    # by half the padding. The gap lands between siblings only, and the outer
    # cells stay flush with the chart edge. Insetting the tiling box instead
    # leaves a half-padding margin all the way around and shifts every edge.
    half = padding / 2
    x0, y0 = -half, -half
    x1, y1 = float(width) + half, float(height) + half
    value = sum(n["value"] for n in order if n["value"] > 0)
    i0 = 0
    n = len(order)
    while i0 < n:
        dx, dy = x1 - x0, y1 - y0
        if dx <= 0 or dy <= 0 or value <= 0:
            break
        i1 = i0
        sum_value = 0.0
        while i1 < n and not sum_value:
            sum_value = order[i1]["value"]
            i1 += 1
        min_value = max_value = sum_value
        alpha = max(dy / dx, dx / dy) / (value * PHI)
        beta = sum_value * sum_value * alpha
        min_ratio = max(max_value / beta, beta / min_value) if beta else math.inf
        while i1 < n:
            node_value = order[i1]["value"]
            sum_value += node_value
            min_value = min(min_value, node_value)
            max_value = max(max_value, node_value)
            beta = sum_value * sum_value * alpha
            new_ratio = max(max_value / beta, beta / min_value) if beta else math.inf
            if new_ratio > min_ratio:
                sum_value -= node_value
                break
            min_ratio = new_ratio
            i1 += 1
        row = order[i0:i1]
        if dx < dy:
            edge = (y0 + dy * sum_value / value) if value else y1
            for node in row:
                node["_y1"] = edge
            _dice(row, sum_value, x0, y0, x1)
            y0 = edge
        else:
            edge = (x0 + dx * sum_value / value) if value else x1
            for node in row:
                node["_x1"] = edge
            _slice(row, sum_value, x0, y0, y1)
            x0 = edge
        value -= sum_value
        i0 = i1

    out: list[dict] = [{} for _ in nodes]
    for node in order:
        a0 = node.get("x0", 0.0) + half
        b0 = node.get("y0", 0.0) + half
        a1 = node.get("x1", 0.0) - half
        b1 = node.get("y1", 0.0) - half
        out[node["index"]] = {
            "x0": a0,
            "y0": b0,
            "x1": max(a0, a1),
            "y1": max(b0, b1),
            "value": node["value"],
        }
    return out


def _sign(x: float) -> float:
    return -1.0 if x < 0 else 1.0


def monotone_path(points: list[tuple[float, float]]) -> str:
    """d3-shape `line().curve(curveMonotoneX)` over an x-ascending point list.

    Fritsch-Carlson tangents, so the curve never overshoots a local extreme -
    the reason a merges-per-day line drawn this way cannot imply a negative day.
    """
    if not points:
        return ""
    if len(points) == 1:
        return f"M{_n(points[0][0])},{_n(points[0][1])}"
    if len(points) == 2:
        (x0, y0), (x1, y1) = points
        return f"M{_n(x0)},{_n(y0)}L{_n(x1)},{_n(y1)}"

    n = len(points)
    secant: list[float] = []
    for i in range(n - 1):
        h = points[i + 1][0] - points[i][0]
        secant.append((points[i + 1][1] - points[i][1]) / h if h else 0.0)

    tangent = [0.0] * n
    for i in range(1, n - 1):
        s0, s1 = secant[i - 1], secant[i]
        h0 = points[i][0] - points[i - 1][0]
        h1 = points[i + 1][0] - points[i][0]
        if s0 * s1 <= 0:
            tangent[i] = 0.0
        else:
            p = (s0 * h1 + s1 * h0) / (h0 + h1) if (h0 + h1) else 0.0
            tangent[i] = (_sign(s0) + _sign(s1)) * min(
                abs(s0), abs(s1), 0.5 * abs(p)
            )
    # d3's `slope2` for the two endpoints: one-sided, clamped by its neighbour.
    h = points[1][0] - points[0][0]
    tangent[0] = (3 * secant[0] - tangent[1]) / 2 if h else tangent[1]
    h = points[n - 1][0] - points[n - 2][0]
    tangent[n - 1] = (3 * secant[n - 2] - tangent[n - 2]) / 2 if h else tangent[n - 2]

    parts = [f"M{_n(points[0][0])},{_n(points[0][1])}"]
    for i in range(n - 1):
        (x0, y0), (x1, y1) = points[i], points[i + 1]
        dx = (x1 - x0) / 3
        parts.append(
            f"C{_n(x0 + dx)},{_n(y0 + dx * tangent[i])}"
            f",{_n(x1 - dx)},{_n(y1 - dx * tangent[i + 1])}"
            f",{_n(x1)},{_n(y1)}"
        )
    return "".join(parts)


def _n(value: float) -> str:
    """Trim a coordinate the way d3's path serializer does, to 3 decimals."""
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def esc(text: object) -> str:
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def treemap_svg(
    items: list[dict], width: int, height: int, label_min: int, title: str
) -> str:
    """One rect per item, labelled where the cell can hold the text.

    d3-hierarchy does no label fitting, and an overflowing label is how a
    treemap turns into unreadable clipped text. A cell narrower or shorter than
    `label_min` gets its name in a `<title>` only, which a reader reaches by
    hovering the live HTML - the rasterized PNG loses it either way, which is the
    honest reason to keep the table view beside the chart.
    """
    values = [float(item.get("value", 0)) for item in items]
    # d3's paddingInner puts no margin outside the outermost cells, so their
    # border and corner rounding land on the last pixel row of the viewBox and
    # the chart reads as cut off. Tile a box two pixels smaller and shift it in
    # by one, which keeps `squarify` itself byte-identical to d3.
    cells = squarify(values, width - 2 * TREEMAP_INSET, height - 2 * TREEMAP_INSET)
    parts = [
        f'<svg class="chart-svg chart-treemap" viewBox="0 0 {width} {height}" '
        f'role="img" aria-label="{esc(title)}">'
        f'<g transform="translate({TREEMAP_INSET},{TREEMAP_INSET})">'
    ]
    for item, cell in zip(items, cells, strict=True):
        w = cell["x1"] - cell["x0"]
        h = cell["y1"] - cell["y0"]
        if w <= 0 or h <= 0:
            continue
        name = esc(item.get("name", ""))
        tone = f"var(--chart-{(items.index(item) % 3) + 1})"
        parts.append(
            f'<g><title>{name} ({_n(cell["value"])})</title>'
            f'<rect x="{_n(cell["x0"])}" y="{_n(cell["y0"])}" '
            f'width="{_n(w)}" height="{_n(h)}" rx="3" fill="{tone}"/>'
        )
        if w >= label_min and h >= 26:
            parts.append(
                f'<text class="chart-cell-label" x="{_n(cell["x0"] + 8)}" '
                f'y="{_n(cell["y0"] + 20)}">{name} {_n(cell["value"])}</text>'
            )
        parts.append("</g>")
    parts.append("</g>")
    parts.append(_style_block())
    parts.append("</svg>")
    return "".join(parts)


def line_svg(
    points: list[dict], width: int, height: int, y_label: str, title: str
) -> str:
    """A single monotone line over an ordered categorical or numeric x.

    `x` labels are taken verbatim from the data: the caller already knows
    whether its buckets are days, weeks or sprints, and re-deriving a date scale
    here would invent a time semantics the input does not carry.
    """
    left, right, top, bottom = 52, 16, 18, 34
    inner_w = width - left - right
    inner_h = height - top - bottom
    values = [float(p.get("y", 0)) for p in points]
    # Zero joins the extent so a count chart keeps its real baseline: a series
    # running 8..12 drawn against a 8..12 domain reads as a collapse to nothing.
    lo, hi = nice_domain(min([*values, 0.0]), max([*values, 0.0]), 5)
    span = (hi - lo) or 1.0

    def sx(i: int) -> float:
        return left + (inner_w * i / (len(points) - 1) if len(points) > 1 else 0)

    def sy(v: float) -> float:
        return top + inner_h - (v - lo) / span * inner_h

    parts = [
        f'<svg class="chart-svg chart-line" viewBox="0 0 {width} {height}" '
        f'role="img" aria-label="{esc(title)}">'
    ]
    for tick in ticks(lo, hi, 5):
        y = sy(tick)
        parts.append(
            f'<line class="chart-grid" x1="{left}" x2="{width - right}" '
            f'y1="{_n(y)}" y2="{_n(y)}"/>'
            f'<text class="chart-tick chart-tick-y" x="{left - 8}" '
            f'y="{_n(y + 4)}">{_n(tick)}</text>'
        )
    path = monotone_path([(sx(i), sy(v)) for i, v in enumerate(values)])
    parts.append(f'<path class="chart-ink" d="{path}"/>')
    # Label the ends and the peak. Labelling every bucket is what makes a
    # 30-point line illegible, and those three are the ones a reader asks about.
    peak = values.index(max(values)) if values else 0
    last = len(points) - 1
    for i in sorted({0, last, peak}):
        label = points[i].get("x", "")
        if label == "":
            continue
        # A centred label on the first or last point hangs off the viewBox and
        # gets sliced by the capture. Anchor the two ends inward instead.
        anchor = (
            "chart-tick-start"
            if i == 0
            else "chart-tick-end"
            if i == last
            else "chart-tick-x"
        )
        parts.append(
            f'<text class="chart-tick {anchor}" x="{_n(sx(i))}" '
            f'y="{height - 12}">{esc(label)}</text>'
        )
    if y_label:
        parts.append(
            f'<text class="chart-axis-name" x="{left}" y="12">{esc(y_label)}</text>'
        )
    parts.append(_style_block())
    parts.append("</svg>")
    return "".join(parts)


def _style_block() -> str:
    """Scoped to `.chart-svg` so a fragment cannot restyle the host report."""
    return (
        "<style>"
        f".chart-svg{{font-family:{SANS};max-width:100%;height:auto}}"
        ".chart-svg .chart-cell-label{fill:#fff;font-size:13px;font-weight:600;"
        "font-variant-numeric:tabular-nums}"
        ".chart-svg .chart-tick{fill:var(--chart-label,#6b7280);font-size:11px;"
        "font-variant-numeric:tabular-nums}"
        ".chart-svg .chart-tick-x{text-anchor:middle}"
        ".chart-svg .chart-tick-y{text-anchor:end}"
        ".chart-svg .chart-tick-start{text-anchor:start}"
        ".chart-svg .chart-tick-end{text-anchor:end}"
        ".chart-svg .chart-axis-name{fill:var(--chart-label,#6b7280);font-size:11px}"
        ".chart-svg .chart-grid{stroke:var(--chart-grid,#e5e7eb);stroke-width:1}"
        ".chart-svg .chart-ink{fill:none;stroke:var(--chart-ink,var(--chart-1,#2f6f4f));"
        "stroke-width:2.5;stroke-linejoin:round;stroke-linecap:round}"
        "</style>"
    )


def load(path: str) -> object:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def self_check() -> int:
    """Assert the three ports against values captured from d3 7.9.0."""
    failures: list[str] = []

    def expect(name: str, actual: object, wanted: object) -> None:
        if actual != wanted:
            failures.append(f"{name}: got {actual!r}, want {wanted!r}")

    expect("ticks(0,4200,5)", ticks(0, 4200, 5), [0, 1000, 2000, 3000, 4000])
    expect("ticks(0,12,5)", [int(t) for t in ticks(0, 12, 5)], [0, 2, 4, 6, 8, 10, 12])
    expect("nice_domain(1,11,5)", nice_domain(1, 11, 5), (0, 12))

    # d3: line().x((d,i)=>i*20).y(...).curve(curveMonotoneX) over these points.
    d3_path = (
        "M0,38C6.667,33,13.333,28,20,28C26.667,28,33.333,31,40,31"
        "C46.667,31,53.333,16,60,16C66.667,16,73.333,24,80,24"
        "C86.667,24,93.333,17,100,10"
    )
    expect(
        "monotone_path vs d3 curveMonotoneX",
        monotone_path([(0, 38), (20, 28), (40, 31), (60, 16), (80, 24), (100, 10)]),
        d3_path,
    )

    # d3: treemap().tile(treemapSquarify).size([640,260]).paddingInner(3) over
    # hierarchy({children:[31,18,9,7,4,2]}).sum(d=>d.n).sort desc.
    cells = squarify([31, 18, 9, 7, 4, 2], 640, 260)
    d3_cells = [
        (0.0, 0.0, 277.7465, 260.0),
        (280.7465, 0.0, 522.2676, 172.3333),
        (280.7465, 175.3333, 522.2676, 260.0),
        (525.2676, 0.0, 640.0, 138.6154),
        (525.2676, 141.6154, 600.7559, 260.0),
        (603.7559, 141.6154, 640.0, 260.0),
    ]
    expect(
        "squarify vs d3 treemapSquarify paddingInner(3)",
        [
            (
                round(c["x0"], 4),
                round(c["y0"], 4),
                round(c["x1"], 4),
                round(c["y1"], 4),
            )
            for c in cells
        ],
        d3_cells,
    )
    if any(c["x1"] < c["x0"] or c["y1"] < c["y0"] for c in cells):
        failures.append("squarify produced an inverted rect")

    emitted = treemap_svg(
        [{"name": "a", "value": 3}, {"name": "b", "value": 1}], 200, 100, 60, "t"
    )
    failures.extend(
        f"treemap emitted {banned}"
        for banned in ("<script", "src=", "@import", "<link")
        if banned in emitted
    )
    if 'viewBox="0 0 200 100"' not in emitted:
        failures.append("treemap emitted no viewBox")

    for line in failures:
        sys.stderr.write(f"FAIL  {line}\n")
    if failures:
        return 1
    sys.stdout.write("OK: chart-svg matches the d3 7.9.0 reference values\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    parser.add_argument("kind", choices=["treemap", "line", "check"])
    parser.add_argument("--data", help="JSON file, or - for stdin")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int)
    parser.add_argument("--title", default="")
    parser.add_argument("--y-label", default="")
    parser.add_argument(
        "--label-min",
        type=int,
        default=90,
        help="treemap: suppress a cell's label below this width in px",
    )
    args = parser.parse_args()

    if args.kind == "check":
        return self_check()
    if not args.data:
        parser.error("--data is required for treemap and line")

    payload = load(args.data)
    rows = payload["items"] if isinstance(payload, dict) else payload
    if not isinstance(rows, list) or not rows:
        sys.stderr.write("data must be a non-empty list, or {\"items\": [...]}\n")
        return 2

    if args.kind == "treemap":
        height = args.height or 260
        if any("name" not in r or "value" not in r for r in rows):
            sys.stderr.write("treemap rows need `name` and `value`\n")
            return 2
        sys.stdout.write(
            treemap_svg(rows, args.width, height, args.label_min, args.title)
        )
    else:
        height = args.height or 250
        if any("y" not in r for r in rows):
            sys.stderr.write("line rows need `y` (and optionally `x` for a label)\n")
            return 2
        sys.stdout.write(
            line_svg(rows, args.width, height, args.y_label, args.title)
        )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
