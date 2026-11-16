#!/usr/bin/env bash
# Regression tests for .claude/hooks/stop-claim-check.sh, the Stop wrapper around
# .claude/scripts/claim-check.py. The script has its own suite (tests/scripts/
# test-claim-check.sh); this one covers what only the wrapper does.
#
# What has to hold: the hook never fails the Stop event, stays silent on empty input, hands
# the payload to the script, exports the root it resolved so the script can place its dedupe
# marker, and fails open when python3 is not on PATH.
#
# Run from repo root:  bash tests/hooks/test-stop-claim-check.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/stop-claim-check.sh"
FIX="$ROOT/tests/fixtures/transcripts"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

pass=0
fail=0

ok() {
  printf 'PASS  %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2
  fail=$((fail + 1))
}

# A throwaway git repo whose .claude is the real one, so the hook runs the real script
# while the dedupe marker lands in the scratch workspace/tmp.
make_repo() {
  local dir="$SCRATCH/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  ln -s "$ROOT/.claude" "$dir/.claude"
  printf '%s' "$dir"
}

payload() {
  printf '{"transcript_path":"%s/b-no-run.jsonl","session_id":"%s"}' "$FIX" "$1"
}

# run_hook <cwd> <path> <stdin> [VAR=value ...]  -> sets OUT and RC
run_hook() {
  local cwd="$1" path="$2" stdin="$3"
  shift 3
  RC=0
  OUT=$(cd "$cwd" && printf '%s' "$stdin" | env -u NASE_ROOT "$@" PATH="$path" bash "$HOOK" 2>&1) || RC=$?
}

# --- 1. empty stdin: silent, exit 0, no marker ---
repo=$(make_repo empty)
run_hook "$repo" "$PATH" ""
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "empty stdin exits 0 and prints nothing"; else bad "empty stdin exits 0 and prints nothing" "rc=$RC out=$OUT"; fi
if [ ! -e "$repo/workspace" ]; then ok "empty stdin creates no workspace state"; else bad "empty stdin creates no workspace state"; fi

# --- 2. valid payload reaches the script and its dedupe marker ---
repo=$(make_repo valid)
run_hook "$repo" "$PATH" "$(payload s-valid)"
marker="$repo/workspace/tmp/claim-check-s-valid.state"
if [ "$RC" -eq 0 ] && grep -q '"systemMessage"' <<<"$OUT" && grep -q 'claim-check' <<<"$OUT"; then
  ok "a payload with an unproven claim reaches claim-check.py and warns"
else
  bad "a payload with an unproven claim reaches claim-check.py and warns" "rc=$RC out=$OUT"
fi
# --- 3. the wrapper exports NASE_ROOT: with it unset the marker still lands in the repo ---
if [ -f "$marker" ]; then
  ok "the wrapper exports NASE_ROOT, so the script writes its dedupe marker under it"
else
  bad "the wrapper exports NASE_ROOT, so the script writes its dedupe marker under it" "$(find "$repo" -type f 2>/dev/null | head -5)"
fi
run_hook "$repo" "$PATH" "$(payload s-valid)"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "the same state is not warned about twice"; else bad "the same state is not warned about twice" "rc=$RC out=$OUT"; fi

# An explicit NASE_ROOT wins over the git toplevel of the cwd.
repo=$(make_repo explicit-cwd)
other=$(make_repo explicit-root)
run_hook "$repo" "$PATH" "$(payload s-explicit)" NASE_ROOT="$other"
if [ -f "$other/workspace/tmp/claim-check-s-explicit.state" ] && [ ! -e "$repo/workspace" ]; then
  ok "an explicit NASE_ROOT is the root the script receives"
else
  bad "an explicit NASE_ROOT is the root the script receives"
fi

# --- 4. malformed payloads never fail the Stop event ---
repo=$(make_repo malformed)
run_hook "$repo" "$PATH" "{not json"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "malformed JSON exits 0 and prints nothing"; else bad "malformed JSON exits 0 and prints nothing" "rc=$RC out=$OUT"; fi
run_hook "$repo" "$PATH" '{"transcript_path":"/nonexistent/transcript.jsonl","session_id":"s-gone"}'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "a missing transcript exits 0 and prints nothing"; else bad "a missing transcript exits 0 and prints nothing" "rc=$RC out=$OUT"; fi

# --- 5. no python3 on PATH: fail open, and prove the guard is what stopped the warning ---
# The same payload warned in case 2, so silence here can only come from the missing python3.
nopy="$SCRATCH/nopy-bin"
mkdir -p "$nopy"
for tool in bash cat git dirname basename printf env sed grep head tr mkdir date; do
  src=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$src" ] && [ -x "$src" ] && ln -sf "$src" "$nopy/$tool"
done
if PATH="$nopy" command -v python3 >/dev/null 2>&1; then
  bad "test setup: python3 must be absent from the restricted PATH"
else
  repo=$(make_repo nopy)
  run_hook "$repo" "$nopy" "$(payload s-nopy)"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$repo/workspace" ]; then
    ok "without python3 the hook exits 0, silent, and writes nothing"
  else
    bad "without python3 the hook exits 0, silent, and writes nothing" "rc=$RC out=$OUT"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
