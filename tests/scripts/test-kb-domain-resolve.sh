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
- sre → workspace/kb/ops/sre.md
EOF
printf '# example\n' > "$FIXTURE/workspace/kb/projects/example.md"
printf '# sre\n' > "$FIXTURE/workspace/kb/ops/sre.md"

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
  if printf '%s' "$text" | grep -qF "$needle"; then
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

NASE_ROOT="$FIXTURE" CLAUDE_SESSION_ID="domain-test" \
  python3 "$LOGGER" activate --skill "discuss-pr" --source test >/dev/null 2>&1

out=$(cd "$FIXTURE" && NASE_ROOT="$FIXTURE" CLAUDE_SESSION_ID="domain-test" bash "$SCRIPT" "example_repo" 2>&1)
rc=$?
assert_exit "T1: resolves normalized domain key" 0 "$rc"
assert_contains "T1: stdout is resolved KB path" "$out" "workspace/kb/projects/example.md"
assert_jq "T1: successful resolve appends telemetry" \
  'select(.skill == "discuss-pr" and .file == "workspace/kb/projects/example.md" and .access == "resolve" and .source == "kb-domain-resolve")'

before=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
out=$(cd "$FIXTURE" && NASE_ROOT="$FIXTURE" CLAUDE_SESSION_ID="domain-test" bash "$SCRIPT" "missing-domain" 2>&1)
rc=$?
after=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
assert_exit "T2: missing domain exits nonzero" 1 "$rc"
assert_contains "T2: missing domain reports error" "$out" "No KB entry"
if [ "$before" = "$after" ]; then
  pass_msg "T2: failed resolve does not append telemetry"
else
  fail_msg "T2: failed resolve changed ledger count (before $before, after $after)"
fi

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
