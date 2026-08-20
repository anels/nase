#!/usr/bin/env bash
# Regression tests for .claude/scripts/confluence-publish.py (plan/render).
# Fixture-driven: no Atlassian credentials and no network are needed.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

SCRIPT=.claude/scripts/confluence-publish.py
FIX=tests/fixtures/confluence-publish
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

plan_of() {
  python3 "$SCRIPT" plan --source "$1" --out-dir "$2" >/dev/null 2>&1
  echo $?
}

jqp() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$1" "$2"; }

# --- void elements: the failure that emitted an empty document -------------
out="$WORK/void"; rc=$(plan_of "$FIX/void-elements.html" "$out")
check "void: plan exits 0" "$rc" "0"
body=$(cat "$out"/page-000.body.html 2>/dev/null)
if [ -n "$body" ]; then pass "void: body is non-empty"; else fail "void: body is non-empty" "empty output"; fi
check "void: title from <title>" "$(jqp "$out/plan.json" "d['title']")" "Void Element Regression"
check_contains "void: content after <head> survives" "$body" "Still emitted."
check_contains "void: br emitted" "$body" "<br />"
check_absent "void: img dropped" "$body" "missing.png"

# --- mapping coverage ------------------------------------------------------
out="$WORK/mapping"; rc=$(plan_of "$FIX/mapping.html" "$out")
check "mapping: plan exits 0" "$rc" "0"
body=$(cat "$out"/page-000.body.html)
check_contains "mapping: colspan preserved"        "$body" '<td colspan="2">'
check_contains "mapping: note panel"               "$body" 'data-type="panel-note"'
check_contains "mapping: warning panel"            "$body" 'data-type="panel-warning"'
check_contains "mapping: error panel"              "$body" 'data-type="panel-error"'
check_contains "mapping: success panel"            "$body" 'data-type="panel-success"'
check_contains "mapping: expand"                   "$body" '<details><summary>'
check_contains "mapping: code language"            "$body" '<code class="language-bash">'
check_contains "mapping: jira inline card"         "$body" 'data-card-appearance="inline"'
check_contains "mapping: plain link stays plain"   "$body" '<a href="https://example.com/plain">'
check_absent   "mapping: plain link not carded"    "$body" 'example.com/plain" data-card-appearance'
check_absent   "mapping: style stripped"           "$body" '<style'
check_absent   "mapping: script stripped"          "$body" '<script'
check_absent   "mapping: html wrapper stripped"    "$body" '<body'
check_absent   "mapping: sparkline dropped"        "$body" 'data-tip'
check_absent   "mapping: viewBox-less svg dropped" "$body" '<circle'
check_absent   "mapping: highlight spans flattened" "$body" '<span'
check_contains "mapping: pre content escaped"      "$body" 'echo hi &amp;&amp; exit 0'
check "mapping: chart subtrees dropped" "$(jqp "$out/plan.json" "d['dropped_chart_subtrees']")" "1"
check "mapping: no rasterizable charts" "$(jqp "$out/plan.json" "sum(len(p['visuals']) for p in d['pages'])")" "0"
# whitespace rule: unwrapped inline spans must not weld
check_contains "mapping: whitespace rule holds" "$body" "100 -&gt; 5"

# --- structural counts are preserved (no transformation path) --------------
src_tables=$(grep -o '<table' "$FIX/mapping.html" | wc -l | tr -d ' ')
out_tables=$(grep -o '<table' "$out"/page-000.body.html | wc -l | tr -d ' ')
check "mapping: table count preserved" "$out_tables" "$src_tables"
src_li=$(grep -o '<li' "$FIX/mapping.html" | wc -l | tr -d ' ')
out_li=$(grep -o '<li' "$out"/page-000.body.html | wc -l | tr -d ' ')
check "mapping: li count preserved" "$out_li" "$src_li"

# --- chart with a viewBox --------------------------------------------------
out="$WORK/chart"; rc=$(plan_of "$FIX/chart-viewbox.html" "$out")
check "chart: plan exits 0" "$rc" "0"
check "chart: one visual detected" "$(jqp "$out/plan.json" "sum(len(p['visuals']) for p in d['pages'])")" "1"
check "chart: viewBox width"  "$(jqp "$out/plan.json" "d['pages'][0]['visuals'][0]['width']")"  "400"
check "chart: viewBox height" "$(jqp "$out/plan.json" "d['pages'][0]['visuals'][0]['height']")" "200"
body=$(cat "$out"/page-000.body.html)
check_contains "chart: placeholder emitted" "$body" 'attach <code>chart-01.png</code>'
check_contains "chart: chart text preserved" "$body" 'Chart data (text)'
check_contains "chart: chart values searchable" "$body" '2025-10 $91k +4.0%'
check_absent   "chart: svg markup not inlined" "$body" '<svg'

# --- nesting violations are detected, never rewritten ----------------------
for case in table-in-li table-in-panel table-in-cell; do
  out="$WORK/nest-$case"
  rc=$(plan_of "$FIX/nesting-$case.html" "$out")
  check "nesting $case: exits 4" "$rc" "4"
  msg=$(python3 "$SCRIPT" plan --source "$FIX/nesting-$case.html" --out-dir "$out" 2>&1 >/dev/null)
  check_contains "nesting $case: names the construct" "$msg" "NESTING:"
