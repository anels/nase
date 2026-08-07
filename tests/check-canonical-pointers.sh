#!/usr/bin/env bash
# Verify every skill reaches the language preflight through the canonical
# pointer declared in `.claude/docs/language-config.md → Canonical pointer`,
# and that no skill carries a second, drifting copy of the preflight rules.
#
# `workspace/` is local and ignored, so workspace skills are checked only when
# that directory exists.
#
# Run from repo root:  bash tests/check-canonical-pointers.sh
# Exit 0 = every skill uses the canonical pointer, exit 1 = at least one drift.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

# The Python gate is a separate file: bash 3.2 (macOS) mis-scans a heredoc
# body inside command substitution, so this script never wraps one.
exec python3 .claude/scripts/check-canonical-pointers.py "$@"
