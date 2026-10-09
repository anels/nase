#!/usr/bin/env bash
# Regression tests for .claude/hooks/daily-log-format-guard.sh
#
# The hook is a blocking PreToolUse guard on Edit, Write and MultiEdit. What has to hold:
# a non-canonical session line added to a dated daily log blocks (exit 2) with the fix
# named, canonical lines and every other file pass, lines already in the file are never
# judged, and anything the guard cannot parse passes instead of blocking a write.
#
# Run from repo root:  bash tests/hooks/test-daily-log-format-guard.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/daily-log-format-guard.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/workspace/logs" "$TMP/workspace/kb"
LOG="$TMP/workspace/logs/2026-10-01.md"
TRACKER="$TMP/workspace/logs/2026-09-23-sre-tracker.md"
KB="$TMP/workspace/kb/a.md"

GOOD='- 09:15 | kb-review: 2 runs, 33 repairs'
BAD='- 09:16 [done] repaired the header dates'

pass=0
fail=0

ok() {
  printf 'PASS  %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2
  fail=$((fail + 1))
}

run_hook() {
  local payload="$1"
  shift
  RC=0
  ERR=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>&1 >/dev/null) || RC=$?
}

edit_payload() {
  jq -n --arg p "$1" --arg o "$2" --arg n "$3" \
    '{tool_name: "Edit", tool_input: {file_path: $p, old_string: $o, new_string: $n}}'
}

write_payload() {
  jq -n --arg p "$1" --arg c "$2" \
    '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}'
}

expect_pass() {
  if [[ "$RC" -eq 0 && -z "$ERR" ]]; then ok "$1"; else bad "$1" "rc=$RC err=$ERR"; fi
}

expect_block() {
  if [[ "$RC" -eq 2 && "$ERR" == *"daily-log-append.py"* && "$ERR" == *"$2"* ]]; then
    ok "$1"
  else
    bad "$1" "rc=$RC err=$ERR"
  fi
}

printf '# Work Log\n\n## Sessions\n\n%s\n' "$BAD" > "$LOG"

run_hook "$(edit_payload "$LOG" "" "$GOOD")"
expect_pass "Edit adding a canonical line passes"

run_hook "$(edit_payload "$LOG" "" "$BAD")"
expect_block "Edit adding a [type] line blocks and names the helper" "[done]"

run_hook "$(edit_payload "$LOG" "" "- 09:20 no tag at all")"
expect_block "Edit adding a line with no tag blocks" "no tag at all"

run_hook "$(edit_payload "$LOG" "" "- 09:21 | Bad_Tag: uppercase tag")"
expect_block "Edit with an invalid tag blocks" "Bad_Tag"

run_hook "$(edit_payload "$LOG" "$BAD" "$BAD")"
expect_pass "Edit that keeps an existing bad line unchanged passes"

run_hook "$(write_payload "$LOG" "$(printf '# Work Log\n\n## Sessions\n\n%s\n%s\n' "$BAD" "$GOOD")")"
expect_pass "Write that keeps the old bad line and adds a good one passes"

run_hook "$(write_payload "$LOG" "$(printf '# Work Log\n\n## Sessions\n\n%s\n- 09:30 [wip] new\n' "$BAD")")"
expect_block "Write that adds a new bad line blocks" "[wip]"

run_hook "$(write_payload "$TMP/workspace/logs/2026-10-02.md" "$(printf '# Work Log\n\n## Sessions\n\n%s\n' "$BAD")")"
expect_block "Write creating a new log with a bad line blocks" "[done]"

run_hook "$(jq -n --arg p "$LOG" --arg g "$GOOD" --arg b "$BAD" \
  '{tool_name: "MultiEdit", tool_input: {file_path: $p, edits: [{old_string: "", new_string: $g}, {old_string: "", new_string: $b}]}}')"
expect_block "MultiEdit with one bad edit blocks" "[done]"

run_hook "$(edit_payload "$LOG" "" $'## Commits\n\nplain text and a header are not session lines')"
expect_pass "Headers and prose that are not session lines pass"

run_hook "$(edit_payload "$TRACKER" "" "$BAD")"
expect_pass "A tracker log with its own format is ignored"

run_hook "$(edit_payload "$KB" "" "$BAD")"
expect_pass "A file outside workspace/logs is ignored"

run_hook "$(edit_payload "$LOG" "" "$BAD")" NASE_DAILY_LOG_GUARD=0
expect_pass "NASE_DAILY_LOG_GUARD=0 lets the write through"

run_hook 'not json, workspace/logs/2026-10-08.md'
if [[ "$RC" -eq 0 && "$ERR" == *"not checked"* ]]; then
  ok "Unparseable stdin passes and says it was not checked"
else
  bad "Unparseable stdin passes and says it was not checked" "rc=$RC err=$ERR"
fi

run_hook '{"tool_name": "Edit"}'
expect_pass "A payload with no file_path passes"

run_hook '{"tool_name": "Edit", "tool_input": {"file_path": "workspace/logs/2026-10-08.md"}}'
if [[ "$RC" -eq 0 && "$ERR" == *"not checked"* ]]; then
  ok "A log edit missing old_string and new_string fails open"
else
  bad "A log edit missing old_string and new_string fails open" "rc=$RC err=$ERR"
fi

STUB="$TMP/stub/.claude"
mkdir -p "$STUB/hooks" "$STUB/scripts"
cp "$HOOK" "$STUB/hooks/"
cp "$ROOT/.claude/scripts/daily-log-line-check.py" "$ROOT/.claude/scripts/daily-log-append.py" "$STUB/scripts/"
HOOK="$STUB/hooks/daily-log-format-guard.sh"
run_hook "$(edit_payload "$LOG" "" "$BAD")"
if [[ "$RC" -eq 0 && "$ERR" == *"not checked"* ]]; then
  ok "A missing helper module passes and says it was not checked"
else
  bad "A missing helper module passes and says it was not checked" "rc=$RC err=$ERR"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
