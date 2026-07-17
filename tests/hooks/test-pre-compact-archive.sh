#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

repo="$FIXTURE/repo"
mkdir -p "$repo/.claude/hooks" "$repo/.claude/scripts" \
  "$repo/workspace/tasks" "$repo/workspace/efforts/done" "$repo/workspace/efforts/archive/$(date +%Y)" \
  "$repo/workspace/tmp"
git -C "$repo" init -q
cp "$ROOT/.claude/hooks/pre-compact-archive.sh" "$repo/.claude/hooks/"
cp "$ROOT/.claude/scripts/workspace-archive.py" "$ROOT/.claude/scripts/workspace_lock.py" \
  "$ROOT/.claude/scripts/workspace-write-guard.py" "$repo/.claude/scripts/"

python3 - "$repo/workspace/tasks/lessons.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(
    "# Lessons\n\n## debugging -- 2020-01-01 -- old\n\n" + "x" * 82000
    + "\n\n> Promoted → kb.md\n",
    encoding="utf-8",
)
PY

year=$(date +%Y)
printf 'source content\n' > "$repo/workspace/efforts/done/collision.md"
printf 'destination content\n' > "$repo/workspace/efforts/archive/$year/collision.md"
touch -t 202001010000 "$repo/workspace/efforts/done/collision.md"

printf 'move content\n' > "$repo/workspace/efforts/done/move.md"
touch -t 202001010000 "$repo/workspace/efforts/done/move.md"

out=$(cd "$repo" && bash .claude/hooks/pre-compact-archive.sh 2>&1)

test ! -e "$repo/workspace/efforts/done/move.md"
grep -qx 'move content' "$repo/workspace/efforts/archive/$year/move.md"
grep -qx 'source content' "$repo/workspace/efforts/done/collision.md"
grep -qx 'destination content' "$repo/workspace/efforts/archive/$year/collision.md"
grep -q 'retained workspace/efforts/done/collision.md' <<<"$out"
grep -q 'nase-archive:' "$repo/workspace/tasks/lessons-archive.md"
test "$(wc -c < "$repo/workspace/tasks/lessons.md")" -lt 81920

printf 'pre-compact archive hook tests passed.\n'
