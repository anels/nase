#!/usr/bin/env bash
set -euo pipefail

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$NASE_ROOT" ]; then
  exit 0
fi

# Pending todos — remind user before session ends
TODO_FILE="$NASE_ROOT/workspace/tasks/todo.md"
if [ -f "$TODO_FILE" ]; then
  # `|| true`: an empty todo list makes grep exit 1, and under `pipefail` that
  # aborts the hook with a non-zero Stop-event status instead of staying quiet.
  PENDING=$(grep '^[[:space:]]*- \[ \]' "$TODO_FILE" | sed 's/^[[:space:]]*- \[ \] //' | head -10 || true)
  TODO_COUNT=$(grep -c '^[[:space:]]*- \[ \]' "$TODO_FILE" 2>/dev/null || true)
  if [ -n "$PENDING" ]; then
    echo "[session-end] Pending todos ($TODO_COUNT):"
    while IFS= read -r item; do
      echo "[session-end]   • $item"
    done <<< "$PENDING"
  fi
fi
