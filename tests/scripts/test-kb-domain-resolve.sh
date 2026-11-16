#!/usr/bin/env bash
# Regression tests for .claude/scripts/kb-domain-resolve.sh telemetry.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/kb-domain-resolve.sh"
LOGGER="$ROOT/.claude/scripts/kb-usage-log.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/workspace/kb/projects" "$FIXTURE/workspace/kb/ops"
cat > "$FIXTURE/workspace/kb/.domain-map.md" <<'EOF'
# Domain map

- example-repo → workspace/kb/projects/example.md
- platform-monitoring → workspace/kb/projects/platform-monitoring.md
- sre-extra → workspace/kb/ops/sre-extra.md
- sre → workspace/kb/ops/sre.md
- c++ → workspace/kb/projects/cpp.md
- dup → workspace/kb/projects/dup-first.md
- dup → workspace/kb/projects/dup-second.md
<!-- single-line comment, not a row: - hidden-inline → workspace/kb/projects/hidden-inline.md -->
<!--
Registered rows only. Example of the shape:
- hidden → workspace/kb/projects/hidden.md
-->
- after-comment → workspace/kb/projects/after.md
EOF
printf '# example\n' > "$FIXTURE/workspace/kb/projects/example.md"
printf '# sre\n' > "$FIXTURE/workspace/kb/ops/sre.md"
printf '# sre-extra\n' > "$FIXTURE/workspace/kb/ops/sre-extra.md"
printf '# monitoring\n' > "$FIXTURE/workspace/kb/projects/platform-monitoring.md"
for f in cpp dup-first dup-second hidden hidden-inline after; do
  printf '# %s\n' "$f" > "$FIXTURE/workspace/kb/projects/$f.md"
done

pass=0
fail=0

pass_msg() {
  pass=$((pass + 1))
  printf 'PASS  %s\n' "$1"
}

fail_msg() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

assert_exit() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass_msg "$desc"
  else
    fail_msg "$desc (expected exit $expected, got $actual)"
  fi
}

assert_contains() {
  local desc="$1"
  local text="$2"
  local needle="$3"
  if grep -qF -- "$needle" <<< "$text"; then
    pass_msg "$desc"
  else
    fail_msg "$desc (missing $needle)"
  fi
}

assert_jq() {
  local desc="$1"
  local expr="$2"
  local file="$FIXTURE/workspace/stats/kb-usage.jsonl"
  if [ -f "$file" ] && jq -e "$expr" "$file" >/dev/null 2>&1; then
    pass_msg "$desc"
  else
    fail_msg "$desc"
    [ -f "$file" ] && cat "$file" >&2
  fi
}

NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="domain-test" \
  python3 "$LOGGER" activate --skill "discuss-pr" --source test >/dev/null 2>&1

out=$(cd "$FIXTURE" && NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="domain-test" bash "$SCRIPT" "example_repo" 2>&1)
rc=$?
assert_exit "T1: resolves normalized domain key" 0 "$rc"
assert_contains "T1: stdout is resolved KB path" "$out" "workspace/kb/projects/example.md"
assert_jq "T1: successful resolve appends telemetry" \
  'select(.skill == "discuss-pr" and .file == "workspace/kb/projects/example.md" and .access == "resolve" and .source == "kb-domain-resolve")'

before=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
out=$(cd "$FIXTURE" && NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="domain-test" bash "$SCRIPT" "missing-domain" 2>&1)
rc=$?
after=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
assert_exit "T2: missing domain exits nonzero" 1 "$rc"
assert_contains "T2: missing domain reports error" "$out" "No KB entry"
if [ "$before" = "$after" ]; then
  pass_msg "T2: failed resolve does not append telemetry"
else
  fail_msg "T2: failed resolve changed ledger count (before $before, after $after)"
fi

resolve() {
  (cd "$FIXTURE" && NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="domain-test" bash "$SCRIPT" "$1" 2>&1)
}

# The key is a literal string, not a regex.
out=$(resolve "platform.monitoring"); rc=$?
assert_exit "T3: a dot in the key does not match a hyphenated row" 1 "$rc"
assert_contains "T3: dot key reports no entry" "$out" "No KB entry"

out=$(resolve "sre|sre-extra"); rc=$?
assert_exit "T4: an alternation in the key matches nothing" 1 "$rc"
assert_contains "T4: alternation key reports no entry" "$out" "No KB entry"

out=$(resolve ".*"); rc=$?
assert_exit "T5: a wildcard key matches nothing" 1 "$rc"
assert_contains "T5: wildcard key reports no entry" "$out" "No KB entry"

out=$(resolve "sre"); rc=$?
assert_exit "T6: sre resolves although sre-extra shares its prefix" 0 "$rc"
assert_contains "T6: sre resolves to its own file" "$out" "workspace/kb/ops/sre.md"
out=$(resolve "sre-extra"); rc=$?
assert_exit "T6: sre-extra resolves" 0 "$rc"
assert_contains "T6: sre-extra resolves to its own file" "$out" "workspace/kb/ops/sre-extra.md"

out=$(resolve "c++"); rc=$?
assert_exit "T7: a key with regex metacharacters resolves" 0 "$rc"
assert_contains "T7: c++ resolves to its file" "$out" "workspace/kb/projects/cpp.md"

out=$(resolve "hidden"); rc=$?
assert_exit "T8: a row inside a comment block is ignored" 1 "$rc"
out=$(resolve "hidden-inline"); rc=$?
assert_exit "T8: a row inside a one-line comment is ignored" 1 "$rc"
out=$(resolve "after-comment"); rc=$?
assert_exit "T8: a row after a comment block still resolves" 0 "$rc"
assert_contains "T8: row after comment resolves to its file" "$out" "workspace/kb/projects/after.md"

out=$(resolve "dup"); rc=$?
assert_exit "T9: duplicate keys resolve" 0 "$rc"
assert_contains "T9: the first duplicate row wins" "$out" "workspace/kb/projects/dup-first.md"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
