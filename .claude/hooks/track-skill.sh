#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook — track /nase:* skill invocations to JSONL
# Input: JSON on stdin with tool_input.skill

NASE_ROOT="${NASE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -z "$NASE_ROOT" ] && exit 0
STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/skill-usage.jsonl"
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGGER="$HOOK_DIR/../scripts/kb-usage-log.py"

INPUT=$(cat)
# Single jq pass: emit "<skill>\t<status>\t<duration_ms>\t<session_id>". status derivation -
# `tool_response.is_error == true` or non-empty error field counts as error;
# everything else (including absent) is success. duration_ms surfaced from
# Claude Code 2.1.119+ hook JSON (top-level). Empty string when absent.
# Backward compat: readers must treat absent status/duration_ms as success/unknown.
if ! IFS=$'\t' read -r SKILL STATUS DUR_MS SESSION_ID < <(echo "$INPUT" | jq -r '
  [ (.tool_input.skill // ""),
    ((.tool_response // {}) as $r
     | if ($r.is_error == true) or (($r.error // "") != "") then "error" else "success" end),
    (.duration_ms // ""),
    (.session_id // .sessionId // "")
  ] | @tsv
' 2>/dev/null); then
  echo "[track-skill] WARNING: malformed JSON on stdin — skipping" >&2
  exit 0
fi

# Only track nase:* skills
case "$SKILL" in
  nase:*) ;;
  *) exit 0 ;;
esac

# Strip nase: prefix
SKILL_NAME="${SKILL#nase:}"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
[ -n "$SESSION_ID" ] || SESSION_ID="${CLAUDE_SESSION_ID:-${CLAUDE_SESSIONID:-}}"
if [ "$STATUS" = "error" ]; then
  EVENT_TYPE="tool_failed"
else
  EVENT_TYPE="tool_succeeded"
fi

mkdir -p "$STATS_DIR"

if command -v python3 >/dev/null 2>&1; then
  TRACK_ARGS=(activate --root "$NASE_ROOT" --skill "$SKILL_NAME" --source skill-hook)
  [ -n "$SESSION_ID" ] && TRACK_ARGS+=(--session "$SESSION_ID")
  python3 "$LOGGER" "${TRACK_ARGS[@]}" >/dev/null 2>&1 || true
fi

if [[ "$DUR_MS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg event "$EVENT_TYPE" --arg session "$SESSION_ID" --argjson d "$DUR_MS" \
    '{skill:$s,ts:$t,source:"skill-hook",event_type:$event,duration_ms:$d} + (if $session == "" then {} else {session_id:$session} end)' >> "$JSONL"
else
  jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg event "$EVENT_TYPE" --arg session "$SESSION_ID" \
    '{skill:$s,ts:$t,source:"skill-hook",event_type:$event} + (if $session == "" then {} else {session_id:$session} end)' >> "$JSONL"
fi
