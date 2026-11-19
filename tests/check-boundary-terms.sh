#!/usr/bin/env bash
# Enforce `workspace/context.md -> Workspace Boundary Policy` over tracked files.
#
# The term list lives in `workspace/boundary-terms.txt`, which is git-ignored so
# the terms never ship. `NASE_BOUNDARY_TERMS_FILE` points at another list; CI sets it
# from the NASE_BOUNDARY_TERMS secret. A fresh clone has no `workspace/`, so the gate skips with
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
#
# The Python gate skips with exit 0 when the term list is absent. Count that skip here so a
# gate that checked nothing says so at the end instead of reading as a pass. Absence is
# never a failure: the term list is per-user, and CI and fresh clones never have one.
# shellcheck source=lib/workspace-skip.sh
source "$SOURCE_ROOT/tests/lib/workspace-skip.sh"
# A set but missing override is the gate's exit 2, not a skip, so it is not counted here.
terms_file="${NASE_BOUNDARY_TERMS_FILE:-${NASE_BOUNDARY_SCAN_ROOT:-$ROOT}/workspace/boundary-terms.txt}"
[[ -f "$terms_file" || -n "${NASE_BOUNDARY_TERMS_FILE:-}" ]] || ws_count_skip
rc=0
python3 "$SOURCE_ROOT/.claude/scripts/check-boundary-terms.py" "$@" || rc=$?
ws_skip_summary
exit "$rc"
