#!/usr/bin/env bash
# PreToolUse guard for Confluence page writes: enforce an accepted format and a size cap.
# The Atlassian MCP can truncate or fail on very large page bodies; block at
# 70K bytes to leave headroom for storage-format expansion. The figure is
# calibrated against a published page the site already accepts, whose body is
# 64084 characters, so a cap below that rejects bodies Confluence stores fine.
# Keep it in step with CAP_BYTES in .claude/scripts/confluence-publish.py.
# Note that headroom
# was calibrated when ADF was the only accepted format - markdown is far terser
# per input byte, so callers publishing markdown should split well below the cap
# (see .claude/docs/confluence-publish-conversion.md).
# Page bodies must be sent as contentFormat:"adf", "html" (Confluence HTML+), or
# "markdown". adf and html round-trip inlineCard, panels, tables, and
# attachments through the MCP's own converter; markdown is passthrough and
# cannot express any of them. Storage XHTML and unset are rejected -
# see .claude/docs/confluence-adf-pattern.md.
# Two Atlassian MCP tool generations reach this guard. The older
# create/updateConfluencePage pair carries a top-level contentFormat with a
# string body; the current create/updateConfluenceContent pair carries
# body:{format,value} and drops adf. Both are matched, each against its own
# format enum.
set -euo pipefail

LIMIT=70000

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
    echo "Confluence bodies must declare a format this tool accepts:"
    echo "  create/updateConfluencePage: \"adf\", \"html\", or \"markdown\""
    echo "  create/updateConfluenceContent: \"html\", \"markdown\", or the"
    echo "  non-doc formats \"svg\" (whiteboard), \"csv\" (database), \"url\" (embed)"
    echo "Use \"adf\" when editing a page already fetched as ADF and \"html\""
    echo "(Confluence HTML+) when publishing converted HTML - both round-trip"
    echo "inlineCard Jira links, panels, tables, and attachments. \"markdown\" is"
    echo "passthrough and expresses none of those, so use it only for a plain"
    echo "markdown document. Storage XHTML and any other value are rejected. The"
    echo "newer *Content tools take the format inside body:{format,value}."
    echo "If a page cannot be expressed in one of these, save a draft to"
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
  *__updateConfluencePage|*__createConfluencePage)
    ACCEPTED_FORMATS=(adf html markdown)
    ;;
  *__updateConfluenceContent|*__createConfluenceContent)
    ACCEPTED_FORMATS=(html markdown svg csv url)
    ;;
  *) exit 0 ;;
esac

# One jq pass for every fact the checks below need. This runs before each guarded
# tool call, so each extra subprocess is on the interactive path. @tsv escapes any
# tab or newline inside a value, keeping the record on one line.
if ! GUARD_FACTS=$(printf '%s' "$INPUT" | jq -r '
      (.tool_input // {}) as $i
      | ($i.body // $i.value) as $b
      | (if $b == null then ""
         elif ($b | type) == "object" then ($i.contentFormat // $b.format // "")
         else ($i.contentFormat // "") end) as $format
      | (if $b == null then
           (if ($i.edits | type) == "array" then ($i.edits | tojson) else "" end)
         elif ($b | type) == "object" then (($b.value // "") | tostring)
         elif ($b | type) == "string" then $b
         else ($b | tostring) end) as $text
      | [(if $b == null then "0" else "1" end), $format, ($text | utf8bytelength)]
      | @tsv
' 2>/dev/null); then
  block "could not parse Confluence content body"
fi
# Split by expansion, not `read -r`: bash treats a tab in IFS as IFS-whitespace and
# collapses runs of it, so an unset format would silently shift the byte count into
# the format field and leave the size empty.
BODY_PRESENT="${GUARD_FACTS%%$'\t'*}"
GUARD_FACTS_TAIL="${GUARD_FACTS#*$'\t'}"
CONTENT_FORMAT="${GUARD_FACTS_TAIL%%$'\t'*}"
SIZE="${GUARD_FACTS_TAIL#*$'\t'}"

# A title-only, width-only, or granular-edits update carries no body, so it has
# no format to gate. The size check below still bounds what such a call sends.
if [ "$BODY_PRESENT" = "1" ]; then
  format_accepted=0
  for accepted in "${ACCEPTED_FORMATS[@]}"; do
    if [ "$CONTENT_FORMAT" = "$accepted" ]; then
      format_accepted=1
      break
    fi
  done
  if [ "$format_accepted" -ne 1 ]; then
    quoted_formats=$(printf '"%s", ' "${ACCEPTED_FORMATS[@]}")
    block_format "$TOOL sent contentFormat \"${CONTENT_FORMAT:-<unset>}\", expected one of ${quoted_formats%, }"
  fi
fi

if [ "${SIZE:-0}" -gt "$LIMIT" ]; then
  block "body is ${SIZE} bytes (>${LIMIT})"
fi

exit 0
