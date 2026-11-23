#!/usr/bin/env bash
# Regression tests for .claude/scripts/content-identity.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/content-identity.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

assert_cmd() {
  local desc="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$desc" >&2
  fi
}

exit_code() {
  "$@" >/dev/null 2>&1
  echo $?
}

run_expect() {
  local want="$1"
  shift
  [ "$(exit_code "$@")" = "$want" ]
}

repo="$FIXTURE/repo"
mkdir -p "$repo"
git_in() { git -C "$repo" "$@"; }

git_in init -q
git_in checkout -q -b main 2>/dev/null || true
git_in config user.email test@example.com
git_in config user.name Test

printf 'one\ntwo\nthree\n' > "$repo/a.txt"
printf 'x\n' > "$repo/b.txt"
git_in add a.txt b.txt
git_in commit -q -m base
base=$(git_in rev-parse HEAD)

git_in checkout -q -b feature
printf 'one\ntwo\nthree\nfour\n' > "$repo/a.txt"
git_in commit -q -am 'feature 1'
printf 'one\ntwo\nthree\nfour\nfive\n' > "$repo/a.txt"
git_in commit -q -am 'feature 2'
verified=$(git_in rev-parse HEAD)

# Squash on the same base keeps the tree byte for byte.
git_in checkout -q -b squashed "$base"
git_in merge --squash -q feature
git_in commit -q -m squashed
squashed=$(git_in rev-parse HEAD)

assert_cmd "same-tree: faithful squash is same" \
  run_expect 0 python3 "$SCRIPT" same-tree --repo "$repo" --expect "$verified" --actual "$squashed"

verified_tree=$(git_in rev-parse "$verified^{tree}")
assert_cmd "same-tree: a bare tree OID is accepted as expect" \
  run_expect 0 python3 "$SCRIPT" same-tree --repo "$repo" --expect "$verified_tree" --actual "$squashed"

# A squash that picks up one extra edit must be refused.
git_in checkout -q -b tampered "$base"
git_in merge --squash -q feature
printf 'extra\n' >> "$repo/b.txt"
git_in commit -q -am tampered
tampered=$(git_in rev-parse HEAD)

assert_cmd "same-tree: extra edit in the squash differs" \
  run_expect 1 python3 "$SCRIPT" same-tree --repo "$repo" --expect "$verified" --actual "$tampered"

# Whitespace-only drift is invisible to patch-id but visible to the tree.
git_in checkout -q -b spacey "$base"
git_in merge --squash -q feature
sed 's/four/four /' "$repo/a.txt" > "$repo/a.tmp" && mv "$repo/a.tmp" "$repo/a.txt"
git_in commit -q -am spacey
spacey=$(git_in rev-parse HEAD)

assert_cmd "same-tree: whitespace-only drift differs" \
  run_expect 1 python3 "$SCRIPT" same-tree --repo "$repo" --expect "$verified" --actual "$spacey"
assert_cmd "same-patch: whitespace-only drift is not seen (documented blind spot)" \
  run_expect 0 python3 "$SCRIPT" same-patch --repo "$repo" \
    --old-base "$base" --old-head "$verified" --new-base "$base" --new-head "$spacey"

# Clean rebase onto a moved base keeps the branch's own diff.
git_in checkout -q main
printf 'unrelated\n' > "$repo/c.txt"
git_in add c.txt
git_in commit -q -m 'main moves'
moved=$(git_in rev-parse HEAD)
git_in checkout -q -b rebased feature
git_in rebase -q main
rebased=$(git_in rev-parse HEAD)

assert_cmd "same-patch: clean rebase onto a moved base is same" \
  run_expect 0 python3 "$SCRIPT" same-patch --repo "$repo" \
    --old-base "$base" --old-head "$verified" --new-base "$moved" --new-head "$rebased"
assert_cmd "same-tree: the same rebase differs, because the base moved" \
  run_expect 1 python3 "$SCRIPT" same-tree --repo "$repo" --expect "$verified" --actual "$rebased"

# A rebase whose resolution changes the branch's own diff is caught.
git_in checkout -q -b resolved rebased
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "$repo/a.txt"
git_in commit -q -am 'resolution changed code'
resolved=$(git_in rev-parse HEAD)

assert_cmd "same-patch: changed own diff after rebase differs" \
  run_expect 1 python3 "$SCRIPT" same-patch --repo "$repo" \
    --old-base "$base" --old-head "$verified" --new-base "$moved" --new-head "$resolved"

# Two diffs that differ only in invalid UTF-8 bytes must not share a patch-id.
git_in checkout -q -b bytes-a "$base"
printf 'caf\351\n' > "$repo/latin.txt"
git_in add latin.txt
git_in commit -q -m 'latin-1 e-acute'
bytes_a=$(git_in rev-parse HEAD)
git_in checkout -q -b bytes-b "$base"
printf 'caf\350\n' > "$repo/latin.txt"
git_in add latin.txt
git_in commit -q -m 'latin-1 e-grave'
bytes_b=$(git_in rev-parse HEAD)

assert_cmd "same-patch: diffs differing only in invalid UTF-8 bytes differ" \
  run_expect 1 python3 "$SCRIPT" same-patch --repo "$repo" \
    --old-base "$base" --old-head "$bytes_a" --new-base "$base" --new-head "$bytes_b"

# Errors are not verdicts.
assert_cmd "same-tree: unknown revision exits 2" \
  run_expect 2 python3 "$SCRIPT" same-tree --repo "$repo" --expect nope --actual "$squashed"
assert_cmd "same-patch: empty diff exits 2" \
  run_expect 2 python3 "$SCRIPT" same-patch --repo "$repo" \
    --old-base "$base" --old-head "$base" --new-base "$base" --new-head "$base"
assert_cmd "no subcommand exits 2" \
  run_expect 2 python3 "$SCRIPT"

verdict=$(python3 "$SCRIPT" same-tree --repo "$repo" --expect "$verified" --actual "$tampered" 2>/dev/null || true)
assert_cmd "differs verdict is one JSON line with both values" \
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["verdict"] == "differs" and d["kind"] == "tree" and d["expect"] != d["actual"], d
' "$verdict"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
