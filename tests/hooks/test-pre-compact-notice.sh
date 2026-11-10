#!/usr/bin/env bash
# Regression tests for .claude/hooks/pre-compact-notice.sh
#
# Run from repo root: bash tests/hooks/test-pre-compact-notice.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/pre-compact-notice.sh"

pass=0
fail=0

ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2; fail=$((fail+1)); }

# Case 1: no workspace -> still emits systemMessage, never non-zero
repo=$(mktemp -d)
git -C "$repo" init -q >/dev/null 2>&1
out=$(cd "$repo" && printf '{"trigger":"auto"}' | bash "$HOOK" 2>&1) || rc=$?
rc=${rc:-0}
if [ "$rc" -eq 0 ]; then ok "exit 0 without workspace"; else bad "exit 0 without workspace" "rc=$rc"; fi
if jq -e '.systemMessage' >/dev/null 2>&1 <<<"$out"; then ok "systemMessage present (no workspace)"; else bad "systemMessage present (no workspace)" "$out"; fi

# Case 2: workspace present, trigger surfaced
repo2=$(mktemp -d)
git -C "$repo2" init -q >/dev/null 2>&1
mkdir -p "$repo2/workspace/logs"
out2=$(cd "$repo2" && printf '{"trigger":"manual","custom_instructions":"keep foo"}' | bash "$HOOK" 2>&1) || rc2=$?
rc2=${rc2:-0}
if [ "$rc2" -eq 0 ]; then ok "exit 0 with workspace"; else bad "exit 0 with workspace" "rc=$rc2"; fi
if jq -e '.systemMessage | test("manual")' >/dev/null 2>&1 <<<"$out2"; then ok "trigger surfaced"; else bad "trigger surfaced" "$out2"; fi
if jq -e '.systemMessage | test("keep foo")' >/dev/null 2>&1 <<<"$out2"; then ok "custom instructions surfaced"; else bad "custom instructions surfaced" "$out2"; fi
if jq -e '.systemMessage | test("Re-read the effort doc|treat.*as a claim")' >/dev/null 2>&1 <<<"$out2"; then ok "re-anchor guidance present"; else bad "re-anchor guidance present" "$out2"; fi

# Case 3: empty stdin -> still succeeds
repo3=$(mktemp -d)
git -C "$repo3" init -q >/dev/null 2>&1
mkdir -p "$repo3/workspace/logs"
out3=$(cd "$repo3" && printf '' | bash "$HOOK" 2>&1) || rc3=$?
rc3=${rc3:-0}
if [ "$rc3" -eq 0 ]; then ok "exit 0 on empty stdin"; else bad "exit 0 on empty stdin" "rc=$rc3"; fi
if jq -e '.systemMessage' >/dev/null 2>&1 <<<"$out3"; then ok "systemMessage present (empty stdin)"; else bad "systemMessage present (empty stdin)" "$out3"; fi

rm -rf "$repo" "$repo2" "$repo3"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
