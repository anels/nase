#!/usr/bin/env bash
# Regression tests for .claude/scripts/commit-log-append.py.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/commit-log-append.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"
failures=0

python3 -c 'import fcntl' 2>/dev/null || export NASE_WEAK_LOCK=1

day=2026-01-02
log="$FIXTURE/workspace/logs/$day.md"
fp="$FIXTURE/workspace/logs/.last-commit-fingerprint"

pids=()
for i in $(seq 1 20); do
  printf 'fp%s\n**[repo%s]**\nabc%04d commit number %s\n' "$i" "$i" "$i" "$i" |
    python3 "$SCRIPT" --root "$FIXTURE" --date "$day" >/dev/null &
  pids+=("$!")
done
rc=0
for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
assert_cmd "20 parallel appends all exit 0" test "$rc" = 0
assert_cmd "20 Commits blocks survive" test "$(grep -c '^## Commits$' "$log")" = 20
assert_cmd "every block body is intact" test "$(grep -c '^abc[0-9]* commit number [0-9]*$' "$log")" = 20
assert_cmd "no block is split from its header" test "$(grep -c '^\*\*\[repo[0-9]*\]\*\*$' "$log")" = 20
assert_cmd "fingerprint file holds one well-formed stamp" grep -Eqx "$day:fp[0-9]+" "$fp"

before=$(wc -c <"$log")
out=$({ sed "s/^$day://" "$fp"; printf 'x\n'; } | python3 "$SCRIPT" --root "$FIXTURE" --date "$day")
assert_cmd "same fingerprint reports unchanged" test "$out" = unchanged
assert_cmd "same fingerprint appends nothing" test "$(wc -c <"$log")" = "$before"

printf 'a\n**[r]**\nabc1234 one\n' | python3 "$SCRIPT" --root "$FIXTURE" --date 2026-01-03 >/dev/null
assert_cmd "block shape matches the legacy printf" cmp -s "$FIXTURE/workspace/logs/2026-01-03.md" <(printf '\n## Commits\n**[r]**\nabc1234 one\n\n')

# 2000 commit hashes are longer than a Windows command line may be.
long_fp=$(seq 1 2000 | xargs printf '%040d,')
out=$(printf '%s\nx\n' "$long_fp" | python3 "$SCRIPT" --root "$FIXTURE" --date 2026-01-05)
assert_cmd "a long fingerprint is appended" test "$out" = appended
assert_cmd "a long fingerprint is stored whole" test "$(cat "$fp")" = "2026-01-05:$long_fp"

# Short appends rarely interleave by chance, so hold the shared lock to prove the script waits for it.
python3 - "$ROOT/.claude/scripts" "$SCRIPT" "$FIXTURE" <<'PY'
import pathlib
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
from nase_fs import lock_exclusive

script, root = sys.argv[2], pathlib.Path(sys.argv[3])
log = root / "workspace" / "logs" / "2026-01-04.md"
with open(log.parent / ".daily-log.lock", "a") as lock:
    lock_exclusive(lock)
    child = subprocess.Popen(
        [sys.executable, script, "--root", str(root), "--date", "2026-01-04"],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
    )
    child.stdin.write(b"held\nheld block\n")
    child.stdin.close()
    try:
        child.wait(timeout=3)
        sys.exit("script finished while the daily-log lock was held")
    except subprocess.TimeoutExpired:
        if log.exists():
            sys.exit("script wrote while the daily-log lock was held")
if child.wait(timeout=60) != 0 or b"held block" not in log.read_bytes():
    sys.exit("script did not append after the lock was released")
PY
assert_cmd "append waits for the shared daily-log lock" test "$?" = 0

exit "$failures"
