#!/usr/bin/env bash
# Regression tests for .claude/scripts/workspace_lock.py

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace_lock.py"
TMPROOT=$(mktemp -d)
failures=0
source "$ROOT/tests/lib/assert.sh"
trap 'rm -rf "$TMPROOT"' EXIT

python3 "$SCRIPT" acquire --root "$TMPROOT" --timeout-ms 10 --owner-pid $$ > "$TMPROOT/lease.json"
nonce=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nonce"])' "$TMPROOT/lease.json")
assert_cmd "first lock acquisition succeeds" test -d "$TMPROOT/.nase-locks/workspace-mutation.lock"

sleep 11 &
live_owner=$!
python3 - "$TMPROOT/.nase-locks/workspace-mutation.lock" <<'PY'
import os
import sys
import time

old = time.time() - 30
os.utime(sys.argv[1], (old, old))
PY
python3 - "$TMPROOT/.nase-locks/workspace-mutation.lock/owner.json" "$live_owner" <<'PY'
import json
import sys

path, pid = sys.argv[1:3]
data = json.load(open(path, encoding="utf-8"))
data["pid"] = int(pid)
open(path, "w", encoding="utf-8").write(json.dumps(data))
PY
python3 "$SCRIPT" acquire --root "$TMPROOT" --timeout-ms 10 --owner-pid $$ > "$TMPROOT/busy.out" 2> "$TMPROOT/busy.err"
busy_rc=$?
assert_cmd "live lock fails closed" test "$busy_rc" = "5"
kill "$live_owner" 2>/dev/null || true
wait "$live_owner" 2>/dev/null || true

python3 "$SCRIPT" release --root "$TMPROOT" --nonce wrong > "$TMPROOT/wrong.out" 2> "$TMPROOT/wrong.err"
wrong_rc=$?
assert_cmd "wrong owner cannot release lock" test "$wrong_rc" = "5"
assert_cmd "wrong release leaves lock" test -d "$TMPROOT/.nase-locks/workspace-mutation.lock"

python3 "$SCRIPT" release --root "$TMPROOT" --nonce "$nonce"
assert_cmd "owner release removes lock" test ! -e "$TMPROOT/.nase-locks/workspace-mutation.lock"

mkdir -p "$TMPROOT/.nase-locks/workspace-mutation.lock"
printf '{"pid":99999999,"nonce":"stale"}\n' > "$TMPROOT/.nase-locks/workspace-mutation.lock/owner.json"
python3 - "$TMPROOT/.nase-locks/workspace-mutation.lock" <<'PY'
import os
import sys
import time

old = time.time() - 30
os.utime(sys.argv[1], (old, old))
PY
python3 "$SCRIPT" acquire --root "$TMPROOT" --timeout-ms 100 --owner-pid $$ > "$TMPROOT/recovered.json"
recovered_nonce=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nonce"])' "$TMPROOT/recovered.json")
assert_cmd "dead stale lock is recovered" test "$recovered_nonce" != "stale"
python3 "$SCRIPT" release --root "$TMPROOT" --nonce "$recovered_nonce"

touch "$TMPROOT/.nase-locks/workspace-mutation.recovery.guard"
mkdir -p "$TMPROOT/.nase-locks/workspace-mutation.lock"
printf '{"pid":99999999,"nonce":"stale-after-crash"}\n' > "$TMPROOT/.nase-locks/workspace-mutation.lock/owner.json"
python3 - "$TMPROOT/.nase-locks/workspace-mutation.lock" <<'PY'
import os
import sys
import time

old = time.time() - 30
os.utime(sys.argv[1], (old, old))
PY
python3 "$SCRIPT" acquire --root "$TMPROOT" --timeout-ms 100 --owner-pid $$ > "$TMPROOT/crash-recovered.json"
crash_recovered_nonce=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nonce"])' "$TMPROOT/crash-recovered.json")
assert_cmd "orphaned recovery guard file does not block" test -n "$crash_recovered_nonce"
python3 "$SCRIPT" release --root "$TMPROOT" --nonce "$crash_recovered_nonce"

mkdir -p "$TMPROOT/.nase-locks/workspace-mutation.lock"
printf '{"pid":99999999,"nonce":"stale-race"}\n' > "$TMPROOT/.nase-locks/workspace-mutation.lock/owner.json"
python3 - "$TMPROOT/.nase-locks/workspace-mutation.lock" <<'PY'
import os
import sys
import time

old = time.time() - 30
os.utime(sys.argv[1], (old, old))
PY
for n in 1 2; do
  (
    python3 "$SCRIPT" acquire --root "$TMPROOT" --timeout-ms 50 --owner-pid $$ > "$TMPROOT/race-$n.json" 2> "$TMPROOT/race-$n.err"
    printf '%s' "$?" > "$TMPROOT/race-$n.rc"
  ) &
done
wait
race_successes=0
for n in 1 2; do
  [[ "$(cat "$TMPROOT/race-$n.rc")" = "0" ]] && race_successes=$((race_successes + 1))
done
assert_cmd "two stale recoverers produce one owner" test "$race_successes" = "1"
for n in 1 2; do
  if [[ "$(cat "$TMPROOT/race-$n.rc")" = "0" ]]; then
    race_nonce=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nonce"])' "$TMPROOT/race-$n.json")
    python3 "$SCRIPT" release --root "$TMPROOT" --nonce "$race_nonce"
  fi
done

if [[ "$failures" -eq 0 ]]; then
  printf '\nworkspace lock tests passed.\n'
  exit 0
fi

printf '\n%d workspace lock assertion(s) failed.\n' "$failures" >&2
exit "$failures"
