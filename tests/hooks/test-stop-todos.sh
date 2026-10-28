#!/usr/bin/env bash
# Regression tests for .claude/hooks/stop-todos.sh
#
# The hook runs on Stop and reminds the user when today's daily log has no session
# note. What has to hold: it stays silent when nothing is owed, never returns
# non-zero - a reminder that fails the Stop event would turn a nicety into a
# session-ending error - emits the reminder as JSON `systemMessage` because a
# successful hook's stdout is never shown to the user, and never lists todo items.
# Stop fires every turn, so a todo list there repeats after each reply.
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

# The hook locates the workspace from the NASE_ROOT that hook-dispatch.sh exports
# and falls back to `git rev-parse --show-toplevel` from its own cwd, so each case
# needs a throwaway repo (or an explicit NASE_ROOT).
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

# --- open todo items never reach the reminder ------------------------------
repo=$(make_repo)
write_log_with_notes "$repo"
cat > "$repo/workspace/tasks/todo.md" <<'MD'
# Todo

- [ ] rotate the alpha token
  - [ ] nested but still open
MD
run_in "$repo"
expect_silent "open todo items with a noted log are silent"
rm -rf "$repo"

repo=$(make_repo)
printf '# Work Log — %s\n\n## Commits\n\n- abc123 something\n' "$(date +%Y-%m-%d)" \
  > "$repo/workspace/logs/$(date +%Y-%m-%d).md"
printf -- '- [ ] rotate the alpha token\n' > "$repo/workspace/tasks/todo.md"
run_in "$repo"
if [[ "$RC" -eq 0 ]] \
  && grep -q 'no session notes' <<<"$MSG" \
  && ! grep -qi 'rotate the alpha token\|pending todos' <<<"$OUT"; then
  ok "a reminder that fires does not carry the todo list"
else
  bad "a reminder that fires does not carry the todo list" "rc=$RC out=$OUT"
fi
rm -rf "$repo"

# --- the reminder is JSON systemMessage ------------------------------------
# Plain stdout from a successful hook is never shown to the user, so the
# reminder only works if it arrives as JSON.
repo=$(make_repo)
run_in "$repo"
if [[ "$RC" -eq 0 ]] \
  && jq -e '.systemMessage | type == "string" and length > 0' >/dev/null 2>&1 <<<"$OUT"; then
  ok "reminder is emitted as a JSON systemMessage"
else
  bad "reminder is emitted as a JSON systemMessage" "rc=$RC out=$OUT"
fi
rm -rf "$repo"

# --- a daily log with no session note is reported --------------------------
repo=$(make_repo)
printf '# Work Log — %s\n\n## Commits\n\n- abc123 something\n' "$(date +%Y-%m-%d)" \
  > "$repo/workspace/logs/$(date +%Y-%m-%d).md"
run_in "$repo"
if [[ "$RC" -eq 0 ]] && grep -q 'no session notes' <<<"$MSG"; then
  ok "a log without session notes is reported"
else
  bad "a log without session notes is reported" "rc=$RC out=$MSG"
fi
rm -rf "$repo"

# --- a missing daily log is reported ---------------------------------------
repo=$(make_repo)
run_in "$repo"
if [[ "$RC" -eq 0 ]] && grep -q 'no daily log for today' <<<"$MSG"; then
  ok "a missing daily log is reported"
else
  bad "a missing daily log is reported" "rc=$RC out=$MSG"
fi
rm -rf "$repo"

# --- silent paths ---------------------------------------------------------
repo=$(make_repo)
write_log_with_notes "$repo"
run_in "$repo"
expect_silent "a log with a session note is silent and still exits 0"
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

# NASE_ROOT exported by hook-dispatch.sh wins over the cwd's git toplevel.
# The override repo has no log, the cwd repo has notes: only the override can
# produce the "no daily log" reminder.
repo=$(make_repo)
other=$(make_repo)
write_log_with_notes "$other"
RC=0
OUT=$(cd "$other" && NASE_ROOT="$repo" bash "$HOOK" 2>/dev/null) || RC=$?
MSG=$(jq -r '.systemMessage // empty' <<<"$OUT" 2>/dev/null || true)
if [[ "$RC" -eq 0 ]] && grep -q 'no daily log for today' <<<"$MSG"; then
  ok "NASE_ROOT override beats the cwd's git repo"
else
  bad "NASE_ROOT override beats the cwd's git repo" "rc=$RC out=$OUT"
fi
rm -rf "$other"

outside=$(mktemp -d)
RC=0
OUT=$(cd "$outside" && NASE_ROOT="$repo" bash "$HOOK" 2>/dev/null) || RC=$?
MSG=$(jq -r '.systemMessage // empty' <<<"$OUT" 2>/dev/null || true)
if [[ "$RC" -eq 0 ]] && grep -q 'no daily log for today' <<<"$MSG"; then
  ok "NASE_ROOT override works from a non-git cwd"
else
  bad "NASE_ROOT override works from a non-git cwd" "rc=$RC out=$OUT"
fi
rm -rf "$outside" "$repo"

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
