# shellcheck shell=bash
# Shared helpers for .claude/hooks/*.sh. Source it; do not execute it.
#
#   . "$HOOK_DIR/../lib/hook-common.sh" || <fail open or closed, per hook>
#
# Rules this file keeps so any hook can source it safely:
#   - It sets no shell option and no global variable. Callers run under
#     `set -euo pipefail`, `set -uo pipefail`, or neither.
#   - Every function returns 0 or a documented status, and never calls `exit`. The one
#     exception is nase_fail_closed_exit, an EXIT-trap handler whose job is to exit.
#   - Bash 3.2 (macOS) compatible; builtins first, no GNU-only flags.
#
# A hook that cannot source this file decides its own failure mode. Guard hooks
# exit 2 (Claude Code blocks only on 2); tracking and lifecycle hooks exit 0.

# nase_root - print the workspace root: NASE_ROOT, else the git toplevel of the
# current directory. Returns 1 with no output when neither resolves; the caller
# picks the fallback.
# CLAUDE_PROJECT_DIR is deliberately not read here. hook-dispatch.sh resolves it
# and exports NASE_ROOT before it runs a hook, so a dispatched hook never needs
# it, and reading it here would make a direct run (a test, a manual debug) resolve
# to the real project instead of the git repo it was started in.
nase_root() {
  if [ -n "${NASE_ROOT:-}" ]; then
    printf '%s\n' "$NASE_ROOT"
    return 0
  fi
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  printf '%s\n' "$top"
}

# nase_require <cmd>... - return 0 when every command exists, 1 otherwise.
# Silent, so a hook chooses between fail-open (`|| exit 0`) and fail-closed
# (`|| block "..."`) and words its own message.
nase_require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || return 1
  done
  return 0
}

# nase_session_id [stdin_json] - print the session id, or nothing when unknown.
# Always returns 0, so `SID=$(nase_session_id "$INPUT")` is safe under set -e.
# Precedence:
#   1. .session_id / .sessionId in the hook's stdin JSON (when given and jq exists)
#   2. CLAUDE_CODE_SESSION_ID, the variable Claude Code sets
#   3. CLAUDE_SESSION_ID, then CLAUDE_SESSIONID (legacy names)
nase_session_id() {
  local json="${1:-}" sid=""
  if [ -n "$json" ] && command -v jq >/dev/null 2>&1; then
    sid=$(printf '%s' "$json" \
      | jq -r '(.session_id // .sessionId // "") | if type == "string" then . else tostring end' \
        2>/dev/null) || sid=""
  fi
  [ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CLAUDE_SESSIONID:-}}}"
  [ -z "$sid" ] || printf '%s\n' "$sid"
  return 0
}

# nase_now_utc - print the current UTC time as YYYY-MM-DDTHH:MM:SSZ.
nase_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# nase_append_jsonl <file> <json> - append one line, creating the parent directory.
# One printf, so one write(2) on an O_APPEND descriptor: concurrent sessions
# appending short lines do not interleave. <json> must already be a single
# compact line (jq -c). Returns 1 for an empty line or an unwritable target, and
# 2 for a missing file argument.
nase_append_jsonl() {
  local file="${1:-}" line="${2-}" dir
  [ -n "$file" ] || return 2
  [ -n "$line" ] || return 1
  case "$file" in
    */*) dir=${file%/*} ;;
    *) dir=. ;;
  esac
  [ -n "$dir" ] || dir=/
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n' "$line" 2>/dev/null >> "$file"
}

# nase_install_fail_closed_trap <hook-name> - for guard hooks. Claude Code blocks only
# on exit 2, so any other non-zero exit (set -e, an unbound variable, a failed
# subprocess) would let the tool call through. This maps such an exit to 2. Call it
# after sourcing this file, never before: a syntax error in a sourced file makes bash
# 3.2 exit through an installed trap with status 0, which would fail open.
nase_install_fail_closed_trap() {
  # shellcheck disable=SC2064 # The hook name is meant to be expanded now.
  trap "nase_fail_closed_exit '$1'" EXIT
  trap 'exit 2' HUP INT TERM
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap nase_install_fail_closed_trap sets.
nase_fail_closed_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
    echo "BLOCKED by $1: unexpected error (exit $status); failing closed." >&2
    status=2
  fi
  exit "$status"
}
