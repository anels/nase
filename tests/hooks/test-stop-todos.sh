#!/usr/bin/env bash
# Regression tests for .claude/hooks/stop-todos.sh
#
# The hook runs on Stop and surfaces unchecked todo items. What has to hold: it
# counts and lists only unchecked items, stays silent when there is nothing owed,
# and never returns non-zero - a reminder that fails the Stop event would turn a
# nicety into a session-ending error.
#
# Run from repo root:  bash tests/hooks/test-stop-todos.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/stop-todos.sh"

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

# The hook locates the workspace with `git rev-parse --show-toplevel` from its own
# cwd and takes no override, so each case needs a throwaway repo.
make_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  mkdir -p "$dir/workspace/tasks"
  printf '%s' "$dir"
}

run_in() {
  RC=0
  OUT=$(cd "$1" && bash "$HOOK" 2>/dev/null) || RC=$?
}

expect_silent() {
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then
    ok "$1"
  else
    bad "$1" "rc=$RC out=$OUT"
  fi
}

# --- pending items are listed ---------------------------------------------
repo=$(make_repo)
cat > "$repo/workspace/tasks/todo.md" <<'MD'
# Todo

- [ ] rotate the alpha token
- [x] land the retention cap
- [ ] chase the JP partitions
MD
run_in "$repo"
if [[ "$RC" -eq 0 ]] \
  && grep -q '^\[session-end\] Pending todos (2):$' <<<"$OUT" \
  && grep -q 'rotate the alpha token' <<<"$OUT" \
  && grep -q 'chase the JP partitions' <<<"$OUT" \
  && ! grep -q 'land the retention cap' <<<"$OUT"; then
  ok "unchecked items are counted and listed, checked ones are not"
else
  bad "unchecked items are counted and listed, checked ones are not" "rc=$RC out=$OUT"
fi
rm -rf "$repo"

# --- indentation ----------------------------------------------------------
# Nested items are still owed work, and the hook's pattern allows leading space.
repo=$(make_repo)
printf '  - [ ] nested but still open\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
if [[ "$RC" -eq 0 ]] && grep -q 'nested but still open' <<<"$OUT"; then
  ok "indented items are counted"
else
  bad "indented items are counted" "rc=$RC out=$OUT"
fi
rm -rf "$repo"

# --- the cap reports the real total ---------------------------------------
# Only ten lines print, so the count on the header is the only place the rest are
# visible. A capped list that also capped the count would under-report the debt.
repo=$(make_repo)
: > "$repo/workspace/tasks/todo.md"
for i in $(seq 1 14); do
  printf -- '- [ ] item %s\n' "$i" >> "$repo/workspace/tasks/todo.md"
done
run_in "$repo"
listed=$(grep -c '^\[session-end\]   ' <<<"$OUT")
if [[ "$RC" -eq 0 ]] \
  && grep -q 'Pending todos (14):' <<<"$OUT" \
  && [[ "$listed" -eq 10 ]]; then
  ok "list caps at 10 while the count reports all 14"
else
  bad "list caps at 10 while the count reports all 14" "rc=$RC listed=$listed out=$OUT"
fi
rm -rf "$repo"

# --- silent paths ---------------------------------------------------------
# `grep` exits 1 on no match, and the hook runs under `pipefail`, so these are the
# cases where a missing `|| true` would fail the Stop event.
repo=$(make_repo)
printf -- '- [x] all done\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
expect_silent "a fully checked list is silent and still exits 0"
rm -rf "$repo"

repo=$(make_repo)
: > "$repo/workspace/tasks/todo.md"
run_in "$repo"
expect_silent "an empty todo file is silent and still exits 0"
rm -rf "$repo"

repo=$(make_repo)
run_in "$repo"
expect_silent "a missing todo file is silent and still exits 0"
rm -rf "$repo"

# Outside a git checkout there is no workspace to read; the hook must not fail the
# Stop event over it.
outside=$(mktemp -d)
# The case is only meaningful if the temp dir really is outside a checkout. Assert the
# precondition instead of reading a pass off an environment that quietly broke it.
if git -C "$outside" rev-parse --show-toplevel >/dev/null 2>&1; then
  bad "outside a git checkout the hook exits 0 quietly" \
    "precondition broken: $outside is inside a git repo, so this case proves nothing"
else
  run_in "$outside"
  expect_silent "outside a git checkout the hook exits 0 quietly"
fi
rm -rf "$outside"

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
