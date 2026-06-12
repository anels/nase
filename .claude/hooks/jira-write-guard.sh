#!/usr/bin/env bash
# PreToolUse guard: token-gate Jira mutations.
#
# Each gated Jira tool call must be immediately preceded by a JSON token at
# workspace/.jira-write-token, written by the calling skill after showing the
# payload to the user and receiving explicit approval. Two token modes:
#
#   - single-shot (legacy): binds the exact tool name + canonical payload sha;
#     consumed once (deleted after a single allowed call). TTL 300s.
#   - batch: binds an approved issue-key set + an op-count cap + TTL; consumed
#     up to max_ops times within the TTL. Use for an approved multi-ticket
#     batch (e.g. cancel N incidents) so one approval covers all the
#     transitions and comments without re-deriving a sha per call. TTL 900s.
#
# Batch mode trades the exact-payload binding for an issue allowlist plus a
# hard op-count + TTL ceiling, so a runaway loop still cannot touch tickets
# outside the approved set or exceed the approved op budget.
set -euo pipefail

SINGLE_TOKEN_TTL_SECONDS=300
BATCH_TOKEN_TTL_SECONDS=900

block_without_log() {
  local reason="$1"
  {
    echo "BLOCKED by jira-write-guard: $reason."
    echo ""
    echo "Jira mutation tools require a fresh JSON token at"
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
    echo "This Jira mutation tool ($TOOL) requires a fresh JSON token at"
    echo "workspace/.jira-write-token before it can execute. The token must be"
    echo "written by the calling skill after an AskUserQuestion has shown the"
    echo "payload(s) and the user has approved."
    echo ""
    echo "Single-shot token (one mutation, exact payload):"
    echo "  {"
    echo "    \"tool_name\": \"$TOOL\","
    echo "    \"issue_key\": \"PROJ-123\","
    echo "    \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "    \"payload_summary\": \"short human-readable summary\","
    echo "    \"payload_sha256\": \"sha256 of jq -cS .tool_input\""
    echo "  }"
    echo ""
    echo "Batch token (approved set, op-count cap, ${BATCH_TOKEN_TTL_SECONDS}s TTL):"
    echo "  {"
    echo "    \"approved_issues\": [\"PROJ-1\", \"PROJ-2\"],"
    echo "    \"max_ops\": 6,"
    echo "    \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "    \"payload_summary\": \"cancel approved incidents\""
    echo "  }"
    echo ""
    echo "Policy source: .claude/docs/external-mutation-policy.md"
  } >&2
  printf '%s BLOCKED %s (%s)\n' "$TS" "$TOOL" "$reason" >> "$LOG"
  [ -f "$TOKEN" ] && rm -f "$TOKEN"
  exit 2
}

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    block "no SHA-256 helper available"
  fi
}

issue_in_csv() {
  local issue="$1" csv="$2"
  case ",$csv," in
    *,"$issue",*) return 0 ;;
    *) return 1 ;;
  esac
}

parse_epoch() {
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || echo ""
}

if [ ! -f "$TOKEN" ]; then
  block "no jira-write-token present"
fi

TOKEN_CONTENT=$(cat "$TOKEN" 2>/dev/null || echo "")
if ! printf '%s' "$TOKEN_CONTENT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  block "invalid token JSON"
fi

# Issues named by the current payload (shared by both modes).
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

