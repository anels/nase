#!/usr/bin/env bash
# Regression tests for .claude/hooks/style-edit-detect.sh
#
# Run from repo root:  bash tests/hooks/test-style-edit-detect.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/style-edit-detect.sh"

pass=0
fail=0

run_case() {
  local name=$1
  local prompt=$2
  local expected=$3
  local out rc

  out=$(printf '{"prompt":%s}' "$(jq -Rn --arg p "$prompt" '$p')" | bash "$HOOK")
  rc=$?

  if [[ "$rc" -ne 0 ]]; then
    printf 'FAIL  %-38s rc=%s\n' "$name" "$rc"
    fail=$((fail+1))
    return
  fi

  if [[ "$expected" == "match" ]]; then
    if jq -e '
      .hookSpecificOutput.hookEventName == "UserPromptSubmit"
      and (.hookSpecificOutput.additionalContext | contains("style-edit-detect"))
      and (.hookSpecificOutput.additionalContext | contains("[STYLE-DELTA]"))
      and (.hookSpecificOutput.additionalContext | contains("Do not update workspace/communication-style.md directly"))
    ' >/dev/null 2>&1 <<<"$out"; then
      printf 'PASS  %-38s match\n' "$name"
      pass=$((pass+1))
    else
      printf 'FAIL  %-38s expected match, got: %s\n' "$name" "$out"
      fail=$((fail+1))
    fi
  else
    if [[ -z "$out" ]]; then
      printf 'PASS  %-38s no-match\n' "$name"
      pass=$((pass+1))
    else
      printf 'FAIL  %-38s expected no output, got: %s\n' "$name" "$out"
      fail=$((fail+1))
    fi
  fi
}

run_case "slack draft edit" 'change "hello" to "hey" in the Slack draft' match
run_case "Chinese slack draft edit" "下次这个 Slack 草稿不要说 certainly，改成 sure" match
run_case "PR shorthand edit" "PR: next time make it shorter" match
run_case "PR mid-sentence edit" "next time make the PR shorter" match
run_case "DM shorthand edit" "DM: next time use sure instead of certainly" match
run_case "inline comment edit" "inline comment: next time drop the intro" match
run_case "external doc edit" "external doc: next time make it shorter" match
run_case "announcement edit" "announcement: next time make it shorter" match
run_case "internal doc negative" "next time make the doc shorter" no-match
run_case "code edit negative" "change the parser to handle quotes in src/main.py" no-match
run_case "document fragment negative" "next time fix the documentId output" no-match
run_case "word fragment negative" "next time fix the program output" no-match

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
