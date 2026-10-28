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
  'select(.skill == "fsd" and .source == "prompt-expansion" and .event_type == "activated")'

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
if [ "$count" = "2" ] && jq -e 'select(.skill == "fsd" and .event_type == "tool_succeeded" and .source == "skill-hook")' "$skill_log" >/dev/null; then
  pass_msg "PostToolUse:Skill records a separate tool outcome"
else
  fail_msg "PostToolUse:Skill records a separate tool outcome (got $count)"
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

# Slack write tools beyond send/canvas must be gated by the guard and by settings.json wiring.
settings="$ROOT/.claude/settings.json"
slack_write_tools="slack_send_message slack_schedule_message slack_create_canvas slack_update_canvas slack_add_reaction slack_create_conversation slack_add_list_record slack_update_list_record slack_create_list slack_update_list slack_complete_file_upload"
slack_allowed_tools="slack_send_message_draft slack_read_channel slack_get_file_upload_url slack_read_list slack_get_reactions slack_search_users"
slack_matcher=$(jq -r '[.hooks.PreToolUse[] | select(.hooks[].command | contains("slack-send-guard.sh")) | .matcher] | first // ""' "$settings")
for t in $slack_write_tools; do
  full="mcp__plugin_slack_slack__$t"
  if printf '%s' "$full" | grep -Eq "$slack_matcher"; then
    pass_msg "settings matcher covers $t"
  else
    fail_msg "settings matcher covers $t"
  fi
  out=$(printf '{"tool_name":"%s","tool_input":{}}' "$full" | bash "$ROOT/.claude/hooks/slack-send-guard.sh" 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ] && [[ "$out" == *"BLOCKED by slack-send-guard"* ]]; then
    pass_msg "slack-send-guard blocks $t"
  else
    fail_msg "slack-send-guard blocks $t (rc=$rc)"
  fi
done
for t in $slack_allowed_tools; do
  full="mcp__plugin_slack_slack__$t"
  if printf '%s' "$full" | grep -Eq "$slack_matcher"; then
    fail_msg "settings matcher leaves $t alone"
  else
    pass_msg "settings matcher leaves $t alone"
  fi
  printf '{"tool_name":"%s","tool_input":{}}' "$full" | bash "$ROOT/.claude/hooks/slack-send-guard.sh" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then pass_msg "slack-send-guard allows $t"; else fail_msg "slack-send-guard allows $t (rc=$rc)"; fi
done

for hook in post-edit-shellcheck.sh post-edit-ruff.sh; do
  post_matcher=$(jq -r --arg h "$hook" '[.hooks.PostToolUse[] | select(.hooks[].command | contains($h)) | .matcher] | first // ""' "$settings")
  if printf 'MultiEdit' | grep -Eq "^($post_matcher)$"; then
    pass_msg "PostToolUse $hook matches MultiEdit"
  else
    fail_msg "PostToolUse $hook matches MultiEdit (matcher '$post_matcher')"
  fi
done
if jq empty "$settings" 2>/dev/null; then pass_msg "settings.json is valid JSON"; else fail_msg "settings.json is valid JSON"; fi

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
