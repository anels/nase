#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook — track /nase:* skill invocations to JSONL
# Input: JSON on stdin with tool_input.skill

WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
STATS_DIR="$WORKSPACE/work/stats"
JSONL="$STATS_DIR/skill-usage.jsonl"

INPUT=$(cat)
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')

# Only track nase:* skills
case "$SKILL" in
  nase:*) ;;
  *) exit 0 ;;
esac

# Strip nase: prefix
SKILL_NAME="${SKILL#nase:}"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$STATS_DIR"

# Dedup: skip if same skill + same second already recorded
if [ -f "$JSONL" ]; then
  LAST=$(tail -1 "$JSONL" 2>/dev/null || true)
  LAST_SKILL=$(echo "$LAST" | jq -r '.skill // empty' 2>/dev/null || true)
  LAST_TS=$(echo "$LAST" | jq -r '.ts // empty' 2>/dev/null || true)
  if [ "$LAST_SKILL" = "$SKILL_NAME" ] && [ "$LAST_TS" = "$TS" ]; then
    exit 0
  fi
fi

echo "{\"skill\":\"$SKILL_NAME\",\"ts\":\"$TS\"}" >> "$JSONL"
