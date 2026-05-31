#!/usr/bin/env bash
# PreToolUse guard: block oversized Confluence page writes.
# The Atlassian MCP can truncate or fail on very large page bodies; block at
# 60K bytes to leave headroom for storage-format expansion.
set -euo pipefail

LIMIT=60000

block() {
  local reason="$1"
  {
    echo "BLOCKED by confluence-size-guard: $reason."
    echo ""
    echo "Write the rendered page body to workspace/tmp/{slug}-confluence-patch.html"
    echo "or workspace/tmp/{slug}-confluence-patch.md and ask the user to paste"
    echo "it manually in Confluence."
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

case "$TOOL" in
  *__updateConfluencePage) ;;
  *__createConfluencePage) ;;
  *) exit 0 ;;
esac

if ! SIZE=$(printf '%s' "$INPUT" \
  | jq -j '.tool_input.body // .tool_input.value // ""' 2>/dev/null \
  | wc -c \
  | tr -d ' '); then
  block "could not parse Confluence page body"
fi

if [ "${SIZE:-0}" -gt "$LIMIT" ]; then
  block "body is ${SIZE} bytes (>${LIMIT})"
fi

exit 0
