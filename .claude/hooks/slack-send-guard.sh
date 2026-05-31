#!/usr/bin/env bash
# PreToolUse guard: hard-block direct Slack API sends.
# Slack drafts are allowed; direct sends are irreversible from the model side.
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

if [[ "$TOOL" == *__slack_send_message ]]; then
  block "slack_send_message is forbidden"
fi

exit 0
