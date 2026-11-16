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
tracking_only: true
owner: teammate
---

Fixed by https://github.com/acme/widgets/pull/42 and follow-up #43.
EOF

cat > "$TMPDIR_TEST/done/tokens.md" <<'EOF'
Hash sha-256 and SHA-256 checks, ci-1234 id, REQ-003 spec, TLS-1234 handshake,
LLMOPS-3068 ticket, acme/widgets#99 fix, #12345678 build id, no-pr, UTF-8,
see https://github.com/acme/widgets/pull/7 for details.
EOF

out="$TMPDIR_TEST/out.txt"
PATH="$TMPDIR_TEST/bin:$PATH" bash "$SCRIPT" 2026-06 "$TMPDIR_TEST/done" > "$out"

grep -q '=== reporting (2026-06) ===' "$out"
grep -q 'status: done' "$out"
grep -q 'tracking_only: true' "$out"
grep -q 'owner: teammate' "$out"
grep -q 'github.com/acme/widgets/pull/42' "$out"
grep -q 'ABC-123' "$out"
grep -q -- '---- 2 efforts with mtime in 2026-06' "$out"

# Jira keys and #N match as whole tokens only. The ref line is the line under the block header.
refs=$(sed -n '/^=== tokens (/{n;p;}' "$out")
has_ref() { [[ " $refs " == *" $1 "* ]]; }
has_ref 'LLMOPS-3068'
has_ref '#99'
has_ref 'github.com/acme/widgets/pull/7'
for unwanted in 'MOPS-3068' 'OPS-3068' 'sha-256' 'SHA-256' 'ci-1234' 'REQ-003' 'TLS-1234' '#123456' '#12345678' 'UTF-8'; do
  if has_ref "$unwanted"; then
    printf 'FAIL  %s must not be extracted (refs: %s)\n' "$unwanted" "$refs" >&2
    exit 1
  fi
done
test "$(wc -w <<<"$refs" | tr -d ' ')" = 3

printf 'month-efforts tests passed.\n'
