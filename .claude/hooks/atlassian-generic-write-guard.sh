#!/usr/bin/env bash
# PreToolUse guard: block the Atlassian MCP's generic write runners.
#
# `executeWrite` and `executeDestructive` run any operation from the `discover`
# catalog by name. That includes every write the named guards cover
# (transitionJiraIssue, addOrEditJiraIssueComment, updateConfluenceContent, ...),
# so an ungated generic runner is a complete bypass of both the Jira write token
# and the Confluence size/format cap: the tool name no longer says what the call
# does, and neither guard's payload contract fits `{name, cloudId, inputs}`.
#
# Blocking is the fail-closed choice, matching how external-cli-write-guard.sh
# treats an unrecognized guarded CLI invocation. `executeRead` and `discover`
# are read-only and are not matched.
#
# One exception, gated here rather than waved through: `createConfluenceComment`
# under `executeWrite`. Confluence comments have no named MCP tool, so without
# this branch there is no approved path to reply on a page review thread at all.
# The exception is payload-bound the same way the named gates are - this guard
# reads the actual body and addressing fields and rejects anything it cannot
# account for, so the operation name alone never grants passage. Everything
# else, and every `executeDestructive`, stays blocked.
set -euo pipefail

# Confluence rejects a comment body over 4096 characters; bound bytes, which is
# the stricter side of that limit for any non-ASCII draft.
COMMENT_BODY_LIMIT=4096

block() {
  local reason="$1"
  {
    echo "BLOCKED by atlassian-generic-write-guard: $reason."
    echo ""
    echo "Run the write through its named tool instead, so the gate that owns it"
    echo "can see the payload:"
    echo "  Jira    transitionJiraIssue / editJiraIssue / createJiraIssue /"
    echo "          addOrEditJiraIssueComment  (jira-write-guard.sh, token-gated)"
    echo "  Confluence  create/updateConfluenceContent"
    echo "          (confluence-size-guard.sh, format + size capped)"
    echo ""
    echo "Confluence comments are the one operation with no named tool:"
    echo "  executeWrite name=\"createConfluenceComment\" is allowed when its"
    echo "  payload passes this guard's own checks."
    echo ""
    echo "If the operation has no named tool and no gate here, show the user the"
    echo "exact operation name and inputs and ask them to run it, or save the"
    echo "payload under workspace/tmp/ for them to apply by hand."
    echo ""
    echo "Read-only work is unaffected: use discover and executeRead."
    echo ""
    echo "Policy source: .claude/docs/external-mutation-policy.md"
  } >&2
  exit 2
}

block_comment() {
  local reason="$1"
  {
    echo "BLOCKED by atlassian-generic-write-guard: createConfluenceComment $reason."
    echo ""
    echo "A comment call must be readable by this guard before it is sent:"
    echo "  cloudId          top-level, non-empty"
    echo "  inputs.body      {\"format\": \"markdown\"|\"html\", \"value\": \"...\"},"
    echo "                   value non-empty and at most ${COMMENT_BODY_LIMIT} bytes"
    echo "  addressing       exactly one of:"
    echo "                     reply         parentCommentId only"
    echo "                     top-level     contentId + commentType \"footer\""
    echo "                     top-level     contentId + commentType \"inline\""
    echo "                                   + inlineSelection.selectedText"
    echo ""
    echo "Fix the payload and retry, or save the draft under workspace/tmp/ and"
    echo "ask the user to post it by hand."
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
  *__executeWrite) RUNNER="write" ;;
  *__executeDestructive) RUNNER="destructive" ;;
  *) exit 0 ;;
esac
OPERATION=$(printf '%s' "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")

if [ "$RUNNER" = "write" ] && [ "$OPERATION" = "createConfluenceComment" ]; then
  if ! VERDICT=$(printf '%s' "$INPUT" | jq -r --argjson limit "$COMMENT_BODY_LIMIT" '
        def nonempty($v): ($v | type) == "string" and $v != "";
        (.tool_input // {}) as $t
        | ($t.inputs // {}) as $i
        | ($i.body // null) as $b
        | (($b | objects | .format) // "") as $fmt
        | (($b | objects | .value) // "") as $val
        | ($i.parentCommentId // "") as $parent
        | ($i.contentId // "") as $content
        | ($i.commentType // "") as $ctype
        | ($i.inlineSelection // null) as $sel
        | if (nonempty($t.cloudId // "") | not) then "is missing cloudId"
          elif ($b | type) != "object" then "needs inputs.body as an object with format and value"
          elif ($fmt != "markdown" and $fmt != "html") then
            "sent inputs.body.format \"" + (if $fmt == "" then "<unset>" else $fmt end) + "\", expected \"markdown\" or \"html\""
          elif (nonempty($val) | not) then "sent an empty inputs.body.value"
          elif (($val | utf8bytelength) > $limit) then
            "sent a " + ($val | utf8bytelength | tostring) + " byte body (>" + ($limit | tostring) + ")"
          elif nonempty($parent) then
            (if (nonempty($content) or nonempty($ctype) or ($sel != null))
             then "sent parentCommentId together with top-level fields; a reply carries parentCommentId alone"
             else "ok" end)
          elif (nonempty($content) | not) then
            "has no target: pass parentCommentId for a reply, or contentId plus commentType for a top-level comment"
          elif ($ctype == "footer") then
            (if $sel != null then "sent inlineSelection on a footer comment" else "ok" end)
          elif ($ctype == "inline") then
            (if nonempty(($sel | objects | .selectedText) // "")
             then "ok"
             else "sent an inline comment without inlineSelection.selectedText" end)
          else
            "sent commentType \"" + (if $ctype == "" then "<unset>" else $ctype end) + "\", expected \"footer\" or \"inline\""
          end
  ' 2>/dev/null); then
    block_comment "payload could not be parsed"
  fi
  if [ "$VERDICT" = "ok" ]; then
    exit 0
  fi
  block_comment "$VERDICT"
fi

block "$TOOL would run \"${OPERATION:-<unnamed>}\" outside every payload-bound Atlassian gate"
