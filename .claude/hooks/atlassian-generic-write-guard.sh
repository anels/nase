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
# account for, so the operation name alone never grants passage. It also needs the
# same user-approved single-shot token a Jira comment needs, and a body that passes
# prose-lint. Everything else, and every `executeDestructive`, stays blocked.
set -euo pipefail

# Load the shared lib before the EXIT trap below. A syntax error in a sourced file
# makes bash 3.2 exit through the trap with status 0, which would fail open; with no
# trap yet, `set -e` exits 2 and the guard blocks.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "BLOCKED by atlassian-generic-write-guard: hook-common.sh is missing or unreadable; failing closed." >&2; exit 2; }

nase_install_fail_closed_trap atlassian-generic-write-guard

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
    echo "  payload passes this guard's own checks, its body passes prose-lint, and"
    echo "  a user-approved single-shot token (jira-write-token.py) binds it."
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

nase_require jq || block "jq is required to parse tool input"

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
  if [ "$VERDICT" != "ok" ]; then
    block_comment "$VERDICT"
  fi

  # Shape alone is not approval. A comment is outbound prose, so it gets the two gates a
  # Jira comment gets: the plain-writing lint, then the single-shot approval token
  # (workspace/.jira-write-token, bound to this tool name and exact payload) checked and
  # consumed by jira-write-guard.sh. Lint runs first so a failing draft does not spend
  # the token. The lint fails open on infrastructure problems, like prose-lint-guard.sh.
  if [ "${NASE_PROSE_LINT:-1}" != "0" ]; then
    LINT="$HOOK_DIR/../scripts/prose-lint.py"
    if [ -r "$LINT" ] && command -v python3 >/dev/null 2>&1; then
      COMMENT_FILE=$(mktemp) || COMMENT_FILE=""
      if [ -n "$COMMENT_FILE" ]; then
        printf '%s' "$INPUT" | jq -r '
          .tool_input.inputs.body as $b
          | if $b.format == "html" then ($b.value | gsub("<[^>]*>"; " ")) else $b.value end
        ' > "$COMMENT_FILE" 2>/dev/null || : > "$COMMENT_FILE"
        set +e
        LINT_REPORT=$(python3 "$LINT" --surface confluence-doc --file "$COMMENT_FILE" 2>/dev/null)
        LINT_RC=$?
        set -e
        rm -f "$COMMENT_FILE"
        if [ "$LINT_RC" -eq 1 ] && [[ "$LINT_REPORT" == *"Result: FAIL"* ]]; then
          {
            echo "BLOCKED by atlassian-generic-write-guard: the createConfluenceComment body fails the plain-writing gate."
            echo ""
            echo "$LINT_REPORT"
            echo ""
            echo "Fix the findings, then retry. See .claude/docs/plain-writing-guard.md."
            echo "Set NASE_PROSE_LINT=0 only when the flagged text quotes someone else."
          } >&2
          exit 2
        fi
      fi
    fi
  fi

  GATE="$HOOK_DIR/jira-write-guard.sh"
  [ -r "$GATE" ] || block_comment "cannot read the approval-token gate $GATE; failing closed"
  set +e
  printf '%s' "$INPUT" | bash "$GATE"
  GATE_RC=$?
  set -e
  [ "$GATE_RC" -eq 0 ] || exit 2
  exit 0
fi

block "$TOOL would run \"${OPERATION:-<unnamed>}\" outside every payload-bound Atlassian gate"
