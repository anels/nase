#!/usr/bin/env bash
# PreToolUse guard for Confluence page writes: enforce a lossless format and a size cap.
# The Atlassian MCP can truncate or fail on very large page bodies; block at
# 60K bytes to leave headroom for storage-format expansion. Note that headroom
# was calibrated when ADF was the only accepted format — markdown is far terser
# per input byte, so callers publishing markdown should split well below the cap
# (see .claude/docs/confluence-publish-conversion.md).
# Page bodies must be sent as contentFormat:"adf", "html" (Confluence HTML+), or
# "markdown"; all three round-trip inlineCard, panels, tables, and attachments
# through the MCP's own converter. Storage XHTML and unset are rejected —
# see .claude/docs/confluence-adf-pattern.md.
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
    echo "Confluence page bodies must be sent as one of contentFormat:"
    echo "\"adf\", \"html\", or \"markdown\" so inlineCard Jira links, panels,"
    echo "tables, and attachments round-trip. Use \"adf\" when editing a page"
    echo "already fetched as ADF, \"html\" (Confluence HTML+) when publishing"
    echo "converted HTML, and \"markdown\" for markdown passthrough."
    echo "Storage XHTML and any other value are rejected. If a page cannot be"
    echo "expressed in one of these, save a draft to workspace/tmp/ and ask"
    echo "the user to paste it manually."
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
case "$CONTENT_FORMAT" in
  adf|html|markdown) ;;
  *)
    block_format "$TOOL sent contentFormat \"${CONTENT_FORMAT:-<unset>}\", expected one of \"adf\", \"html\", \"markdown\""
    ;;
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
