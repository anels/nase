#!/usr/bin/env bash
set -euo pipefail

NASE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [ -z "$NASE_ROOT" ]; then
  exit 0
fi

# Pending todos — remind user before session ends
TODO_FILE="$NASE_ROOT/workspace/tasks/todo.md"
if [ -f "$TODO_FILE" ]; then
  PENDING=$(grep '^\s*- \[ \]' "$TODO_FILE" | sed 's/.*- \[ \] //' | head -10)
  TODO_COUNT=$(grep -c '^\s*- \[ \]' "$TODO_FILE" 2>/dev/null || true)
  if [ -n "$PENDING" ]; then
    echo "[session-end] Pending todos ($TODO_COUNT):"
    while IFS= read -r item; do
      echo "[session-end]   • $item"
    done <<< "$PENDING"
  fi
fi
