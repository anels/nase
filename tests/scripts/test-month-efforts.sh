#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

SCRIPT="$ROOT/.claude/scripts/month-efforts.sh"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/done"

cat > "$TMPDIR_TEST/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-f" ]]; then
  exit 1
fi
if [[ "$1" == "-c" && "$2" == "%Y" ]]; then
  printf '1781481600\n'
  exit 0
fi
exit 2
SH
chmod +x "$TMPDIR_TEST/bin/stat"

cat > "$TMPDIR_TEST/bin/date" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-d" && "$2" == "@1781481600" && "$3" == "+%Y-%m" ]]; then
  printf '2026-06\n'
  exit 0
fi
exit 2
SH
chmod +x "$TMPDIR_TEST/bin/date"

cat > "$TMPDIR_TEST/done/reporting.md" <<'EOF'
---
status: done
repo: acme/widgets
jira: ABC-123
---

Fixed by https://github.com/acme/widgets/pull/42 and follow-up #43.
EOF

out="$TMPDIR_TEST/out.txt"
PATH="$TMPDIR_TEST/bin:$PATH" bash "$SCRIPT" 2026-06 "$TMPDIR_TEST/done" > "$out"

grep -q '=== reporting (2026-06) ===' "$out"
grep -q 'status: done' "$out"
grep -q 'github.com/acme/widgets/pull/42' "$out"
grep -q 'ABC-123' "$out"
grep -q -- '---- 1 efforts with mtime in 2026-06' "$out"

printf 'month-efforts tests passed.\n'
