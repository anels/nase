#!/usr/bin/env bash
# Regression tests for .claude/scripts/kb-size-snapshot.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/kb-size-snapshot.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

check() {
  local desc="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  %s\n' "$desc" "$detail" >&2
  fi
}

mkdir -p "$FIXTURE/workspace/kb/projects"
printf 'a\n\nb\nc\n' > "$FIXTURE/workspace/kb/projects/one.md"

out=$(python3 "$SCRIPT" --root "$FIXTURE" --max-kb-lines 2)
case "$out" in *"3 non-blank lines in 1 file; 1 over the 2 budget"*) check "first run counts non-blank lines and budget" 1 ;; *) check "first run counts non-blank lines and budget" 0 "$out" ;; esac
check "first run writes the ledger" "$([ -s "$FIXTURE/workspace/stats/kb-size.jsonl" ] && echo 1 || echo 0)"

printf 'd\ne\n' >> "$FIXTURE/workspace/kb/projects/one.md"
out=$(python3 "$SCRIPT" --root "$FIXTURE" --no-write)
case "$out" in *"net +2 lines"*"grew +2"*"one.md"*) check "second run reports growth by file" 1 ;; *) check "second run reports growth by file" 0 "$out" ;; esac
check "--no-write leaves the ledger at one line" "$([ "$(wc -l < "$FIXTURE/workspace/stats/kb-size.jsonl")" -eq 1 ] && echo 1 || echo 0)"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"
[ "$fail" -eq 0 ]
