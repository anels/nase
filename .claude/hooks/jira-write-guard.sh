#!/usr/bin/env bash
# PreToolUse guard: token-gate Jira mutations.
#
# Each gated Jira tool call must be immediately preceded by a fresh single-shot
# JSON token at workspace/.jira-write-token. The calling skill writes the token
# after showing the exact payload to the user and receiving explicit approval.
set -euo pipefail

TOKEN_TTL_SECONDS=300

block_without_log() {
  local reason="$1"
  {
    echo "BLOCKED by jira-write-guard: $reason."
    echo ""
    echo "Jira mutation tools require a fresh single-shot JSON token at"
    echo "workspace/.jira-write-token before execution."
    echo ""
    echo "Policy source: .claude/docs/external-mutation-policy.md"
  } >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || block_without_log "jq is required to parse tool input"

INPUT=$(cat)
if ! TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null); then
  block_without_log "could not parse tool input JSON"
fi

case "$TOOL" in
  *__transitionJiraIssue|\
  *__editJiraIssue|\
  *__createJiraIssue|\
  *__addCommentToJiraIssue|\
  *__addWorklogToJiraIssue|\
  *__createIssueLink)
    ;;
  *)
    exit 0
    ;;
esac

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}"
TOKEN="$NASE_ROOT/workspace/.jira-write-token"
LOG="$NASE_ROOT/workspace/logs/.jira-writes.log"
mkdir -p "$NASE_ROOT/workspace/logs"

TS=$(date +%Y-%m-%dT%H:%M:%S)

block() {
  local reason="$1"
  {
    echo "BLOCKED by jira-write-guard: $reason."
    echo ""
    echo "This Jira mutation tool ($TOOL) requires a fresh single-shot JSON"
    echo "token at workspace/.jira-write-token before it can execute. The"
    echo "token must be written by the calling skill after an AskUserQuestion"
    echo "has shown the exact payload and the user has approved it."
    echo ""
    echo "Token shape:"
    echo "  {"
    echo "    \"tool_name\": \"$TOOL\","
    echo "    \"issue_key\": \"PROJ-123\","
    echo "    \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "    \"payload_summary\": \"short human-readable summary\""
    echo "  }"
    echo ""
    echo "Policy source: .claude/docs/external-mutation-policy.md"
  } >&2
  printf '%s BLOCKED %s (%s)\n' "$TS" "$TOOL" "$reason" >> "$LOG"
  [ -f "$TOKEN" ] && rm -f "$TOKEN"
  exit 2
}

issue_in_csv() {
  local issue="$1" csv="$2"
  case ",$csv," in
    *,"$issue",*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -f "$TOKEN" ]; then
  block "no jira-write-token present"
fi

TOKEN_CONTENT=$(cat "$TOKEN" 2>/dev/null || echo "")
if ! printf '%s' "$TOKEN_CONTENT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  block "invalid token JSON"
fi

EXPECTED_TOOL=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.tool_name // ""')
CREATED_AT=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.created_at // ""')
PAYLOAD_SUMMARY=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.payload_summary // ""')

EXPECTED_ISSUES=$(printf '%s' "$TOKEN_CONTENT" | jq -r '
  [
    .issue_key,
    (
      if (.issue_keys | type) == "array" then
        .issue_keys[]
      else
        empty
      end
    )
  ]
  | map(select(. != null and . != "") | tostring)
  | unique
  | .[]
')

[ -z "$EXPECTED_TOOL" ] && block "token missing tool_name"
[ "$EXPECTED_TOOL" = "$TOOL" ] || block "token tool mismatch: expected $EXPECTED_TOOL"
[ -z "$CREATED_AT" ] && block "token missing created_at"
if [ -z "$EXPECTED_ISSUES" ] && [[ "$TOOL" != *__createJiraIssue ]]; then
  block "token missing issue_key"
fi

CREATED_TS=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$CREATED_AT" +%s 2>/dev/null \
  || date -u -d "$CREATED_AT" +%s 2>/dev/null \
  || echo "")
[ -z "$CREATED_TS" ] && block "token created_at is not parseable: $CREATED_AT"

NOW_TS=$(date +%s)
AGE=$((NOW_TS - CREATED_TS))
if [ "$AGE" -lt 0 ] || [ "$AGE" -gt "$TOKEN_TTL_SECONDS" ]; then
  block "token is stale or from the future: age=${AGE}s"
fi

CURRENT_ISSUES=$(printf '%s' "$INPUT" | jq -r '
  [
    .tool_input.issueIdOrKey,
    .tool_input.issueKey,
    .tool_input.key,
    .tool_input.issue,
    .tool_input.id,
    .tool_input.inwardIssue,
    .tool_input.outwardIssue,
    .tool_input.inwardIssueKey,
    .tool_input.outwardIssueKey,
    .tool_input.fromIssueKey,
    .tool_input.toIssueKey
  ]
  | map(select(. != null) | tostring)
  | unique
  | join(",")
' 2>/dev/null || echo "")

APPROVED_ISSUES_CSV=${EXPECTED_ISSUES//$'\n'/,}

if [ -n "$EXPECTED_ISSUES" ]; then
  while IFS= read -r expected_issue; do
    [ -z "$expected_issue" ] && continue
    issue_in_csv "$expected_issue" "$CURRENT_ISSUES" \
      || block "token issue mismatch: expected $expected_issue, payload has ${CURRENT_ISSUES:-none}"
  done <<< "$EXPECTED_ISSUES"
fi

if [[ "$TOOL" == *__createIssueLink ]]; then
  while IFS= read -r current_issue; do
    [ -z "$current_issue" ] && continue
    issue_in_csv "$current_issue" "$APPROVED_ISSUES_CSV" \
      || block "token issue mismatch: payload has unapproved $current_issue"
  done < <(printf '%s\n' "$CURRENT_ISSUES" | tr ',' '\n')
fi

rm -f "$TOKEN"
printf '%s ALLOWED %s | issue: %s | summary: %s\n' "$TS" "$TOOL" "${APPROVED_ISSUES_CSV:-n/a}" "${PAYLOAD_SUMMARY:-n/a}" >> "$LOG"
exit 0
