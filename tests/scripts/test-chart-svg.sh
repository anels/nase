#!/usr/bin/env bash
# Regression tests for .claude/scripts/chart-svg.py.
#
# Two things are worth pinning. First, the three algorithms are ports, so they
# are asserted against values captured from d3 7.9.0 - `chart-svg.py check`
# owns those and this file just runs it. Second, the emitted fragment has to
# survive `confluence-publish.py`, which drops decorative classes, rasterizes
# with JavaScript off, and refuses an <svg> that draws nothing. A chart helper
# whose output the publish path mangles is worse than no helper.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

CHART=.claude/scripts/chart-svg.py
PUBLISH=.claude/scripts/confluence-publish.py
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n     %s\n' "$1" "$2"; fails=$((fails + 1)); }

check() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then pass "$name"; else fail "$name" "got '$actual', want '$expected'"; fi
}

check_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$name" ;;
    *) fail "$name" "missing '$needle'" ;;
  esac
}

check_absent() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) fail "$name" "unexpected '$needle'" ;;
    *) pass "$name" ;;
  esac
}

# --- the d3 reference values ------------------------------------------------
out=$(python3 "$CHART" check 2>&1)
check "check: matches the d3 7.9.0 reference values" "$?" "0"
check_contains "check: says which version it matched" "$out" "d3 7.9.0"

# --- treemap fragment -------------------------------------------------------
cat >"$WORK/repos.json" <<'JSON'
[{"name":"service-api","value":31},{"name":"service-webapp","value":18},
 {"name":"service-etl","value":9},{"name":"harness-kit","value":7},
 {"name":"deploy-pipeline","value":4},{"name":"docs","value":2}]
JSON
tm=$(python3 "$CHART" treemap --data "$WORK/repos.json" --title "Merged PRs by repo")
check "treemap: exits 0" "$?" "0"
check_contains "treemap: carries a viewBox for the rasterizer" "$tm" 'viewBox="0 0 640 260"'
check_contains "treemap: labels its largest cell" "$tm" "service-api 31"
check_contains "treemap: titles the cells it cannot label" "$tm" "<title>docs (2)</title>"
check_contains "treemap: inherits the report palette" "$tm" "var(--chart-1)"
check_contains "treemap: names the chart for a screen reader" "$tm" 'aria-label="Merged PRs by repo"'

# Nothing that makes the artifact non-self-contained, and no class the
# converter treats as decorative and drops.
for banned in '<script' 'src=' '@import' '<link' 'class="bar' 'class="track' 'class="meter'; do
  check_absent "treemap: no $banned" "$tm" "$banned"
done

# --- line fragment ----------------------------------------------------------
python3 - "$WORK/merges.json" <<'PY'
import json, sys
json.dump(
    [{"x": f"Aug {i + 1}", "y": (i * 7 % 11) + 1} for i in range(30)],
    open(sys.argv[1], "w"),
)
PY
ln=$(python3 "$CHART" line --data "$WORK/merges.json" --title "Merges per day" --y-label merges)
check "line: exits 0" "$?" "0"
check_contains "line: emits a cubic path" "$ln" '<path class="chart-ink" d="M'
check_contains "line: labels the y axis" "$ln" ">merges<"
# A centred label on either end hangs outside the viewBox and the capture slices
# it, so the two ends anchor inward.
check_contains "line: first label anchors start" "$ln" 'chart-tick-start'
check_contains "line: last label anchors end" "$ln" 'chart-tick-end'
check_contains "line: nices the y domain to a whole step" "$ln" ">12<"
check_absent "line: no script" "$ln" "<script"

# --- input validation -------------------------------------------------------
echo '[]' >"$WORK/empty.json"
python3 "$CHART" treemap --data "$WORK/empty.json" >/dev/null 2>&1
check "empty data exits 2" "$?" "2"
echo '[{"name":"a"}]' >"$WORK/novalue.json"
python3 "$CHART" treemap --data "$WORK/novalue.json" >/dev/null 2>&1
check "treemap row without value exits 2" "$?" "2"
echo '[{"x":"a"}]' >"$WORK/noy.json"
python3 "$CHART" line --data "$WORK/noy.json" >/dev/null 2>&1
check "line row without y exits 2" "$?" "2"
printf '%s' "$(cat "$WORK/repos.json")" | python3 "$CHART" treemap --data - >/dev/null 2>&1
check "reads stdin with --data -" "$?" "0"

# --- the fragments survive the publish path --------------------------------
{
  printf '%s' '<!doctype html><html data-theme="light"><head><meta charset="utf-8">'
  printf '%s' '<title>chart-svg through publish</title><style>'
  printf '%s' ':root{--chart-1:#2f6f4f;--chart-2:#4f8f6f;--chart-3:#7fb097;'
  printf '%s' '--chart-grid:#e5e7eb;--chart-label:#6b7280}'
  printf '%s' 'body{background:#fff;font:15px/1.5 system-ui,sans-serif;margin:2rem}'
  printf '%s' '</style></head><body><h1>chart-svg through publish</h1>'
  printf '%s' "$tm"
  printf '%s' "$ln"
  printf '%s' '<p>Merged delivery PRs in month: 71</p></body></html>'
} >"$WORK/report.html"

perr="$WORK/plan.err"
python3 "$PUBLISH" plan --source "$WORK/report.html" --out-dir "$WORK/plan" \
  --title "chart-svg through publish" >/dev/null 2>"$perr"
check "publish: plan accepts both fragments" "$?" "0"
check_absent "publish: neither fragment reads as blank" "$(cat "$perr")" "BLANK VISUAL"

read_plan() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$WORK/plan/plan.json" "$1"; }
check "publish: both captured as svg" "$(read_plan "[v['kind'] for p in d['pages'] for v in p['visuals']]")" "['svg', 'svg']"
check "publish: nothing dropped as decorative" "$(read_plan "d['dropped_chart_subtrees']")" "0"
check "publish: no font warning from our own stacks" "$(read_plan "[w for w in d['warnings'] if 'font stack' in w]")" "[]"
# The labels have to reach the image: a chart the converter counted as text-free
# is the signature of the blank-render failure.
check "publish: labels are present in both captures" \
  "$(read_plan "all(v['text_chars'] > 0 for p in d['pages'] for v in p['visuals'])")" "True"
# The counted headline must land in reader-visible text, not only inside a
# rasterized chart, or it disappears from the published page.
body=$(cat "$WORK/plan"/page-000.body.html 2>/dev/null)
check_contains "publish: the headline count survives conversion" "$body" "Merged delivery PRs in month: 71"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'OK: chart-svg emits publishable static SVG\n'
  exit 0
fi
printf 'FAILED: %d assertion(s)\n' "$fails"
exit 1
