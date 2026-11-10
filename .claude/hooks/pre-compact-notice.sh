#!/usr/bin/env bash
# PreCompact notice — warn that compaction is about to run and what must survive it.
#
# PreCompact fires before the model enters context compression. Unlike
# pre-compact-archive.sh (which only rotates stale artifacts), this hook
# surfaces a reminder of what the next session will NOT have unless it was
# written down first, and what to re-read afterwards. It never blocks and
# never mutates files.
#
# Run from repo root: bash .claude/hooks/pre-compact-notice.sh

HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
# shellcheck source=../lib/hook-common.sh
{ [ -r "$HOOK_DIR/../lib/hook-common.sh" ] && . "$HOOK_DIR/../lib/hook-common.sh"; } 2>/dev/null \
  || { printf '%s\n' '{"systemMessage":"[compact] hook-common unavailable - checkpoint your active effort doc manually before compaction"}'; exit 0; }

set -euo pipefail

NASE_ROOT=$(nase_root) || NASE_ROOT=""
if [ -z "$NASE_ROOT" ]; then
  printf '%s\n' '{"systemMessage":"[compact] cannot resolve workspace root - checkpoint your active effort doc manually before compaction"}'
  exit 0
fi

# Read the PreCompact payload (best-effort; fail open).
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi
TRIGGER=""
CUSTOM=""
if [ -n "$INPUT" ]; then
  if command -v jq >/dev/null 2>&1; then
    TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // empty' 2>/dev/null || true)
    CUSTOM=$(printf '%s' "$INPUT" | jq -r '.custom_instructions // empty' 2>/dev/null || true)
  elif command -v python3 >/dev/null 2>&1; then
    TRIGGER=$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("trigger",""))' 2>/dev/null || true)
    CUSTOM=$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("custom_instructions",""))' 2>/dev/null || true)
  fi
fi

MSG="[compact] Compaction is about to run"
if [ -n "$TRIGGER" ]; then
  MSG="$MSG ($TRIGGER)"
fi
MSG="$MSG. Before it does, write down what the next session must not lose: active repo/path/branch, current task and plan, changed files, the verification run and its failing output, and the active effort doc path. The post-compaction session restarts with only the summary — treat it as a claim, not evidence, and re-read the effort doc named in the last session note before acting."
if [ -n "$CUSTOM" ]; then
  MSG="$MSG Custom instructions in effect: $CUSTOM"
fi

if command -v jq >/dev/null 2>&1; then
  jq -cn --arg msg "$MSG" '{systemMessage:$msg}'
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; print(json.dumps({"systemMessage":sys.argv[1]}))' "$MSG"
else
  printf '[compact] %s\n' "$MSG"
fi
exit 0
