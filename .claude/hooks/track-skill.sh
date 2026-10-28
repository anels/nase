#!/usr/bin/env bash
# Sourced before `set -e`: on bash 3.2 a syntax error in a sourced file would otherwise
# end the shell with status 2 instead of reaching the `||` fallback below.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { echo "[track-skill] hook-common.sh unavailable - skipping" >&2; exit 0; }

set -euo pipefail

# PostToolUse hook — track /nase:* skill invocations to JSONL
# Input: JSON on stdin with tool_input.skill

NASE_ROOT=$(nase_root) || exit 0
STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/skill-usage.jsonl"
LOGGER="$HOOK_DIR/../scripts/kb-usage-log.py"

INPUT=$(cat)
# Single jq pass: emit "<skill>\u001f<status>\u001f<duration_ms>\u001f<session_id>". status derivation -
# `tool_response.is_error == true` or non-empty error field counts as error;
# everything else (including absent) is success. duration_ms surfaced from
# Claude Code 2.1.119+ hook JSON (top-level). Empty string when absent.
# The delimiter is \u001f, not a tab: tab is IFS whitespace, so `read` would
# collapse an empty duration and shift session_id into its slot.
# Backward compat: readers must treat absent status/duration_ms as success/unknown.
if ! PARSED=$(printf '%s' "$INPUT" | jq -r '
  [ (.tool_input.skill // ""),
    ((.tool_response // {}) as $r
     | if ($r.is_error == true) or (($r.error // "") != "") then "error" else "success" end),
    (.duration_ms // ""),
    (.session_id // .sessionId // "")
  ] | map(tostring) | join("\u001f")
' 2>/dev/null); then
  echo "[track-skill] WARNING: malformed JSON on stdin — skipping" >&2
  exit 0
fi
IFS=$'\037' read -r SKILL STATUS DUR_MS SESSION_ID <<< "$PARSED" || true

# Only track nase:* skills
case "$SKILL" in
  nase:*) ;;
  *) exit 0 ;;
esac

# Strip nase: prefix
SKILL_NAME="${SKILL#nase:}"
TS=$(nase_now_utc)
[ -n "$SESSION_ID" ] || SESSION_ID=$(nase_session_id)
if [ "$STATUS" = "error" ]; then
  EVENT_TYPE="tool_failed"
else
  EVENT_TYPE="tool_succeeded"
fi

if nase_require python3; then
  TRACK_ARGS=(activate --root "$NASE_ROOT" --skill "$SKILL_NAME" --source skill-hook)
  [ -n "$SESSION_ID" ] && TRACK_ARGS+=(--session "$SESSION_ID")
  python3 "$LOGGER" "${TRACK_ARGS[@]}" >/dev/null 2>&1 || true
fi

if [[ "$DUR_MS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  LINE=$(jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg event "$EVENT_TYPE" --arg session "$SESSION_ID" --argjson d "$DUR_MS" \
    '{skill:$s,ts:$t,source:"skill-hook",event_type:$event,duration_ms:$d} + (if $session == "" then {} else {session_id:$session} end)')
else
  LINE=$(jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg event "$EVENT_TYPE" --arg session "$SESSION_ID" \
    '{skill:$s,ts:$t,source:"skill-hook",event_type:$event} + (if $session == "" then {} else {session_id:$session} end)')
fi
nase_append_jsonl "$JSONL" "$LINE"
