#!/usr/bin/env bash
set -euo pipefail

# PostToolUseFailure hook — append a bounded failure summary.

command -v jq >/dev/null 2>&1 || exit 0

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -z "$NASE_ROOT" ] && exit 0

STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/tool-failures.jsonl"
mkdir -p "$STATS_DIR"

INPUT=$(cat)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EVENT="${HOOK_EVENT_NAME:-PostToolUseFailure}"

printf '%s' "$INPUT" | jq -c --arg ts "$TS" --arg event "$EVENT" '
  def clip($x; $n):
    (($x // "") | tostring) as $s
    | if ($s | length) > $n then ($s[0:$n] + "...") else $s end;
  def scrub:
    tostring
    | gsub("(?i)bearer[[:space:]]+[A-Za-z0-9._~+/=-]+"; "Bearer [REDACTED]")
    | gsub("(?i)(token|api[-_]?key|password|passwd|pwd|secret|pat)[[:space:]]*[:=][[:space:]]*[^[:space:]\"'\'']+"; "[REDACTED_SECRET]")
    | gsub("gh[pousr]_[A-Za-z0-9_]{20,}"; "[REDACTED_GITHUB_TOKEN]")
    | gsub("sk-[A-Za-z0-9_-]{20,}"; "[REDACTED_API_KEY]")
    | gsub("https?://[^[:space:]@]+:[^[:space:]@]+@"; "https://[REDACTED]@");
  {
    ts: $ts,
    event: $event,
    session: (.session_id // env.CLAUDE_SESSION_ID // ""),
    tool: (.tool_name // .toolName // .tool // .matcher // ""),
    status: "failure",
    duration_ms: (.duration_ms // null),
    error: clip(((.error // .tool_error // .tool_response.error // .message) | scrub); 500)
  }
' >> "$JSONL" 2>/dev/null || true
