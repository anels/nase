#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook — track /nase:* skill invocations to JSONL
# Input: JSON on stdin with tool_input.skill

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
STATS_DIR="$NASE_ROOT/workspace/stats"
JSONL="$STATS_DIR/skill-usage.jsonl"

INPUT=$(cat)
# Single jq pass: emit "<skill>\t<status>\t<duration_ms>". status derivation —
# `tool_response.is_error == true` or non-empty error field counts as error;
# everything else (including absent) is success. duration_ms surfaced from
# Claude Code 2.1.119+ hook JSON (top-level). Empty string when absent.
# Backward compat: readers must treat absent status/duration_ms as success/unknown.
if ! IFS=$'\t' read -r SKILL STATUS DUR_MS < <(echo "$INPUT" | jq -r '
  [ (.tool_input.skill // ""),
    ((.tool_response // {}) as $r
     | if ($r.is_error == true) or (($r.error // "") != "") then "error" else "success" end),
    (.duration_ms // "")
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

mkdir -p "$STATS_DIR"

# Dedup: skip if same skill + same second already recorded.
# Bash string match avoids a second jq fork on the hot path; JSONL is
# compact (one object per line) so substring match is safe.
if [ -f "$JSONL" ]; then
  LAST=$(tail -1 "$JSONL" 2>/dev/null || true)
  if [[ "$LAST" == *"\"skill\":\"$SKILL_NAME\""*"\"ts\":\"$TS\""* ]]; then
    exit 0
  fi
fi

if [[ "$DUR_MS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg st "$STATUS" --argjson d "$DUR_MS" \
    '{skill:$s,ts:$t,status:$st,duration_ms:$d}' >> "$JSONL"
else
  jq -cn --arg s "$SKILL_NAME" --arg t "$TS" --arg st "$STATUS" \
    '{skill:$s,ts:$t,status:$st}' >> "$JSONL"
fi
