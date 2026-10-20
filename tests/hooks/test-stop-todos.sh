#!/usr/bin/env bash
# Regression tests for .claude/hooks/stop-todos.sh
#
# The hook runs on Stop and surfaces unchecked todo items plus a missing daily-log
# note. What has to hold: it counts and lists only unchecked items, stays silent
# when there is nothing owed, never returns non-zero - a reminder that fails the
# Stop event would turn a nicety into a session-ending error - and emits the
# reminder as JSON `systemMessage`, because a successful hook's stdout is never
# shown to the user.
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
  mkdir -p "$dir/workspace/tasks" "$dir/workspace/logs"
  printf '%s' "$dir"
}

# A daily log that already carries a session note, so the reminder stays silent
# unless a case is about the log itself.
write_log_with_notes() {
  printf '# Work Log — %s\n\n## Sessions\n\n- did the thing\n' "$(date +%Y-%m-%d)" \
    > "$1/workspace/logs/$(date +%Y-%m-%d).md"
}

run_in() {
  RC=0
  OUT=$(cd "$1" && bash "$HOOK" 2>/dev/null) || RC=$?
  MSG=""
  if [ -n "$OUT" ]; then
    MSG=$(jq -r '.systemMessage // empty' <<<"$OUT" 2>/dev/null || true)
  fi
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
write_log_with_notes "$repo"
cat > "$repo/workspace/tasks/todo.md" <<'MD'
# Todo

- [ ] rotate the alpha token
- [x] land the retention cap
- [ ] chase the JP partitions
MD
run_in "$repo"
if [[ "$RC" -eq 0 ]] \
  && grep -q '^\[session-end\] Pending todos (2):$' <<<"$MSG" \
  && grep -q 'rotate the alpha token' <<<"$MSG" \
  && grep -q 'chase the JP partitions' <<<"$MSG" \
  && ! grep -q 'land the retention cap' <<<"$MSG"; then
  ok "unchecked items are counted and listed, checked ones are not"
else
  bad "unchecked items are counted and listed, checked ones are not" "rc=$RC out=$MSG"
fi
rm -rf "$repo"

# --- the reminder is JSON systemMessage ------------------------------------
# Plain stdout from a successful hook is never shown to the user, so the
# reminder only works if it arrives as JSON.
repo=$(make_repo)
write_log_with_notes "$repo"
printf -- '- [ ] one open item\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
if [[ "$RC" -eq 0 ]] \
  && jq -e '.systemMessage | type == "string" and length > 0' >/dev/null 2>&1 <<<"$OUT"; then
  ok "reminder is emitted as a JSON systemMessage"
else
  bad "reminder is emitted as a JSON systemMessage" "rc=$RC out=$OUT"
fi
rm -rf "$repo"

# --- indentation ----------------------------------------------------------
# Nested items are still owed work, and the hook's pattern allows leading space.
repo=$(make_repo)
write_log_with_notes "$repo"
printf '  - [ ] nested but still open\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
if [[ "$RC" -eq 0 ]] && grep -q 'nested but still open' <<<"$MSG"; then
  ok "indented items are counted"
else
  bad "indented items are counted" "rc=$RC out=$MSG"
fi
rm -rf "$repo"

# --- the cap reports the real total ---------------------------------------
# Only ten lines print, so the count on the header is the only place the rest are
# visible. A capped list that also capped the count would under-report the debt.
repo=$(make_repo)
write_log_with_notes "$repo"
: > "$repo/workspace/tasks/todo.md"
for i in $(seq 1 14); do
  printf -- '- [ ] item %s\n' "$i" >> "$repo/workspace/tasks/todo.md"
done
run_in "$repo"
listed=$(grep -c '^\[session-end\]   ' <<<"$MSG")
if [[ "$RC" -eq 0 ]] \
  && grep -q 'Pending todos (14):' <<<"$MSG" \
  && [[ "$listed" -eq 10 ]]; then
  ok "list caps at 10 while the count reports all 14"
else
  bad "list caps at 10 while the count reports all 14" "rc=$RC listed=$listed out=$MSG"
fi
rm -rf "$repo"

# --- a daily log with no session note is reported --------------------------
repo=$(make_repo)
printf '# Work Log — %s\n\n## Commits\n\n- abc123 something\n' "$(date +%Y-%m-%d)" \
  > "$repo/workspace/logs/$(date +%Y-%m-%d).md"
printf -- '- [ ] one open item\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
if [[ "$RC" -eq 0 ]] && grep -q 'no session notes' <<<"$MSG"; then
  ok "a log without session notes is reported"
else
  bad "a log without session notes is reported" "rc=$RC out=$MSG"
fi
rm -rf "$repo"

# --- a missing daily log is reported ---------------------------------------
repo=$(make_repo)
printf -- '- [ ] one open item\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
if [[ "$RC" -eq 0 ]] && grep -q 'no daily log for today' <<<"$MSG"; then
  ok "a missing daily log is reported"
else
  bad "a missing daily log is reported" "rc=$RC out=$MSG"
fi
rm -rf "$repo"

# --- silent paths ---------------------------------------------------------
# `grep` exits 1 on no match, and the hook runs under `pipefail`, so these are the
# cases where a missing `|| true` would fail the Stop event.
repo=$(make_repo)
write_log_with_notes "$repo"
printf -- '- [x] all done\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
expect_silent "a fully checked list is silent and still exits 0"
rm -rf "$repo"

repo=$(make_repo)
write_log_with_notes "$repo"
: > "$repo/workspace/tasks/todo.md"
run_in "$repo"
expect_silent "an empty todo file is silent and still exits 0"
rm -rf "$repo"

repo=$(make_repo)
write_log_with_notes "$repo"
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
