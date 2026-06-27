#!/usr/bin/env bash
# Regression tests for .claude/hooks/worktree-log.sh.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/worktree-log.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

pass_msg() {
  pass=$((pass + 1))
  printf 'PASS  %s\n' "$1"
}

fail_msg() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

repo="$FIXTURE/repo"
mkdir -p "$repo/workspace/logs"
git -C "$repo" init -q

today=$(date +%Y-%m-%d)
cat > "$repo/workspace/logs/$today.md" <<EOF
# Work Log — $today

## Sessions
- 09:00 | fsd: keep existing entry

## Commits
- existing commit summary
EOF

out=$(cd "$repo" && printf '{"worktree_path":"/tmp/nase-worktree"}' | bash "$HOOK" 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
  pass_msg "worktree hook exits 0"
else
  fail_msg "worktree hook exits 0"
  printf '%s\n' "$out" >&2
fi

log=$(cat "$repo/workspace/logs/$today.md")
if printf '%s\n' "$log" | grep -Eq '^- [0-9]{2}:[0-9]{2} \| worktree: removed `/tmp/nase-worktree`$'; then
  pass_msg "worktree hook writes canonical daily-log entry"
else
  fail_msg "worktree hook writes canonical daily-log entry"
  printf '%s\n' "$log" >&2
fi

if awk '
  /^## Sessions$/ { in_sessions=1; next }
  /^## / { in_sessions=0 }
  in_sessions && /\| worktree:/ { found=1 }
  /^## Commits$/ && !found { bad=1 }
  END { exit bad || !found }
' "$repo/workspace/logs/$today.md"; then
  pass_msg "worktree entry is inserted under Sessions"
else
  fail_msg "worktree entry is inserted under Sessions"
  printf '%s\n' "$log" >&2
fi

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
