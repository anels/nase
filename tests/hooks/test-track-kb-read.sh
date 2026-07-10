#!/usr/bin/env bash
# Regression tests for .claude/hooks/track-kb-read.sh.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/track-kb-read.sh"
LOGGER="$ROOT/.claude/scripts/kb-usage-log.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/workspace/kb/general" "$FIXTURE/workspace/kb/projects" "$FIXTURE/workspace/tmp"
printf '# read fixture\n' > "$FIXTURE/workspace/kb/general/read.md"
printf 'select 1;\n' > "$FIXTURE/workspace/kb/general/data.sql"
printf '# domain map\n' > "$FIXTURE/workspace/kb/.domain-map.md"
printf '# unsupported\n' > "$FIXTURE/workspace/kb/projects/notes.txt"
mkdir -p "$FIXTURE/workspace/docs"
printf '# not kb\n' > "$FIXTURE/workspace/docs/not-kb.md"

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

assert_count() {
  local desc="$1"
  local expected="$2"
  local expr="$3"
  local file="$FIXTURE/workspace/stats/kb-usage.jsonl"
  local actual=0
  if [ -f "$file" ]; then
    actual=$(jq -s "$expr" "$file" 2>/dev/null || echo "jq-error")
  fi
  if [ "$actual" = "$expected" ]; then
    pass_msg "$desc"
  else
    fail_msg "$desc (expected $expected, got $actual)"
    [ -f "$file" ] && cat "$file" >&2
  fi
}

run_hook() {
  local file_path="$1"
  local session="$2"
  printf '{"tool_input":{"file_path":"%s"}}' "$file_path" \
    | NASE_ROOT="$FIXTURE" CLAUDE_SESSION_ID="$session" bash "$HOOK" >/dev/null 2>&1
}

activate_skill() {
  local skill="$1"
  local session="$2"
  NASE_ROOT="$FIXTURE" CLAUDE_SESSION_ID="$session" \
    python3 "$LOGGER" activate --skill "$skill" --source test >/dev/null 2>&1
}

activate_skill "fsd" "hook-active"
run_hook "workspace/kb/general/read.md" "hook-active"
assert_jq "T1: relative KB read records active skill" \
  'select(.skill == "fsd" and .file == "workspace/kb/general/read.md" and .access == "read" and .source == "read-hook" and .session == "hook-active")'

printf '{"session_id":"input-session","tool_input":{"file_path":"workspace/kb/general/read.md"}}' \
  | NASE_ROOT="$FIXTURE" CLAUDE_SESSION_ID="different-env-session" bash "$HOOK" >/dev/null 2>&1
assert_jq "T1b: hook input session wins over environment fallback" \
  'select(.skill == "unknown" and .file == "workspace/kb/general/read.md" and .session == "input-session")'

run_hook "$FIXTURE/workspace/kb/general/data.sql" "hook-unknown"
assert_jq "T2: absolute SQL KB read records unknown skill" \
  'select(.skill == "unknown" and .file == "workspace/kb/general/data.sql" and .access == "read" and .source == "read-hook" and .session == "hook-unknown")'

before=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
run_hook "workspace/kb/.domain-map.md" "hook-skip"
run_hook "workspace/docs/not-kb.md" "hook-skip"
run_hook "workspace/kb/projects/notes.txt" "hook-skip"
after=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
if [ "$before" = "$after" ]; then
  pass_msg "T3: skips domain map, non-KB paths, and unsupported extensions"
else
  fail_msg "T3: skip rules changed ledger count (before $before, after $after)"
fi

activate_skill "design" "hook-dedupe"
run_hook "workspace/kb/general/read.md" "hook-dedupe"
run_hook "workspace/kb/general/read.md" "hook-dedupe"
assert_count "T4: dedupes repeated same-file reads in a short window" "1" \
  '[.[] | select(.session == "hook-dedupe" and .file == "workspace/kb/general/read.md" and .access == "read")] | length'

NASE_ROOT="$FIXTURE" python3 "$LOGGER" activate --skill "learn" --source test >/dev/null 2>&1
run_hook "workspace/kb/general/read.md" "hook-fallback"
assert_jq "T5: falls back to active skill when hook sessions differ" \
  'select(.skill == "learn" and .file == "workspace/kb/general/read.md" and .access == "read" and .source == "read-hook" and .session == "hook-fallback")'

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