IS_BATCH=$(printf '%s' "$TOKEN_CONTENT" | jq -r '
  if (.approved_issues | type) == "array" and ((.approved_issues | length) > 0)
  then "1" else "0" end' 2>/dev/null || echo "0")

# ---------------------------------------------------------------------------
# Batch mode: approved issue set + op-count cap + TTL. Consumed up to max_ops.
# ---------------------------------------------------------------------------
if [ "$IS_BATCH" = "1" ]; then
  CREATED_AT=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.created_at // ""')
  MAX_OPS=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.max_ops // ""')
  TTL=$(printf '%s' "$TOKEN_CONTENT" | jq -r --argjson d "$BATCH_TOKEN_TTL_SECONDS" '.ttl_seconds // $d')
  PAYLOAD_SUMMARY=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.payload_summary // ""')

  [ -z "$CREATED_AT" ] && block "batch token missing created_at"
  [[ "$MAX_OPS" =~ ^[0-9]+$ ]] || block "batch token max_ops must be a positive integer"
  [ "$MAX_OPS" -gt 0 ] || block "batch token exhausted (max_ops=0)"
  [[ "$TTL" =~ ^[0-9]+$ ]] || block "batch token ttl_seconds must be an integer"

  # Optional tool allowlist. When present the current tool must match (exact
  # name or suffix, to tolerate MCP namespace-prefix differences).
  TOOLS_LEN=$(printf '%s' "$TOKEN_CONTENT" | jq -r '(.tools // []) | length')
  if [ "$TOOLS_LEN" -gt 0 ]; then
    TOOL_OK=$(printf '%s' "$TOKEN_CONTENT" | jq -r --arg t "$TOOL" '
      if (.tools | map(select(. as $e | ($e == $t) or ($t | endswith($e)))) | length) > 0
      then "1" else "0" end')
    [ "$TOOL_OK" = "1" ] || block "batch token does not authorize tool $TOOL"
  fi

  CREATED_TS=$(parse_epoch "$CREATED_AT")
  [ -z "$CREATED_TS" ] && block "batch token created_at is not parseable: $CREATED_AT"
  NOW_TS=$(date +%s)
  AGE=$((NOW_TS - CREATED_TS))
  if [ "$AGE" -lt 0 ] || [ "$AGE" -gt "$TTL" ]; then
    block "batch token is stale or from the future: age=${AGE}s ttl=${TTL}s"
  fi

  APPROVED_CSV=$(printf '%s' "$TOKEN_CONTENT" | jq -r '
    ([.approved_issues[]?, .issue_key, (.issue_keys[]? // empty)]
     | map(select(. != null and . != "") | tostring) | unique | join(","))')
  [ -z "$APPROVED_CSV" ] && block "batch token missing approved_issues"

  if [ -z "$CURRENT_ISSUES" ]; then
    block "batch token cannot authorize a call with no issue key (use a single-shot token for createJiraIssue)"
  fi

  while IFS= read -r current_issue; do
    [ -z "$current_issue" ] && continue
    issue_in_csv "$current_issue" "$APPROVED_CSV" \
      || block "batch token issue mismatch: $current_issue not in approved set [$APPROVED_CSV]"
  done < <(printf '%s\n' "$CURRENT_ISSUES" | tr ',' '\n')

  REMAINING=$((MAX_OPS - 1))
  if [ "$REMAINING" -le 0 ]; then
    rm -f "$TOKEN"
  else
    TMP="$TOKEN.tmp.$$"
    if printf '%s' "$TOKEN_CONTENT" | jq -c --argjson r "$REMAINING" '.max_ops = $r' > "$TMP" 2>/dev/null; then
      mv "$TMP" "$TOKEN"
    else
      rm -f "$TMP"
      block "could not decrement batch token max_ops"
    fi
  fi

  printf '%s ALLOWED %s | batch | issue: %s | remaining: %s | summary: %s\n' \
    "$TS" "$TOOL" "$CURRENT_ISSUES" "$REMAINING" "${PAYLOAD_SUMMARY:-n/a}" >> "$LOG"
  exit 0
fi

# ---------------------------------------------------------------------------
# Single-shot mode (legacy): exact tool + payload-sha binding, consumed once.
# ---------------------------------------------------------------------------
EXPECTED_TOOL=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.tool_name // ""')
CREATED_AT=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.created_at // ""')
PAYLOAD_SUMMARY=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.payload_summary // ""')
EXPECTED_PAYLOAD_SHA=$(printf '%s' "$TOKEN_CONTENT" | jq -r '.payload_sha256 // ""')

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
[ -z "$EXPECTED_PAYLOAD_SHA" ] && block "token missing payload_sha256"
if [ -z "$EXPECTED_ISSUES" ] && [[ "$TOOL" != *__createJiraIssue ]]; then
  block "token missing issue_key"
fi

CANONICAL_TOOL_INPUT=$(printf '%s' "$INPUT" | jq -cS '.tool_input // {}' 2>/dev/null \
  || block "could not canonicalize tool_input")
CURRENT_PAYLOAD_SHA=$(printf '%s\n' "$CANONICAL_TOOL_INPUT" | sha256_hex)
[ "$EXPECTED_PAYLOAD_SHA" = "$CURRENT_PAYLOAD_SHA" ] \
  || block "token payload mismatch: expected $EXPECTED_PAYLOAD_SHA, got $CURRENT_PAYLOAD_SHA"

CREATED_TS=$(parse_epoch "$CREATED_AT")
[ -z "$CREATED_TS" ] && block "token created_at is not parseable: $CREATED_AT"

NOW_TS=$(date +%s)
AGE=$((NOW_TS - CREATED_TS))
if [ "$AGE" -lt 0 ] || [ "$AGE" -gt "$SINGLE_TOKEN_TTL_SECONDS" ]; then
  block "token is stale or from the future: age=${AGE}s"
fi

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
