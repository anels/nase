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

for invalid_pid in 0 -1; do
  python3 "$SCRIPT" acquire --root "$TMPROOT/invalid-pid-$invalid_pid" --timeout-ms 10 --owner-pid "$invalid_pid" > "$TMPROOT/invalid-pid-$invalid_pid.out" 2> "$TMPROOT/invalid-pid-$invalid_pid.err"
  invalid_pid_rc=$?
  assert_cmd "owner PID $invalid_pid is rejected" test "$invalid_pid_rc" = "2"
  assert_cmd "owner PID $invalid_pid creates no lock" test ! -e "$TMPROOT/invalid-pid-$invalid_pid/.nase-locks/workspace-mutation.lock"
done

python3 - "$SCRIPT" "$TMPROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

script, root_arg = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("workspace_lock_invalid_pid", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
root = Path(root_arg) / "invalid-pid-api"
try:
    module.acquire(root, 10, owner_pid=0)
except module.LockError as exc:
    assert "owner PID" in str(exc)
else:
    raise AssertionError("expected invalid owner PID rejection")
assert not (root / ".nase-locks").exists()
PY
invalid_pid_api_rc=$?
assert_cmd "invalid owner PID API creates no lock" test "$invalid_pid_api_rc" = "0"

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

case_root="$TMPROOT/parent-swap-race"
outside="$TMPROOT/outside-parent-swap"
mkdir -p "$case_root/.nase-locks" "$outside"
printf 'outside sentinel\n' > "$outside/sentinel"
python3 - "$SCRIPT" "$case_root" "$outside" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from unittest import mock

script, root, outside = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("workspace_lock", script)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_entry_matches = module._entry_matches
locks_checks = 0


def swap_after_initial_validation(parent_fd, name, expected):
    global locks_checks
    if name == module.LOCKS_NAME:
        locks_checks += 1
        if locks_checks == 2:
            os.rename(root / module.LOCKS_NAME, root / ".nase-locks-original")
            os.symlink(outside, root / module.LOCKS_NAME, target_is_directory=True)
    return real_entry_matches(parent_fd, name, expected)


with mock.patch.object(
    module, "_entry_matches", side_effect=swap_after_initial_validation
):
    try:
        module.acquire(root, timeout_ms=20, owner_pid=os.getpid())
    except module.LockError:
        pass
    else:
        raise AssertionError("parent swap was accepted")
PY
assert_cmd "parent swap after validation fails closed" test -L "$case_root/.nase-locks"
assert_cmd "parent swap creates no outside lock" test ! -e "$outside/workspace-mutation.lock"
assert_cmd "parent swap preserves outside sentinel" grep -qx 'outside sentinel' "$outside/sentinel"
assert_cmd "parent swap creates no lock in original parent" test ! -e "$case_root/.nase-locks-original/workspace-mutation.lock"

case_root="$TMPROOT/release-lock-swap-race"
mkdir -p "$case_root"
python3 - "$SCRIPT" "$case_root" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path
from unittest import mock

script, root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("workspace_lock", script)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
lease = module.acquire(root, timeout_ms=20, owner_pid=os.getpid())
real_rename = os.rename
real_claim = module._claim_lock
swapped = False


def swap_canonical_during_claim(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
    global swapped
    if src == module.LOCK_NAME and ".release-" in dst and not swapped:
        swapped = True
        real_rename(
            module.LOCK_NAME,
            "opened-old-lock",
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
        )
        os.mkdir(module.LOCK_NAME, dir_fd=src_dir_fd)
        new_lock_fd = os.open(
            module.LOCK_NAME, module._directory_flags(), dir_fd=src_dir_fd
        )
        try:
            owner_fd = os.open(
                module.OWNER_NAME,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=new_lock_fd,
            )
            with os.fdopen(owner_fd, "w", encoding="utf-8") as handle:
                json.dump({"nonce": "b" * 32, "pid": os.getpid()}, handle)
        finally:
            os.close(new_lock_fd)
    return real_rename(
        src,
        dst,
        src_dir_fd=src_dir_fd,
        dst_dir_fd=dst_dir_fd,
    )


def claim_with_swap(locks_fd, expected, tag):
    with mock.patch.object(
        module.os, "rename", side_effect=swap_canonical_during_claim
    ):
        return real_claim(locks_fd, expected, tag)


with mock.patch.object(module, "_claim_lock", side_effect=claim_with_swap):
    try:
        module.release(lease)
    except module.LockError:
        pass
    else:
        raise AssertionError("swapped release claim was accepted")
PY
release_claim=$(find "$case_root/.nase-locks" -maxdepth 1 -type d -name 'workspace-mutation.lock.release-*' -print -quit)
assert_cmd "release swap preserves claimed new live lock" test -n "$release_claim"
assert_cmd "release swap preserves new owner" grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$release_claim/owner.json"
assert_cmd "release swap preserves opened old lock" test -f "$case_root/.nase-locks/opened-old-lock/owner.json"
assert_cmd "release swap does not report success by deleting canonical" test ! -e "$case_root/.nase-locks/workspace-mutation.lock"

case_root="$TMPROOT/guard-swap-race"
mkdir -p "$case_root/.nase-locks/workspace-mutation.lock"
printf '{"pid":99999999,"nonce":"stale"}\n' > "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
touch -t 202001010000 "$case_root/.nase-locks/workspace-mutation.lock"
python3 - "$SCRIPT" "$case_root" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from unittest import mock

script, root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("workspace_lock", script)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_flock = module.fcntl.flock
swapped = False


def swap_guard_after_flock(descriptor, operation):
    global swapped
    result = real_flock(descriptor, operation)
    if operation & module.fcntl.LOCK_EX and not swapped:
        swapped = True
        locks = root / module.LOCKS_NAME
        os.rename(locks / module.GUARD_NAME, locks / "opened-old-guard")
        (locks / module.GUARD_NAME).write_text("new guard\n", encoding="utf-8")
    return result


with mock.patch.object(module.fcntl, "flock", side_effect=swap_guard_after_flock):
    try:
        module.acquire(root, timeout_ms=20, owner_pid=os.getpid())
    except module.LockError:
        pass
    else:
        raise AssertionError("swapped recovery guard was accepted")
PY
assert_cmd "guard swap preserves new guard" grep -qx 'new guard' "$case_root/.nase-locks/workspace-mutation.recovery.guard"
assert_cmd "guard swap preserves opened guard" test -f "$case_root/.nase-locks/opened-old-guard"
assert_cmd "guard swap leaves stale lock untouched" grep -q '"nonce":"stale"' "$case_root/.nase-locks/workspace-mutation.lock/owner.json"

case_root="$TMPROOT/stale-claim-swap-race"
mkdir -p "$case_root/.nase-locks/workspace-mutation.lock"
printf '{"pid":99999999,"nonce":"stale"}\n' > "$case_root/.nase-locks/workspace-mutation.lock/owner.json"
touch -t 202001010000 "$case_root/.nase-locks/workspace-mutation.lock"
python3 - "$SCRIPT" "$case_root" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path
from unittest import mock

script, root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("workspace_lock", script)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_claim = module._claim_lock
real_rename = os.rename
swapped = False


def swap_stale_during_rename(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
    global swapped
    if src == module.LOCK_NAME and ".stale-" in dst and not swapped:
        swapped = True
        real_rename(
            module.LOCK_NAME,
            "opened-old-lock",
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
        )
        os.mkdir(module.LOCK_NAME, dir_fd=src_dir_fd)
        new_lock_fd = os.open(
            module.LOCK_NAME, module._directory_flags(), dir_fd=src_dir_fd
        )
        try:
            owner_fd = os.open(
                module.OWNER_NAME,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=new_lock_fd,
            )
            with os.fdopen(owner_fd, "w", encoding="utf-8") as handle:
                json.dump({"nonce": "c" * 32, "pid": os.getpid()}, handle)
        finally:
            os.close(new_lock_fd)
    return real_rename(
        src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd
    )


def claim_with_stale_swap(locks_fd, expected, tag):
    if tag != "stale":
        return real_claim(locks_fd, expected, tag)
    with mock.patch.object(
        module.os, "rename", side_effect=swap_stale_during_rename
    ):
        return real_claim(locks_fd, expected, tag)


with mock.patch.object(module, "_claim_lock", side_effect=claim_with_stale_swap):
    try:
        module.acquire(root, timeout_ms=20, owner_pid=os.getpid())
    except module.LockError:
        pass
    else:
        raise AssertionError("swapped stale claim returned a lease")
PY
stale_claim=$(find "$case_root/.nase-locks" -maxdepth 1 -type d -name 'workspace-mutation.lock.stale-*' -print -quit)
assert_cmd "stale swap preserves claimed replacement" test -n "$stale_claim"
assert_cmd "stale swap preserves replacement owner" grep -q 'cccccccccccccccccccccccccccccccc' "$stale_claim/owner.json"
assert_cmd "stale swap preserves opened old lock" test -f "$case_root/.nase-locks/opened-old-lock/owner.json"
assert_cmd "stale swap returns no canonical lease" test ! -e "$case_root/.nase-locks/workspace-mutation.lock"

case_root="$TMPROOT/acquire-cleanup-swap-race"
mkdir -p "$case_root"
python3 - "$SCRIPT" "$case_root" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path
from unittest import mock

script, root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("workspace_lock", script)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_claim = module._claim_lock
real_rename = os.rename
swapped = False


def swap_cleanup_during_rename(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
    global swapped
    if src == module.LOCK_NAME and ".acquire-failed-" in dst and not swapped:
        swapped = True
        real_rename(
            module.LOCK_NAME,
            "opened-old-lock",
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
        )
        os.mkdir(module.LOCK_NAME, dir_fd=src_dir_fd)
        new_lock_fd = os.open(
            module.LOCK_NAME, module._directory_flags(), dir_fd=src_dir_fd
        )
        try:
            owner_fd = os.open(
                module.OWNER_NAME,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=new_lock_fd,
            )
            with os.fdopen(owner_fd, "w", encoding="utf-8") as handle:
                json.dump({"nonce": "d" * 32, "pid": os.getpid()}, handle)
        finally:
            os.close(new_lock_fd)
    return real_rename(
        src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd
    )


def claim_with_cleanup_swap(locks_fd, expected, tag):
    if tag != "acquire-failed":
        return real_claim(locks_fd, expected, tag)
    with mock.patch.object(
        module.os, "rename", side_effect=swap_cleanup_during_rename
    ):
        return real_claim(locks_fd, expected, tag)


with (
    mock.patch.object(module, "_read_owner_at", return_value=None),
    mock.patch.object(module, "_claim_lock", side_effect=claim_with_cleanup_swap),
):
    try:
        module.acquire(root, timeout_ms=20, owner_pid=os.getpid())
    except module.LockError:
        pass
    else:
        raise AssertionError("failed acquisition returned a lease")
PY
cleanup_claim=$(find "$case_root/.nase-locks" -maxdepth 1 -type d -name 'workspace-mutation.lock.acquire-failed-*' -print -quit)
assert_cmd "failed acquire preserves claimed replacement" test -n "$cleanup_claim"
assert_cmd "failed acquire preserves replacement owner" grep -q 'dddddddddddddddddddddddddddddddd' "$cleanup_claim/owner.json"
assert_cmd "failed acquire preserves opened old lock" test -f "$case_root/.nase-locks/opened-old-lock/owner.json"
assert_cmd "failed acquire returns no canonical lease" test ! -e "$case_root/.nase-locks/workspace-mutation.lock"

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
        SimpleNamespace(hex="a" * 32),
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

python3 - "$SCRIPT" <<'PY'
import builtins
import importlib.util
import sys
import tempfile
from pathlib import Path
from unittest import mock

script = Path(sys.argv[1])
real_import = builtins.__import__

def import_without_fcntl(name, *args, **kwargs):
    if name == "fcntl":
        raise ImportError("simulated non-Unix platform")
    return real_import(name, *args, **kwargs)

with mock.patch("builtins.__import__", side_effect=import_without_fcntl):
    spec = importlib.util.spec_from_file_location("workspace_lock_no_fcntl", script)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

assert module.fcntl is None
with tempfile.TemporaryDirectory() as root:
    try:
        module.acquire(Path(root), 0)
    except module.LockError as exc:
        assert "file locking support" in str(exc)
    else:
        raise AssertionError("expected unsupported-platform failure")
PY
platform_rc=$?
assert_cmd "missing fcntl fails closed without import crash" test "$platform_rc" = "0"

if [[ "$failures" -eq 0 ]]; then
  printf '\nworkspace lock tests passed.\n'
  exit 0
fi

printf '\n%d workspace lock assertion(s) failed.\n' "$failures" >&2
exit "$failures"
