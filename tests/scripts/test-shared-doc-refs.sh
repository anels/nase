#!/usr/bin/env bash
# Regression test for tests/check-shared-doc-refs.sh.
#
# Each case runs the gate inside a throwaway git repo, so the suite can hold
# probes that MUST fail. The gate once scanned with `grep -Z | awk`, which finds
# zero matches on BSD grep (macOS) and reported OK for a dead reference.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

GATE="$ROOT/tests/check-shared-doc-refs.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

new_repo() {
  local repo="$TMPROOT/$1"
  mkdir -p "$repo/.claude/docs" "$repo/.claude/commands/nase" "$repo/workspace/skills/docs"
  git -C "$repo" init -q
  printf '# Real doc\n' >"$repo/.claude/docs/real.md"
  printf 'See .claude/docs/real.md for details.\n' >"$repo/.claude/commands/nase/ok.md"
  printf '%s\n' "$repo"
}

run_gate() {
  local repo="$1" tag="$2"
  set +e
  (cd "$repo" && bash "$GATE") >"$TMPROOT/$tag.out" 2>"$TMPROOT/$tag.err"
  printf '%s\n' "$?" >"$TMPROOT/$tag.rc"
  set -e
}

rc_of() { cat "$TMPROOT/$1.rc"; }

# --- 1. every reference resolves ---
repo=$(new_repo clean)
run_gate "$repo" clean
[[ "$(rc_of clean)" == 0 ]] && pass "clean tree exits 0" || fail "clean tree exits 0 (rc=$(rc_of clean))"
assert_contains "clean tree prints OK" "$TMPROOT/clean.out" "OK: shared doc references resolve"

# --- 2. dead reference in a command file fails with the MISSING format ---
repo=$(new_repo dead)
printf 'Read .claude/docs/does-not-exist.md first.\n' >"$repo/.claude/commands/nase/bad.md"
run_gate "$repo" dead
[[ "$(rc_of dead)" == 1 ]] && pass "dead reference exits 1" || fail "dead reference exits 1 (rc=$(rc_of dead))"
assert_contains "dead reference names source and target" "$TMPROOT/dead.out" \
  "MISSING  .claude/commands/nase/bad.md -> .claude/docs/does-not-exist.md"

# --- 3. dead reference in CLAUDE.md and README.md (file scan paths, not dirs) ---
repo=$(new_repo dead-top)
printf 'Policy: .claude/docs/gone-claude.md\n' >"$repo/CLAUDE.md"
printf 'Guide: .claude/docs/gone-readme.md\n' >"$repo/README.md"
run_gate "$repo" dead-top
[[ "$(rc_of dead-top)" == 1 ]] && pass "dead top-level refs exit 1" || fail "dead top-level refs exit 1 (rc=$(rc_of dead-top))"
assert_contains "CLAUDE.md dead ref reported" "$TMPROOT/dead-top.out" "MISSING  CLAUDE.md -> .claude/docs/gone-claude.md"
assert_contains "README.md dead ref reported" "$TMPROOT/dead-top.out" "MISSING  README.md -> .claude/docs/gone-readme.md"

# --- 4. workspace/skills/docs refs: required from workspace files, skipped elsewhere ---
repo=$(new_repo ws-skip)
printf 'Local: workspace/skills/docs/local-only.md\n' >"$repo/.claude/commands/nase/ws.md"
run_gate "$repo" ws-skip
[[ "$(rc_of ws-skip)" == 0 ]] && pass "workspace doc ref from tracked file is skipped" || fail "workspace doc ref from tracked file is skipped (rc=$(rc_of ws-skip))"

repo=$(new_repo ws-own)
printf 'Local: workspace/skills/docs/local-only.md\n' >"$repo/workspace/skills/mine.md"
run_gate "$repo" ws-own
[[ "$(rc_of ws-own)" == 1 ]] && pass "workspace doc ref from workspace file must resolve" || fail "workspace doc ref from workspace file must resolve (rc=$(rc_of ws-own))"
assert_contains "workspace dead ref reported" "$TMPROOT/ws-own.out" \
  "MISSING  workspace/skills/mine.md -> workspace/skills/docs/local-only.md"

# --- 5. a source path containing a colon still parses ---
repo=$(new_repo colon)
printf 'Read .claude/docs/colon-gone.md\n' >"$repo/.claude/commands/nase/a:b.md"
run_gate "$repo" colon
[[ "$(rc_of colon)" == 1 ]] && pass "colon in source path still fails the gate" || fail "colon in source path still fails the gate (rc=$(rc_of colon))"
assert_contains "colon path reported whole" "$TMPROOT/colon.out" \
  "MISSING  .claude/commands/nase/a:b.md -> .claude/docs/colon-gone.md"

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nAll shared-doc-refs gate tests passed.\n'
