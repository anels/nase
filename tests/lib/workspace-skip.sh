#!/usr/bin/env bash
# Counted skips for assertions that read git-ignored `workspace/` files.
#
# A bare `SKIP` line is easy to miss, and a gate that skips everything looks the same as a
# gate that passed. Source this file, route every workspace-only skip through
# `ws_count_skip`, and call `ws_skip_summary` last so the total is on screen.
#
# Rule: `workspace/skills/` absent means a fresh clone or CI, so a missing named file is a
# skip. `workspace/skills/` present means the file list is checkable here, so a missing
# named file is a failure (`ws_file_status` returns 2) - a renamed or deleted skill must
# not turn its assertions into silent skips.
#
# Usage:
#   source "$ROOT/tests/lib/workspace-skip.sh"
#   rc=0; ws_file_status "$file" || rc=$?     # 0 present, 1 skip, 2 missing
#   ws_count_skip                             # on rc 1
#   ws_skip_summary                           # last
#
# Python blocks count through tests/lib/workspace_skip.py. Call `ws_skip_file_init` before
# them so their skips land in the same total.

WS_SKIPPED=0
WS_SKIP_FILE=""

ws_file_status() {
  [[ -f "$1" ]] && return 0
  if [[ -d workspace/skills ]]; then
    return 2
  fi
  return 1
}

ws_count_skip() {
  WS_SKIPPED=$((WS_SKIPPED + 1))
}

ws_skip_file_init() {
  WS_SKIP_FILE=$(mktemp "${TMPDIR:-/tmp}/nase-ws-skips-XXXXXXXX")
  export WS_SKIP_FILE
}

ws_skip_summary() {
  local total="$WS_SKIPPED" from_file=0
  if [[ -n "$WS_SKIP_FILE" && -f "$WS_SKIP_FILE" ]]; then
    from_file=$(wc -l <"$WS_SKIP_FILE")
    from_file=$((from_file + 0))
    rm -f "$WS_SKIP_FILE"
    WS_SKIP_FILE=""
  fi
  total=$((total + from_file))
  if (( total > 0 )); then
    printf '[warn] %d workspace-only assertions skipped (workspace/ is local-only)\n' "$total" >&2
  fi
  return 0
}
