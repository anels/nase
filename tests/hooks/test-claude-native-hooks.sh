#!/usr/bin/env bash
# Regression tests for Claude-native lifecycle hook telemetry.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

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
  local desc="$1" file="$2" expr="$3"
  if [ -f "$file" ] && jq -e "$expr" "$file" >/dev/null 2>&1; then
    pass_msg "$desc"
  else
    fail_msg "$desc"
    [ -f "$file" ] && cat "$file" >&2
  fi
}

mkdir -p "$FIXTURE/workspace/stats"

printf '{"command_name":"nase:fsd"}' \
  | NASE_ROOT="$FIXTURE" HOOK_EVENT_NAME=UserPromptExpansion \
    bash "$ROOT/.claude/hooks/track-skill-prompt.sh" >/dev/null 2>&1

skill_log="$FIXTURE/workspace/stats/skill-usage.jsonl"
assert_jq "UserPromptExpansion records prompt-expansion source" "$skill_log" \
  'select(.skill == "fsd" and .source == "prompt-expansion" and .status == "success")'

before_count=$(wc -l < "$skill_log" | tr -d ' ')
printf '{"prompt":"nase:fsd is just text"}' \
  | NASE_ROOT="$FIXTURE" HOOK_EVENT_NAME=UserPromptSubmit \
    bash "$ROOT/.claude/hooks/track-skill-prompt.sh" >/dev/null 2>&1
after_count=$(wc -l < "$skill_log" | tr -d ' ')
if [ "$before_count" = "$after_count" ]; then
  pass_msg "UserPromptSubmit requires slash command syntax"
else
  fail_msg "UserPromptSubmit requires slash command syntax"
fi

printf '{"tool_input":{"skill":"nase:fsd"},"tool_response":{}}' \
  | NASE_ROOT="$FIXTURE" bash "$ROOT/.claude/hooks/track-skill.sh" >/dev/null 2>&1
count=$(jq -s '[.[] | select(.skill == "fsd")] | length' "$skill_log" 2>/dev/null || echo 0)
if [ "$count" = "1" ]; then
  pass_msg "PostToolUse:Skill dedupes recent prompt-expansion entry"
else
  fail_msg "PostToolUse:Skill dedupes recent prompt-expansion entry (got $count)"
fi

fake_bearer="Bear""er redaction-test-token"
fake_secret_assignment="token""=""redaction-test-secret"
long_error="$fake_bearer $fake_secret_assignment $(printf 'x%.0s' {1..700})"
printf '{"tool_name":"Bash","error":"%s","duration_ms":12}' "$long_error" \
  | NASE_ROOT="$FIXTURE" HOOK_EVENT_NAME=PostToolUseFailure \
    bash "$ROOT/.claude/hooks/track-tool-failure.sh" >/dev/null 2>&1
assert_jq "PostToolUseFailure writes bounded tool failure" "$FIXTURE/workspace/stats/tool-failures.jsonl" \
  'select(.event == "PostToolUseFailure" and .tool == "Bash" and .status == "failure" and (.error | length) <= 503 and (.error | contains("redaction-test-secret") | not) and (.error | contains("[REDACTED_SECRET]")))'

printf '{"agent_type":"reviewer","agent_transcript_path":"/tmp/agent.jsonl","last_assistant_message":"done"}' \
  | NASE_ROOT="$FIXTURE" HOOK_EVENT_NAME=SubagentStop \
    bash "$ROOT/.claude/hooks/track-subagent.sh" >/dev/null 2>&1
assert_jq "SubagentStop writes subagent summary" "$FIXTURE/workspace/stats/subagent-usage.jsonl" \
  'select(.event == "SubagentStop" and .agent == "reviewer" and .message_chars == 4 and has("message_preview") | not)'

printf '{"error":"rate limit %s","error_details":"too many requests %s","last_assistant_message":"retry later"}' "$fake_secret_assignment" "$fake_bearer" \
  | NASE_ROOT="$FIXTURE" HOOK_EVENT_NAME=StopFailure \
    bash "$ROOT/.claude/hooks/track-session-failure.sh" >/dev/null 2>&1
assert_jq "StopFailure writes session failure summary" "$FIXTURE/workspace/stats/session-failures.jsonl" \
  'select(.event == "StopFailure" and (.error | contains("redaction-test-secret") | not) and (.error_details | contains("redaction-test-token") | not) and .last_assistant_chars == 11 and has("last_assistant_preview") | not)'

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
