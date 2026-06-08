#!/usr/bin/env bash
# Regression tests for .claude/scripts/workspace-write-guard.py

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace-write-guard.py"
TMPROOT=$(mktemp -d)
failures=0

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_cmd() {
  local desc="$1"
  shift
  if "$@"; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, field = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in field.split("."):
    value = value[part]
print(value)
PY
}

mkdir -p "$TMPROOT/workspace/kb/projects" "$TMPROOT/workspace/tmp" "$TMPROOT/.claude/commands/nase/workspace"
mkdir -p "$TMPROOT/workspace/journals"

target="$TMPROOT/workspace/kb/projects/demo.md"
proposal="$TMPROOT/proposal.md"
stage_json="$TMPROOT/stage.json"
apply_json="$TMPROOT/apply.json"

printf 'old\n' > "$target"
printf 'new\n' > "$proposal"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --content-file "$proposal" \
  --skill kb-update > "$stage_json"
stage_rc=$?

assert_cmd "stage exits 0" test "$stage_rc" = "0"
staged=$(json_field "$stage_json" staged_abs)
mtime_ns=$(json_field "$stage_json" target.mtime_ns)
sha256=$(json_field "$stage_json" target.sha256)

assert_cmd "stage creates staged file" test -f "$staged"
assert_cmd "stage keeps target unchanged" grep -qx 'old' "$target"
assert_cmd "staged file has proposed content" grep -qx 'new' "$staged"
assert_cmd "stage records mtime" test "$mtime_ns" != "missing"
assert_cmd "stage records sha256" test "$sha256" != "missing"

python3 "$SCRIPT" diff \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --staged "$staged" > "$TMPROOT/diff.txt"
assert_cmd "diff shows old line" grep -q '^-old' "$TMPROOT/diff.txt"
assert_cmd "diff shows new line" grep -q '^+new' "$TMPROOT/diff.txt"

python3 "$SCRIPT" apply \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --staged "$staged" \
  --expected-mtime-ns "$mtime_ns" \
  --expected-sha256 "$sha256" > "$apply_json"
apply_rc=$?

assert_cmd "apply exits 0" test "$apply_rc" = "0"
assert_cmd "apply updates target" grep -qx 'new' "$target"
assert_cmd "apply reports target" grep -q '"target": "workspace/kb/projects/demo.md"' "$apply_json"

printf 'draft\n' > "$proposal"
python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --content-file "$proposal" \
  --skill kb-update > "$stage_json"
drift_staged=$(json_field "$stage_json" staged_abs)
drift_mtime_ns=$(json_field "$stage_json" target.mtime_ns)
drift_sha256=$(json_field "$stage_json" target.sha256)
printf 'changed elsewhere\n' > "$target"

python3 "$SCRIPT" apply \
  --root "$TMPROOT" \
  --target workspace/kb/projects/demo.md \
  --staged "$drift_staged" \
  --expected-mtime-ns "$drift_mtime_ns" \
  --expected-sha256 "$drift_sha256" > "$TMPROOT/drift.out" 2> "$TMPROOT/drift.err"
drift_rc=$?

assert_cmd "drift exits 3" test "$drift_rc" = "3"
assert_cmd "drift preserves target" grep -qx 'changed elsewhere' "$target"
assert_cmd "drift preserves staged draft" test -f "$drift_staged"
assert_cmd "drift message names staged file" grep -q 'staged file preserved' "$TMPROOT/drift.err"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target ../outside.md \
  --content-file "$proposal" \
  --skill bad > "$TMPROOT/outside.out" 2> "$TMPROOT/outside.err"
outside_rc=$?
assert_cmd "outside target rejected" test "$outside_rc" = "2"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/tmp/not-durable.md \
  --content-file "$proposal" \
  --skill bad > "$TMPROOT/tmp-target.out" 2> "$TMPROOT/tmp-target.err"
tmp_target_rc=$?
assert_cmd "workspace tmp target rejected" test "$tmp_target_rc" = "2"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target .claude/commands/nase/workspace/generated.md \
  --content-file "$proposal" \
  --skill extract-skills > "$TMPROOT/wrapper-stage.json"
wrapper_rc=$?
assert_cmd "generated wrapper target allowed" test "$wrapper_rc" = "0"

python3 "$SCRIPT" stage \
  --root "$TMPROOT" \
  --target workspace/journals/2026-06-08.md \
  --content-file "$proposal" \
  --skill wrap-up > "$TMPROOT/journal-stage.json"
journal_rc=$?
assert_cmd "journal rewrite target allowed" test "$journal_rc" = "0"

assert_cmd "guard doc documents helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/docs/workspace-write-guard.md"
assert_cmd "design uses helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/commands/nase/design.md"
assert_cmd "kb-update uses helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/commands/nase/kb-update.md"
assert_cmd "wrap-up uses helper" grep -q 'workspace-write-guard.py stage' "$ROOT/.claude/commands/nase/wrap-up.md"

if [[ "$failures" -eq 0 ]]; then
  printf '\nworkspace-write-guard tests passed.\n'
  exit 0
fi

printf '\n%d workspace-write-guard assertion(s) failed.\n' "$failures" >&2
exit "$failures"
