#!/usr/bin/env bash
# PreToolUse guard for Confluence page writes: enforce ADF format and a size cap.
# The Atlassian MCP can truncate or fail on very large page bodies; block at
# 60K bytes to leave headroom for storage-format expansion. Page bodies must
# also be sent as contentFormat:"adf" so inlineCard, panels, tables, and
# screenshots round-trip — see .claude/docs/confluence-adf-pattern.md.
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

block_format() {
  local reason="$1"
  {
    echo "BLOCKED by confluence-size-guard: $reason."
    echo ""
    echo "Confluence page bodies must be sent as contentFormat: \"adf\" so"
    echo "inlineCard Jira links, panels, tables, and screenshots round-trip."
    echo "Fetch the current page as ADF, modify in memory, and send it back as"
    echo "adf. If a page genuinely cannot be expressed as ADF, save a draft to"
    echo "workspace/tmp/ and ask the user to paste it manually."
    echo ""
    echo "Policy source: .claude/docs/confluence-adf-pattern.md"
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

CONTENT_FORMAT=$(printf '%s' "$INPUT" | jq -r '.tool_input.contentFormat // ""' 2>/dev/null || echo "")
if [ "$CONTENT_FORMAT" != "adf" ]; then
  block_format "$TOOL sent contentFormat \"${CONTENT_FORMAT:-<unset>}\", expected \"adf\""
fi

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
