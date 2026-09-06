#!/usr/bin/env bash
# Verify workspace/tasks/todo.md and workspace/efforts/ reconcile in both directions:
# every queue pointer resolves, every active effort is queued, and no item is left
# checked. The contract is stated in `.claude/commands/nase/kb-review.md` under
# *Deep review -> Authoritative state*; before this gate it was prompt-enforced only.
#
# `workspace/` is git-ignored, so this skips rather than fails when it is absent.
#
# Run from repo root:  bash tests/check-effort-pointer-integrity.sh
# Exit 0 = both directions reconcile, exit 1 = at least one drift.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

# The gate body is a separate Python file: bash 3.2 (macOS) mis-scans a heredoc body
# inside command substitution, so this script never wraps one.
exec python3 .claude/scripts/check-effort-pointer-integrity.py "$@"
