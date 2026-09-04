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
# the image already carries its labels, so a second text copy is page clutter
check_absent   "chart: no text duplicate of the image" "$body" 'Chart data (text)'
check_absent   "chart: svg markup not inlined" "$body" '<svg'

# --- self-closing tags must not leak parser state --------------------------
# A self-closed non-void tag gets a starttag callback and never an endtag. If it
# opened a dropped subtree, the drop counter never returns to zero and every
# element after it is discarded - silently, with exit 0.
out="$WORK/selfclose"; rc=$(plan_of "$FIX/self-closing.html" "$out")
check "self-closing: plan exits 0" "$rc" "0"
body=$(cat "$out"/page-000.body.html)
check_contains "self-closing: survives <i/> in a dropped subtree" "$body" "After a self-closed tag inside"
check_contains "self-closing: survives <svg/>"                    "$body" "After a self-closed viewBox-less svg"
check_contains "self-closing: survives <div class=cards/>"        "$body" "After a self-closed grid container"
check_contains "self-closing: survives <section/>"                "$body" "After a self-closed unwrapped section"
check_contains "self-closing: document tail is not swallowed"     "$body" "Nothing may swallow this."
check_absent   "self-closing: button chrome dropped"              "$body" "Export"

# --- CSS-grid blocks are rasterized, not unwrapped to paragraph soup -------
# A grid lays meaning out in two dimensions; unwrapping it yields a run of
# orphan labels and numbers, so the block is captured and screenshotted whole.
check "grid: one block visual detected" \
  "$(jqp "$out/plan.json" "sum(len(p['visuals']) for p in d['pages'])")" "1"
check "grid: classified as a block, not an svg" \
  "$(jqp "$out/plan.json" "d['pages'][0]['visuals'][0]['kind']")" "block"
check_contains "grid: placeholder emitted"  "$body" 'attach <code>chart-01.png</code>'
check_absent   "grid: rasterized block leaves no text duplicate" "$body" "Runs 1,643,173 Failures 412"
check_absent   "grid: card markup not inlined" "$body" '<strong>Runs</strong>'
# --no-rasterize must turn the block back into ordinary unwrapped content
out="$WORK/selfclose-norast"
python3 "$SCRIPT" plan --source "$FIX/self-closing.html" --out-dir "$out" --no-rasterize >/dev/null 2>&1
check "grid: --no-rasterize emits no visuals" \
  "$(jqp "$out/plan.json" "sum(len(p['visuals']) for p in d['pages'])")" "0"
