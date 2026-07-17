#!/usr/bin/env bash
# Regression tests for .claude/scripts/workspace_lock.py

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace_lock.py"
TMPROOT=$(mktemp -d)
failures=0
source "$ROOT/tests/lib/assert.sh"
trap 'rm -rf "$TMPROOT"' EXIT

run_acquire_bounded() {
  python3 - "$SCRIPT" "$1" "$2" "$3" "$$" <<'PY'
import subprocess
import sys
from pathlib import Path

script, root, stdout_path, stderr_path, owner_pid = sys.argv[1:]
try:
    result = subprocess.run(
        [
            sys.executable,
            script,
            "acquire",
            "--root",
            root,
            "--timeout-ms",
            "20",
            "--owner-pid",
            owner_pid,
        ],
        capture_output=True,
        text=True,
        timeout=3,
    )
except subprocess.TimeoutExpired:
    Path(stderr_path).write_text("lock command timed out\n", encoding="utf-8")
    raise SystemExit(124)
Path(stdout_path).write_text(result.stdout, encoding="utf-8")
Path(stderr_path).write_text(result.stderr, encoding="utf-8")
raise SystemExit(result.returncode)
PY
}

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

case_root="$TMPROOT/symlink-lock-parent"
outside="$TMPROOT/outside-lock-parent"
mkdir -p "$case_root" "$outside"
printf 'outside sentinel\n' > "$outside/sentinel"
ln -s "$outside" "$case_root/.nase-locks"
run_acquire_bounded "$case_root" "$case_root/out" "$case_root/err"
parent_symlink_rc=$?
assert_cmd "symlinked lock parent is rejected" test "$parent_symlink_rc" = "5"
assert_cmd "symlinked lock parent preserves outside sentinel" grep -qx 'outside sentinel' "$outside/sentinel"
assert_cmd "symlinked lock parent creates nothing outside" test "$(find "$outside" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "1"

case_root="$TMPROOT/symlink-lock-dir"
outside="$TMPROOT/outside-lock-dir"
mkdir -p "$case_root/.nase-locks" "$outside"
printf 'outside sentinel\n' > "$outside/sentinel"
ln -s "$outside" "$case_root/.nase-locks/workspace-mutation.lock"
run_acquire_bounded "$case_root" "$case_root/out" "$case_root/err"
lock_symlink_rc=$?
assert_cmd "symlinked lock directory is rejected" test "$lock_symlink_rc" = "5"
assert_cmd "symlinked lock directory preserves outside sentinel" grep -qx 'outside sentinel' "$outside/sentinel"
assert_cmd "symlinked lock directory creates nothing outside" test "$(find "$outside" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "1"

case_root="$TMPROOT/symlink-owner"
outside_file="$TMPROOT/outside-owner.json"
mkdir -p "$case_root/.nase-locks/workspace-mutation.lock"
printf 'outside owner\n' > "$outside_file"
ln -s "$outside_file" "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
touch -t 202001010000 "$case_root/.nase-locks/workspace-mutation.lock"
run_acquire_bounded "$case_root" "$case_root/out" "$case_root/err"
owner_symlink_rc=$?
assert_cmd "symlinked owner is rejected" test "$owner_symlink_rc" = "5"
assert_cmd "symlinked owner preserves outside file" grep -qx 'outside owner' "$outside_file"
assert_cmd "symlinked owner leaves lock in place" test -L "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
assert_cmd "symlinked owner creates no stale path" test -z "$(find "$case_root/.nase-locks" -maxdepth 1 -name 'workspace-mutation.lock.stale-*' -print -quit)"

case_root="$TMPROOT/fifo-owner"
mkdir -p "$case_root/.nase-locks/workspace-mutation.lock"
mkfifo "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
touch -t 202001010000 "$case_root/.nase-locks/workspace-mutation.lock"
run_acquire_bounded "$case_root" "$case_root/out" "$case_root/err"
owner_fifo_rc=$?
assert_cmd "FIFO owner is rejected without blocking" test "$owner_fifo_rc" = "5"
assert_cmd "FIFO owner remains untouched" test -p "$case_root/.nase-locks/workspace-mutation.lock/owner.json"

