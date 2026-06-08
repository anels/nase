#!/usr/bin/env bash
# PreToolUse Edit|Write|MultiEdit hook — fact-forcing investigation gate.
#
# Inspired by affaan-m/ECC scripts/hooks/gateguard-fact-force.js:
# https://github.com/affaan-m/everything-claude-code/blob/main/scripts/hooks/gateguard-fact-force.js
# instead of letting the LLM edit reflexively, demand three concrete facts
# before the first edit of a source file in a session: callers/importers,
# public-API impact, and the originating user instruction.
#
# Non-blocking — emits a PreToolUse additionalContext reminder once per session
# per file. Exit 0.
#
# Scope:
#   - Fires for Edit/Write/MultiEdit on source files (.py .ts .tsx .js .jsx .go .cs
#     .rb .rs .java .sh .kt .swift .cpp .c .h)
#   - Skips: anything under workspace/, docs/, tests/, *.md, *.json, *.yml
#   - Skips files not already present on disk (Write of brand-new file —
#     no callers to enumerate)
#
# Session state: ${TMPDIR:-/tmp}/nase-fact-force.${session}.state. 30-min
# inactivity expiry. Caps entries at 500 to bound disk use.

set -euo pipefail

[[ "${NASE_FACT_FORCE:-1}" == "0" ]] && exit 0

STATE_DIR="${TMPDIR:-/tmp}"
SESSION_ID="${CLAUDE_SESSION_ID:-${PPID}}"
STATE_FILE="${STATE_DIR}/nase-fact-force.${SESSION_ID}.state"
SESSION_TIMEOUT_SECS=$((30 * 60))
MAX_ENTRIES=500

# Read tool input from stdin; if jq missing, exit silently (don't block edits).
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[[ -z "$FILE_PATH" ]] && exit 0

# Skip non-source files.
case "$FILE_PATH" in
  workspace/*|*/workspace/*|docs/*|*/docs/*|tests/*|*/tests/*|*.md|*.json|*.yml|*.yaml|*.toml|*.txt|*.lock|*.log) exit 0 ;;
esac
case "$FILE_PATH" in
  *.py|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.go|*.cs|*.rb|*.rs|*.java|*.kt|*.kts|*.swift|*.cpp|*.cc|*.c|*.h|*.hpp|*.sh|*.bash) ;;
  *) exit 0 ;;
esac

# Brand-new file (Write only) — no callers, skip.
[[ -f "$FILE_PATH" ]] || exit 0

# Initialise or expire stale state file.
if [[ -f "$STATE_FILE" ]]; then
  # macOS stat -f vs Linux stat -c — try BSD first.
  if mtime=$(stat -f '%m' "$STATE_FILE" 2>/dev/null); then
    :
  else
    mtime=$(stat -c '%Y' "$STATE_FILE" 2>/dev/null || echo 0)
  fi
  now=$(date +%s)
  age=$((now - mtime))
  if (( age > SESSION_TIMEOUT_SECS )); then
    : > "$STATE_FILE"
  fi
fi

# Already warned this session? Exit silently.
if [[ -f "$STATE_FILE" ]] && grep -qxF "$FILE_PATH" "$STATE_FILE"; then
  exit 0
fi

# Cap the state file at MAX_ENTRIES (truncate oldest by keeping tail).
if [[ -f "$STATE_FILE" ]]; then
  entries=$(wc -l < "$STATE_FILE" | tr -d ' ')
  if (( entries >= MAX_ENTRIES )); then
    tmp_state="${STATE_FILE}.tmp"
    tail -n $((MAX_ENTRIES - 1)) "$STATE_FILE" > "$tmp_state" && mv "$tmp_state" "$STATE_FILE"
  fi
fi

# Record the file as warned.
echo "$FILE_PATH" >> "$STATE_FILE"

context=$(cat <<EOF
[fact-force] First edit to $FILE_PATH this session. Before applying, in your
next response include three facts so the change is grounded, not reflexive:

  1. Callers — name 2-3 files / functions that import or call into this file.
     If you have not grep'd yet, do so now ("grep -rn '<symbol>' <repo>").
  2. Public-API impact — does this change the file's exported surface
     (signatures, return shapes, exception kinds, side effects)? Yes/No + 1 line.
  3. Origin — quote the user instruction (or upstream task description) that
     authorizes this edit. If you cannot quote it, pause and ask.

Inspired by ECC gateguard-fact-force. Disable with NASE_FACT_FORCE=0.
EOF
)

jq -n --arg ctx "$context" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'

exit 0