check_contains "grid: --no-rasterize keeps the content" \
  "$(cat "$out"/page-000.body.html)" "<strong>Runs</strong>"

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
# Read the cap from the script so this assertion cannot drift from the constant
# it guards.
cap=$(grep -Eo '^CAP_BYTES = [0-9]+' "$SCRIPT" | grep -Eo '[0-9]+')
overs=0
for plan in "$WORK"/*/plan.json; do
  [ -f "$plan" ] || continue
  for body in "$(dirname "$plan")"/page-*.body.*; do
    [ -f "$body" ] || continue
    size=$(wc -c < "$body" | tr -d ' ')
    [ "$size" -gt "$cap" ] && overs=$((overs + 1))
  done
done
check "every emitted body is under the $cap-byte cap" "$overs" "0"

# --- attach: the placeholder -> media-node swap ----------------------------
# The only part of `attach` that needs no network, and the part that silently
# no-ops if the panel wording in `capture_visual` drifts from PLACEHOLDER_RE.
swap=$(python3 - "$SCRIPT" "$WORK/selfclose/page-000.body.html" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cp", sys.argv[1])
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)
body = open(sys.argv[2], encoding="utf-8").read()
node = '<figure data-type="media-single"><div data-type="media" data-id="X"></div></figure>'
out, hit = cp.replace_placeholder(body, "chart-01.png", node)
miss_out, miss = cp.replace_placeholder(body, "chart-99.png", node)
print("hit=%s node=%s panel=%s no_expand=%s tail=%s miss=%s intact=%s" % (
    hit,
    node in out,
    "attach <code>chart-01.png</code>" not in out,
    "Chart data (text)" not in out,
    "Nothing may swallow this." in out,
    miss,
    miss_out == body,
))
PY
)
check "attach: placeholder swapped for the media node" "$swap" \
  "hit=True node=True panel=True no_expand=True tail=True miss=False intact=True"

# --- re-attach: a refreshed attachment mints a new media id -----------------
# Embedding the id read from the attachment listing instead would leave the page
# rendering the superseded version while the status still said attached.
mkdir -p "$WORK/selfclose/assets" && : > "$WORK/selfclose/assets/chart-01.png"
reattach=$(python3 - "$SCRIPT" "$WORK/selfclose/plan.json" <<'PY'
import contextlib, importlib.util, io, json, sys, types
spec = importlib.util.spec_from_file_location("cp", sys.argv[1])
cp = importlib.util.module_from_spec(spec)
sys.modules["cp"] = cp
spec.loader.exec_module(cp)

calls = []
cp.api_token = lambda service, account: "token"
cp.resolve_site = lambda site: "example.atlassian.net"
cp.existing_attachments = lambda *a, **k: {
    "chart-01.png": {"id": "att500", "file_id": "stale-media-id"}
}
def fake_update(site, email, token, page_id, attachment_id, path):
    calls.append(("update", attachment_id))
    return {"extensions": {"fileId": "fresh-media-id"}}
def fake_upload(*a, **k):
    calls.append(("upload", None))
    return {"results": [{"extensions": {"fileId": "uploaded-media-id"}}]}
cp.update_attachment_data = fake_update
cp.upload_attachment = fake_upload

args = types.SimpleNamespace(
    plan=sys.argv[2], page_index=0, page_id="900", account="a@b.c",
    site=None, keychain_service="svc",
)
with contextlib.redirect_stdout(io.StringIO()):
    rc = cp.cmd_attach(args)
body = open(json.load(open(sys.argv[2]))["pages"][0]["body_file"], encoding="utf-8").read()
print("rc=%s calls=%s fresh=%s stale=%s" % (
    rc, calls, "fresh-media-id" in body, "stale-media-id" in body,
))
PY
)
check "attach: refresh embeds the new media id" "$reattach" \
  "rc=0 calls=[('update', 'att500')] fresh=True stale=False"

# an attachment response with no fileId is a visible failure, not a broken <img>
noid=$(python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cp", sys.argv[1])
cp = importlib.util.module_from_spec(spec)
sys.modules["cp"] = cp
spec.loader.exec_module(cp)
print("att_id=%r empty=%r" % (
    cp.media_id_of({"results": [{"id": "att777"}]}),
    cp.media_id_of({}),
))
PY
)
check "attach: att id is never used as a media id" "$noid" "att_id='' empty=''"

# --- rasterize scope: image the charts, keep the prose as text --------------
# The display:grid heuristic cannot tell a bar chart from a grid-laid-out incident
# card, and an imaged card loses search, copy-paste and its Jira links.
out="$WORK/scope-auto"; rc=$(plan_of "$FIX/rasterize-scope.html" "$out")
check "scope: heuristic plan exits 0" "$rc" "0"
check "scope: heuristic images both grid blocks" \
  "$(jqp "$out/plan.json" "sum(len(p['visuals']) for p in d['pages'])")" "2"

out="$WORK/scope-only"
python3 "$SCRIPT" plan --source "$FIX/rasterize-scope.html" --out-dir "$out" \
  --rasterize-only ba >/dev/null 2>&1
check "scope: --rasterize-only images just the named container" \
  "$(jqp "$out/plan.json" "sum(len(p['visuals']) for p in d['pages'])")" "1"
body=$(cat "$out"/page-000.body.html)
check_contains "scope: unnamed block keeps its prose" "$body" "a swallowed error surfaced"
check_contains "scope: unnamed block keeps its links" "$body" "browse/SRE-624400"

# an imaged block that draws nothing is prose: name it instead of letting the
# caller discover it from a screenshot after the page is live
warn=$(jqp "$WORK/scope-auto/plan.json" "' '.join(d['warnings'])")
check_contains "scope: prose-shaped image is flagged" "$warn" "chart-02.png"
check_absent   "scope: real chart is not flagged"     "$warn" "chart-01.png"
check "scope: explicit scope plans clean" \
  "$(jqp "$out/plan.json" "len(d['warnings'])")" "0"

# a misspelled class silently images nothing and drops the chart subtrees, which
# reads as a successful plan unless the mismatch is reported
out="$WORK/scope-typo"
python3 "$SCRIPT" plan --source "$FIX/rasterize-scope.html" --out-dir "$out" \
  --rasterize-only baa >/dev/null 2>&1
check "scope: typo images nothing" \
  "$(jqp "$out/plan.json" "sum(len(p['visuals']) for p in d['pages'])")" "0"
check_contains "scope: typo is reported" \
  "$(jqp "$out/plan.json" "' '.join(d['warnings'])")" "matched nothing in the source"

# naming a container and a class nested inside it is redundant, not a typo: a false
# typo warning on a real class teaches the reader to ignore the warning
out="$WORK/scope-nested"
python3 "$SCRIPT" plan --source "$FIX/rasterize-scope.html" --out-dir "$out" \
  --rasterize-only ba --rasterize-only bar >/dev/null 2>&1
check "scope: nested named class is not called a typo" \
  "$(jqp "$out/plan.json" "len(d['warnings'])")" "0"

# contradictory scope flags discard one of the two intents, so refuse instead
python3 "$SCRIPT" plan --source "$FIX/rasterize-scope.html" --out-dir "$WORK/scope-both" \
  --rasterize-only ba --no-rasterize >/dev/null 2>&1
check "scope: --rasterize-only with --no-rasterize is refused" "$?" "2"

out="$WORK/scope-md"
python3 "$SCRIPT" plan --source "$FIX/digest.md" --out-dir "$out" \
  --rasterize-only ba >/dev/null 2>&1
mdwarn=$(jqp "$out/plan.json" "' '.join(d['warnings'])")
check_contains "scope: markdown source reports the ignored flag" "$mdwarn" "--rasterize-only was ignored"
check_contains "scope: markdown converter warnings survive it" "$mdwarn" "markdown passthrough"

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

# a scratch-space key stops matching once tmp is cleaned, so every page would
# re-create instead of update: refuse it unless the caller says it is throwaway
TRANSIENT="$WORK/workspace/tmp/scrubbed/report.html"
mkdir -p "$(dirname "$TRANSIENT")"
cp "$SRC" "$TRANSIENT"
before=$(wc -l < "$LEDGER" | tr -d ' ')
err=$(python3 "$SCRIPT" ledger-append --ledger "$LEDGER" --source "$TRANSIENT" \
  --page-index 0 --page-id "900900" --page-url "https://wiki/x/t" \
  --published-at "2026-08-21T00:00:00Z" --published-body-sha256 "sha-t" 2>&1 >/dev/null)
rc=$?
after=$(wc -l < "$LEDGER" | tr -d ' ')
check "ledger: transient source refused" "$rc" "2"
check "ledger: transient source appends nothing" "$after" "$before"
check_contains "ledger: transient refusal names the fix" "$err" "durable artifact"
python3 "$SCRIPT" ledger-append --ledger "$LEDGER" --source "$TRANSIENT" \
  --page-index 0 --page-id "900900" --page-url "https://wiki/x/t" \
  --published-at "2026-08-21T00:00:00Z" --published-body-sha256 "sha-t" \
  --allow-transient-source >/dev/null
after=$(wc -l < "$LEDGER" | tr -d ' ')
check "ledger: transient source allowed with opt-in" "$after" "$((before + 1))"

# "workspace" as the tail of a directory name is not scratch space: compare whole
# path segments, or a durable /x/team-workspace/tmp/report.html gets refused
segments=$(python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cp", sys.argv[1])
cp = importlib.util.module_from_spec(spec)
sys.modules["cp"] = cp
spec.loader.exec_module(cp)
print(" ".join(
    "%s=%s" % (label, cp.transient_source(path))
    for label, path in (
        ("scratch", "/a/workspace/tmp/x.html"),
        ("suffix", "/a/team-workspace/tmp/x.html"),
        ("prefix", "/a/workspace/tmpfiles/x.html"),
        ("durable", "/a/workspace/recaps/x.html"),
    )
))
PY
)
check "ledger: scratch detection compares path segments" "$segments" \
  "scratch=True suffix=False prefix=False durable=False"

# --- inline runs: the failure that shattered sentences into one-word lines ---
# A grid-laid-out card left out of the rasterize scope has to convert to
# semantic HTML. Emitting one closed paragraph per text run pushed every inline
# <code> to block level, where Confluence wraps it in a paragraph of its own.
out="$WORK/inline"
python3 "$SCRIPT" plan --source "$FIX/inline-run.html" --out-dir "$out" \
  --rasterize-only bars >/dev/null 2>&1
check "inline: plan exits 0" "$?" "0"
body=$(cat "$out"/page-000.body.html)

check_absent "inline: no code at block level" "$body" "</p><code>"
check_absent "inline: no code opening a block" "$body" "</code><p>"
check_contains "inline: sentence keeps its inline code" "$body" \
  "so <code>first_name</code> and"
check_contains "inline: space before inline code survives" "$body" "stamp a <code>?redacted=1</code>"
check_contains "inline: sentence continues after the code" "$body" "sentinel. See"
check_absent "inline: link is not its own block" "$body" '</p> <a href="https://github.com/acme'
check_contains "inline: b becomes strong" "$body" "<strong>Generated</strong>"
check_contains "inline: label and value share one paragraph" "$body" \
  "<p><strong>Generated</strong> 2026-09-03 <strong>Coverage</strong>"
check_contains "inline: separator survives a run ending at a tag" "$body" \
  "rollup-v2 <strong>Window</strong>"
check_absent "inline: adjacent spans do not weld" "$body" "rollup-v2<strong>"
check_contains "inline: ordinary paragraph untouched" "$body" \
  "<p>An ordinary paragraph with <code>inline code</code> stays one paragraph.</p>"
check_contains "inline: real chart still imaged" "$body" "chart-01.png"
check_contains "inline: panel content splits into paragraphs" "$body" \
  "<p>Problem</p> <p>The gate rejected <code>isHardDelete=false</code>.</p>"
check_absent "inline: panel content is not one welded run" "$body" "still live Problem"
panels=$(printf '%s' "$body" | grep -o 'data-type="panel-error"' | wc -l | tr -d ' ')
check "inline: consecutive panels both emitted, neither nested" "$panels" "2"

opens=$(printf '%s' "$body" | grep -o '<p>' | wc -l | tr -d ' ')
closes=$(printf '%s' "$body" | grep -o '</p>' | wc -l | tr -d ' ')
check "inline: paragraphs balance" "$opens" "$closes"
check_absent "inline: no empty paragraph" "$body" "<p></p>"

# An inline element outside INLINE_PASSTHROUGH is still inline: closing it must
# not end the sentence. A block-level wrapper must end it on the way in too, or
# the run before it welds onto the block's first line.
check_contains "inline: unknown inline tag keeps its sentence whole" "$body" \
  "<p>Latency was p95 above target, so we rolled back.</p>"
check_absent "inline: bare run does not weld onto the next block" "$body" \
  "Draft Body text follows"
check_contains "inline: block after a bare run gets its own paragraph" "$body" \
  "<p>Body text follows the tag.</p>"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'OK: confluence-publish plan/render contract holds\n'
  exit 0
fi
printf 'FAILED: %d assertion(s)\n' "$fails"
exit 1