case_root="$TMPROOT/fifo-lock"
mkdir -p "$case_root/.nase-locks"
mkfifo "$case_root/.nase-locks/workspace-mutation.lock"
run_acquire_bounded "$case_root" "$case_root/out" "$case_root/err"
lock_fifo_rc=$?
assert_cmd "FIFO lock path is rejected without blocking" test "$lock_fifo_rc" = "5"
assert_cmd "FIFO lock path remains untouched" test -p "$case_root/.nase-locks/workspace-mutation.lock"

case_root="$TMPROOT/symlink-recovery-guard"
outside_file="$TMPROOT/outside-recovery-guard"
mkdir -p "$case_root/.nase-locks/workspace-mutation.lock"
printf '{"pid":99999999,"nonce":"stale"}\n' > "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
printf 'outside guard\n' > "$outside_file"
ln -s "$outside_file" "$case_root/.nase-locks/workspace-mutation.recovery.guard"
touch -t 202001010000 "$case_root/.nase-locks/workspace-mutation.lock"
run_acquire_bounded "$case_root" "$case_root/out" "$case_root/err"
guard_symlink_rc=$?
assert_cmd "symlinked recovery guard is rejected" test "$guard_symlink_rc" = "5"
assert_cmd "symlinked recovery guard preserves outside file" grep -qx 'outside guard' "$outside_file"
assert_cmd "symlinked recovery guard leaves stale lock" test -d "$case_root/.nase-locks/workspace-mutation.lock"

case_root="$TMPROOT/fifo-recovery-guard"
mkdir -p "$case_root/.nase-locks/workspace-mutation.lock"
printf '{"pid":99999999,"nonce":"stale"}\n' > "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
mkfifo "$case_root/.nase-locks/workspace-mutation.recovery.guard"
touch -t 202001010000 "$case_root/.nase-locks/workspace-mutation.lock"
run_acquire_bounded "$case_root" "$case_root/out" "$case_root/err"
guard_fifo_rc=$?
assert_cmd "FIFO recovery guard is rejected without blocking" test "$guard_fifo_rc" = "5"
assert_cmd "FIFO recovery guard remains untouched" test -p "$case_root/.nase-locks/workspace-mutation.recovery.guard"
assert_cmd "FIFO recovery guard leaves stale lock" test -d "$case_root/.nase-locks/workspace-mutation.lock"

case_root="$TMPROOT/symlink-stale-collision"
outside="$TMPROOT/outside-stale-collision"
mkdir -p "$case_root/.nase-locks/workspace-mutation.lock" "$outside"
printf '{"pid":99999999,"nonce":"stale"}\n' > "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
printf 'outside sentinel\n' > "$outside/sentinel"
ln -s "$outside" "$case_root/.nase-locks/workspace-mutation.lock.stale-collision"
touch -t 202001010000 "$case_root/.nase-locks/workspace-mutation.lock"
python3 - "$SCRIPT" "$case_root" <<'PY'
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

script, root = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("workspace_lock", script)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
identifiers = iter(
    [
        SimpleNamespace(hex="new-owner"),
        SimpleNamespace(hex="collision"),
        SimpleNamespace(hex="safe-stale"),
    ]
)
with mock.patch.object(module.uuid, "uuid4", side_effect=lambda: next(identifiers)):
    lease = module.acquire(root, timeout_ms=100, owner_pid=99999998)
module.release(lease)
PY
assert_cmd "symlinked stale collision remains lexical" test -L "$case_root/.nase-locks/workspace-mutation.lock.stale-collision"
assert_cmd "symlinked stale collision preserves outside sentinel" grep -qx 'outside sentinel' "$outside/sentinel"
assert_cmd "symlinked stale collision creates nothing outside" test "$(find "$outside" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "1"

if [[ "$failures" -eq 0 ]]; then
  printf '\nworkspace lock tests passed.\n'
  exit 0
fi

printf '\n%d workspace lock assertion(s) failed.\n' "$failures" >&2
exit "$failures"
