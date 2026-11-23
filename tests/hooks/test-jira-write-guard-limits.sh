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

# Windows has no flock, so the lock helper refuses to run there without this opt-in.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) export NASE_WEAK_LOCK=1 ;;
esac

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

# The decrement rewrites the token in place; it used to fsync a read-only handle and
# open the directory, both of which Windows refuses.
write_token 0 3 ""
expect "batch call with ops left is allowed" 0
if [ "$(jq -r '.max_ops' "$TOKEN" 2>/dev/null | tr -d '\r')" = "2" ]; then
  pass "batch token max_ops is decremented in place"
else
  fail "batch token max_ops was not decremented (token: $(cat "$TOKEN" 2>/dev/null))"
fi

# A lock helper that warns on stderr before printing its lease must still yield the lease.
NOISY_BIN="$TMP_ROOT/noisy-bin"
mkdir -p "$NOISY_BIN"
REAL_PYTHON=$(command -v python3)
cat >"$NOISY_BIN/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in *workspace_lock.py*acquire*) echo "WARNING: lock helper noise" >&2 ;; esac
exec "$REAL_PYTHON" "\$@"
EOF
chmod +x "$NOISY_BIN/python3"
write_token 0 3 ""
OLD_PATH=$PATH
PATH="$NOISY_BIN:$PATH"
expect "stderr noise from the lock helper does not invalidate the lease" 0
PATH=$OLD_PATH

# A single-shot token naming two issues: jq prints one key per line, and a CRLF jq
# used to leave a carriage return on the first key.
link_tool="mcp__plugin_atlassian_atlassian__createIssueLink"
input=$(jq -cn --arg tool "$link_tool" \
  '{tool_name:$tool,tool_input:{inwardIssue:"SRE-1",outwardIssue:"SRE-2",type:"Blocks"}}')
link_sha=$(printf '%s' "$input" | jq -cS '.tool_input' | tr -d '\r' | {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
} | awk '{print $1}')
jq -n --arg tool "$link_tool" --arg created "$(stamp 0)" --arg sha "$link_sha" \
  '{tool_name:$tool,issue_keys:["SRE-1","SRE-2"],created_at:$created,payload_sha256:$sha,payload_summary:"link"}' >"$TOKEN"
expect "single-shot token with two issue keys matches both" 0
input=$(jq -cn --arg tool "$tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-1"}}')

rm -f "$TOKEN"
expect "block message names the sanctioned token script" 2 "jira-write-token.py"

# An unexpected failure before the lock is taken must block (exit 2), not exit 1.
BROKEN_BIN="$TMP_ROOT/broken-bin"
mkdir -p "$BROKEN_BIN"
printf '#!/usr/bin/env bash\nexit 3\n' >"$BROKEN_BIN/date"
chmod +x "$BROKEN_BIN/date"
write_token 0 3 ""
PATH="$BROKEN_BIN:$PATH"
expect "an unexpected error before the lock fails closed" 2 "failing closed"
PATH=$OLD_PATH

# The token writer must report success once the token is in place.
printf '{"probe":true}' >"$TMP_ROOT/content.json"
rm -f "$TOKEN"
if python3 "$ROOT/.claude/scripts/jira-write-token.py" --root "$TMP_ROOT" \
  --content-file "$TMP_ROOT/content.json" >/dev/null 2>&1 && [ -f "$TOKEN" ]; then
  pass "jira-write-token.py exits 0 after publishing the token"
else
  fail "jira-write-token.py failed or left no token"
fi

if [ "$failures" -gt 0 ]; then
  printf '%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'All jira-write-guard limit tests passed\n'