done

# --- markdown passthrough --------------------------------------------------
out="$WORK/md"; rc=$(plan_of "$FIX/digest.md" "$out")
check "markdown: plan exits 0" "$rc" "0"
check "markdown: kind" "$(jqp "$out/plan.json" "d['kind']")" "markdown"
check "markdown: title from leading h1" "$(jqp "$out/plan.json" "d['title']")" "Fixture Digest"
check "markdown: conservative threshold" "$(jqp "$out/plan.json" "d['split_threshold']")" "35000"
body=$(cat "$out"/page-000.body.md)
check_contains "markdown: table passed through" "$body" '| Metric | Value |'
check_contains "markdown: fence passed through" "$body" '```bash'
check_absent   "markdown: h1 title consumed"    "$body" '# Fixture Digest'
warns=$(jqp "$out/plan.json" "len(d['warnings'])")
if [ "$warns" -ge 1 ]; then pass "markdown: warns on local image"; else fail "markdown: warns on local image" "no warnings"; fi

# --- oversize: a single block larger than the cap cannot be split ----------
out="$WORK/big"; big="$WORK/big.html"
python3 - "$big" <<'PY'
import sys
cells = "".join("<tr><td>%s</td></tr>" % ("x" * 200) for _ in range(400))
open(sys.argv[1], "w", encoding="utf-8").write(
    "<html><head><title>Oversize</title></head><body><h1>Oversize</h1>"
    "<table>%s</table></body></html>" % cells)
PY
rc=$(plan_of "$big" "$out")
check "oversize: exits 3" "$rc" "3"
msg=$(python3 "$SCRIPT" plan --source "$big" --out-dir "$out" 2>&1 >/dev/null)
check_contains "oversize: names the cause" "$msg" "largest single block"

# --- every emitted body stays under the hard cap ---------------------------
overs=0
for plan in "$WORK"/*/plan.json; do
  [ -f "$plan" ] || continue
  for body in "$(dirname "$plan")"/page-*.body.*; do
    [ -f "$body" ] || continue
    size=$(wc -c < "$body" | tr -d ' ')
    [ "$size" -gt 60000 ] && overs=$((overs + 1))
  done
done
check "every emitted body is under the 60000 cap" "$overs" "0"

# --- ledger: resume, drift detection, orphans ------------------------------
LEDGER="$WORK/pubs.jsonl"
SRC="$FIX/mapping.html"
for i in 0 1 2; do
  python3 "$SCRIPT" ledger-append --ledger "$LEDGER" --source "$SRC" \
    --page-index "$i" --page-id "90000$i" --page-url "https://wiki/x/$i" \
    --published-at "2026-08-19T00:00:00Z" --published-body-sha256 "sha$i" >/dev/null
done

# a 5-page re-publish must resume: 3 updates + 2 creates, never one update
res=$(python3 "$SCRIPT" ledger-lookup --ledger "$LEDGER" --source "$SRC" --pages 5)
updates=$(printf '%s' "$res" | grep -c '"action": "update"')
creates=$(printf '%s' "$res" | grep -c '"action": "create"')
check "ledger: partial fan-out resumes (updates)" "$updates" "3"
check "ledger: partial fan-out resumes (creates)" "$creates" "2"
check_contains "ledger: carries prior body hash for drift" "$res" '"published_body_sha256": "sha0"'

# a shrinking re-publish reports the stranded child instead of deleting it
res=$(python3 "$SCRIPT" ledger-lookup --ledger "$LEDGER" --source "$SRC" --pages 2)
orphans=$(printf '%s' "$res" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['orphans']))")
check "ledger: shrinking split reports 1 orphan" "$orphans" "1"

# an unrelated source is a clean create, not a false update
res=$(python3 "$SCRIPT" ledger-lookup --ledger "$LEDGER" --source "$FIX/digest.md" --pages 1)
check_contains "ledger: unknown source creates" "$res" '"action": "create"'

# the ledger is append-only: re-appending never rewrites an existing line
before=$(wc -l < "$LEDGER" | tr -d ' ')
python3 "$SCRIPT" ledger-append --ledger "$LEDGER" --source "$SRC" \
  --page-index 0 --page-id "900000" --page-url "https://wiki/x/0" \
  --published-at "2026-08-20T00:00:00Z" --published-body-sha256 "sha0-new" >/dev/null
after=$(wc -l < "$LEDGER" | tr -d ' ')
check "ledger: append-only (line added)" "$after" "$((before + 1))"
res=$(python3 "$SCRIPT" ledger-lookup --ledger "$LEDGER" --source "$SRC" --pages 1)
check_contains "ledger: lookup takes the latest record" "$res" '"published_body_sha256": "sha0-new"'

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'OK: confluence-publish plan/render contract holds\n'
  exit 0
fi
printf 'FAILED: %d assertion(s)\n' "$fails"
exit 1
