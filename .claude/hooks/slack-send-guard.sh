#!/usr/bin/env bash
# PreToolUse guard: hard-block direct Slack API sends.
# Slack drafts are allowed; direct sends are irreversible from the model side.
# slack_schedule_message is the same send with a delay, so it is blocked too -
# the draft path substitutes for it exactly.
set -euo pipefail

block() {
  local reason="$1"
  {
    echo "BLOCKED by slack-send-guard: $reason."
    echo ""
    echo "Use slack_send_message_draft instead. The user reviews the draft"
    echo "and sends it from Slack."
    echo ""
    echo "If slack_send_message_draft fails, show the message in chat for"
    echo "manual sending. Never fall back to slack_send_message."
    echo ""
    echo "Policy source: .claude/docs/external-mutation-policy.md"
  } >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || block "jq is required to parse tool input"

INPUT=$(cat)
if ! TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null); then
  block "could not parse tool input JSON"
fi
# Empty stdin parses as nothing at all, and an empty name matches none of the patterns
# below. The guard only runs on a matched Slack write tool, so reaching here without a
# name means the invocation cannot be classified.
if [[ -z "$TOOL" ]]; then
  block "no tool_name in the hook payload"
fi

if [[ "$TOOL" == *__slack_send_message ]]; then
  block "slack_send_message is forbidden"
fi

if [[ "$TOOL" == *__slack_schedule_message ]]; then
  block "slack_schedule_message is forbidden; a scheduled send is still a send"
fi

if [[ "$TOOL" == *__slack_create_canvas || "$TOOL" == *__slack_update_canvas ]]; then
  block "${TOOL##*__} writes to Slack with no draft path"
fi

exit 0
