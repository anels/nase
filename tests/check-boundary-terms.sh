#!/usr/bin/env bash
# Enforce `workspace/context.md -> Workspace Boundary Policy` over tracked files.
#
# The term list lives in `workspace/boundary-terms.txt`, which is git-ignored so
# the terms never ship. A fresh clone has no `workspace/`, so the gate skips with
# a notice rather than failing.
#
# Findings print `path:line` with the matched term redacted, because this gate
# runs in CI on a public repo.
#
# Run from repo root:  bash tests/check-boundary-terms.sh
# Exit 0 = clean or skipped, 1 = at least one violation, 2 = malformed term list.

set -euo pipefail

SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

# `NASE_BOUNDARY_SCAN_ROOT` lets the regression test aim the gate at a throwaway
# git repo, so a probe that must fail can actually be run.
# The Python gate is a separate file: bash 3.2 (macOS) mis-scans a heredoc body
# inside command substitution, so this script never wraps one.
exec python3 "$SOURCE_ROOT/.claude/scripts/check-boundary-terms.py" "$@"
