#!/usr/bin/env bash
# Regression tests for the batch-token ceilings in jira-write-guard.sh.
#
# A batch token carries its own ttl_seconds and max_ops, so the hook has to cap
# both. ttl_seconds may only shorten the 900s window and max_ops may not exceed
# 100. Each case writes a token by hand, the way a forged or runaway one would.
#
# Run from repo root:  bash tests/hooks/test-jira-write-guard-limits.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/.claude/hooks/jira-write-guard.sh"

failures=0
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/workspace/logs"
TOKEN="$TMP_ROOT/workspace/.jira-write-token"

tool="mcp__plugin_atlassian_atlassian__transitionJiraIssue"
input=$(jq -cn --arg tool "$tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-1"}}')

# stamp OFFSET_SECONDS: a created_at that many seconds in the past, in UTC.
stamp() {
  local off="$1" now
  now=$(date +%s)
  date -u -r $((now - off)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$((now - off))" +%Y-%m-%dT%H:%M:%SZ
}

# write_token AGE_SECONDS MAX_OPS TTL_JSON ; TTL_JSON is raw JSON, or "" to omit it.
write_token() {
  local age="$1" ops="$2" ttl="$3" created
  created=$(stamp "$age")
  if [ -n "$ttl" ]; then
    jq -n --arg created "$created" --argjson ops "$ops" --argjson ttl "$ttl" \
      '{approved_issues:["SRE-1"],max_ops:$ops,created_at:$created,ttl_seconds:$ttl,payload_summary:"limits"}' >"$TOKEN"
  else
    jq -n --arg created "$created" --argjson ops "$ops" \
      '{approved_issues:["SRE-1"],max_ops:$ops,created_at:$created,payload_summary:"limits"}' >"$TOKEN"
  fi
}

# run_hook sets RC and OUT.
run_hook() {
  set +e
  OUT=$(printf '%s' "$input" | NASE_ROOT="$TMP_ROOT" bash "$HOOK" 2>&1)
  RC=$?
  set -e
}

expect() {
  local name="$1" want_rc="$2" pattern="${3:-}"
  run_hook
  if [ "$RC" -ne "$want_rc" ]; then
    fail "$name (rc=$RC want=$want_rc out=$OUT)"
  elif [ -n "$pattern" ] && [[ "$OUT" != *"$pattern"* ]]; then
    fail "$name (missing '$pattern' in: $OUT)"
  else
    pass "$name"
  fi
}

set -e

write_token 0 3 ""
expect "fresh batch token with default ttl is allowed" 0

# A 20-minute-old token is past the 900s ceiling, so a huge ttl_seconds must not revive it.
write_token 1200 3 99999
expect "ttl_seconds 99999 cannot extend a 20-minute-old token" 2 "stale"

write_token 1200 3 '"99999999999999999999"'
expect "string ttl_seconds of 20 digits cannot extend a stale token" 2 "stale"

# A fresh token with an absurd ttl is still valid. The clamp must not trip on the
# digit count and must not turn into an arithmetic error.
write_token 0 3 99999999999999999999
expect "ttl_seconds of 20 digits on a fresh token is clamped, not rejected" 0

write_token 0 3 '"99999999999999999999"'
expect "string ttl_seconds of 20 digits on a fresh token is clamped, not rejected" 0

write_token 0 3 60
expect "ttl_seconds below the ceiling is honoured on a fresh token" 0
write_token 120 3 60
expect "ttl_seconds below the ceiling shortens the window" 2 "stale"

write_token 0 100 ""
expect "max_ops at the ceiling is allowed" 0
write_token 0 101 ""
expect "max_ops of 101 is blocked" 2 "ceiling"
write_token 0 100000 ""
expect "max_ops of 100000 is blocked" 2 "ceiling"
write_token 0 '"00000000000000000000001"' ""
expect "max_ops with more than 4 digits is blocked even when small" 2 "ceiling"

rm -f "$TOKEN"
expect "block message names the sanctioned token script" 2 "jira-write-token.py"

if [ "$failures" -gt 0 ]; then
  printf '%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'All jira-write-guard limit tests passed\n'
