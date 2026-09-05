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
set -euo pipefail

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
    echo "If the operation has no named tool, it has no approved gate. Show the"
    echo "user the exact operation name and inputs and ask them to run it, or"
    echo "save the payload under workspace/tmp/ for them to apply by hand."
    echo ""
    echo "Read-only work is unaffected: use discover and executeRead."
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
  *__executeWrite|*__executeDestructive)
    OPERATION=$(printf '%s' "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
    block "$TOOL would run \"${OPERATION:-<unnamed>}\" outside every payload-bound Atlassian gate"
    ;;
esac

exit 0
