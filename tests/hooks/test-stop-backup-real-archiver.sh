#!/usr/bin/env bash
# stop-backup.sh against the real archivers on this host, with no stubs.
#
# test-stop-backup-safety.sh fakes `zip` and `7z` with Python's zipfile, which records a
# Unix mode on every host, so it cannot see how a real archiver describes its members.
# This file publishes, validates, restores, and tampers with real archives.
#
# Run from repo root:  bash tests/hooks/test-stop-backup-real-archiver.sh

set -uo pipefail
# The hook prefers NASE_ROOT to the repo it runs in. Never inherit a real workspace.
unset NASE_ROOT

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source "$ROOT/tests/lib/assert.sh"
source "$ROOT/tests/lib/stage-scripts.sh"
SCAN="$ROOT/tests/check-local-sensitive-artifacts.sh"
failures=0

SEVEN_ZIP=$(command -v 7z 2>/dev/null || true)
if [ -z "$SEVEN_ZIP" ] && ! command -v zip >/dev/null 2>&1; then
  printf 'SKIP  neither 7z nor zip is installed\n'
  exit 0
fi
# Without fcntl the restore helper fails closed; the weak lock is the supported opt-in.
python3 -c 'import fcntl' 2>/dev/null || export NASE_WEAK_LOCK=1
WINDOWS_PYTHON=0
python3 -c 'import os, sys; sys.exit(os.name != "nt")' && WINDOWS_PYTHON=1

fixture=$(mktemp -d)
UNREADABLE=""
restore_access() {
  [ -n "$UNREADABLE" ] || return 0
  if [ "$WINDOWS_PYTHON" -eq 1 ]; then
    MSYS_NO_PATHCONV=1 icacls "$(cygpath -w "$UNREADABLE")" /remove:d "$USERNAME" >/dev/null 2>&1
  else
    chmod 600 "$UNREADABLE" 2>/dev/null
  fi
  UNREADABLE=""
}
trap 'restore_access; chmod -R u+w "$fixture" 2>/dev/null; rm -rf "$fixture"' EXIT

populate_workspace() {
  local ws="$1"
  mkdir -p "$ws/kb/general" "$ws/logs/tmp" "$ws/empty-dir" "$ws/tmp"
  printf '# Workspace Context\n' > "$ws/context.md"
  printf 'backup_min_interval_minutes: 0\n' > "$ws/config.md"
  printf 'crlf\r\nbytes\r\n' > "$ws/kb/general/note.md"
  printf 'non-ascii\n' > "$ws/kb/general/caf$(printf '\303\251')-$(printf '\344\270\255').md"
  printf 'latin\n' > "$ws/kb/general/$(printf '\303\251').md"
  printf 'read only\n' > "$ws/read-only.md"
  chmod 444 "$ws/read-only.md"
  printf '#!/bin/sh\n' > "$ws/run.sh"
  printf '@echo off\r\n' > "$ws/tool.cmd"
  : > "$ws/empty.md"
  printf 'hidden\n' > "$ws/.hidden-note"
  printf 'nested\n' > "$ws/logs/tmp/keep.txt"
  printf 'scratch\n' > "$ws/tmp/scratch.bin"
}

make_repo() {
  local repo="$1" target="$2"
  mkdir -p "$repo/.claude/hooks" "$repo/tests" "$repo/workspace" "$fixture/tmpdir"
  git -C "$repo" init -q
  cp "$ROOT/.claude/hooks/stop-backup.sh" "$repo/.claude/hooks/"
  stage_hook_lib "$repo"
  stage_scripts "$repo/.claude/scripts" verify-bundle.py restore-workspace.py
  cp "$SCAN" "$repo/tests/"
  populate_workspace "$repo/workspace"
  printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
}

run_hook() {
  (cd "$1" && TMPDIR="$fixture/tmpdir" bash .claude/hooks/stop-backup.sh) > "$2" 2>&1
}

count_archives() {
  find "$1" -maxdepth 1 -name 'nase-backup-*.zip' 2>/dev/null | wc -l | tr -d ' '
}

# --- a real backup publishes and restores -----------------------------------------------
repo="$fixture/repo"
target="$fixture/backups"
make_repo "$repo" "$target"
cp -Rp "$repo/workspace" "$fixture/expected"
rm -rf "$fixture/expected/tmp"
run_hook "$repo" "$fixture/publish.out"
rc=$?
[ "$rc" -eq 0 ] || cat "$fixture/publish.out" >&2
assert_cmd "real archiver: backup succeeds" test "$rc" -eq 0
assert_cmd "real archiver: one archive is published" test "$(count_archives "$target")" = 1
assert_contains "real archiver: status records success" "$repo/workspace/logs/.backup-status" "[OK] created nase-backup-"

archive=$(find "$target" -maxdepth 1 -name 'nase-backup-*.zip' -print -quit 2>/dev/null)
if [ -n "$archive" ]; then
  chmod u+w "$repo/workspace/read-only.md"
  printf 'drifted\n' > "$repo/workspace/context.md"
  printf 'local only\n' > "$repo/workspace/added-later.md"
  rm -f "$repo/workspace/read-only.md" "$repo/workspace/.hidden-note"
  python3 "$repo/.claude/scripts/restore-workspace.py" inspect \
    --root "$repo" --archive "$archive" --manifest-out "$fixture/restore.json" > "$fixture/restore.out" 2>&1 \
    && python3 "$repo/.claude/scripts/restore-workspace.py" apply \
      --root "$repo" --manifest "$fixture/restore.json" >> "$fixture/restore.out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || cat "$fixture/restore.out" >&2
  assert_cmd "real archiver: restore applies" test "$rc" -eq 0
  # .backup-status is appended after the snapshot is taken, and the seed tree has none.
  assert_cmd "real archiver: restored tree matches the backed-up tree" \
    diff -r -x .backup-status "$fixture/expected" "$repo/workspace"
else
  fail "real archiver: restore applies (no archive to restore)"
fi

# --- an archiver that tampers with the real archive publishes nothing --------------------
if [ -n "$SEVEN_ZIP" ]; then
  wrapbin="$fixture/wrapbin"
  mkdir -p "$wrapbin"
  cat > "$wrapbin/7z" <<'SH'
#!/usr/bin/env bash
"$REAL_7Z" "$@" || exit $?
for arg in "$@"; do
  case "$arg" in
    *.zip) exec "$REAL_7Z" d -bso0 -bsp0 "$arg" context.md ;;
  esac
done
exit 2
SH
  chmod +x "$wrapbin/7z"
  repo="$fixture/tampered-repo"
  target="$fixture/tampered-backups"
  make_repo "$repo" "$target"
  REAL_7Z="$SEVEN_ZIP" PATH="$wrapbin:$PATH" run_hook "$repo" "$fixture/tampered.out"
  rc=$?
  assert_cmd "member deleted from the real archive fails the backup" test "$rc" -eq 1
  assert_contains "deleted member is named" "$fixture/tampered.out" "missing context.md"
  assert_cmd "tampered backup publishes nothing" test "$(count_archives "$target")" = 0
fi

# --- an unreadable file still fails closed ----------------------------------------------
repo="$fixture/unreadable-repo"
target="$fixture/unreadable-backups"
make_repo "$repo" "$target"
printf 'secret\n' > "$repo/workspace/locked.md"
UNREADABLE="$repo/workspace/locked.md"
if [ "$WINDOWS_PYTHON" -eq 1 ]; then
  MSYS_NO_PATHCONV=1 icacls "$(cygpath -w "$UNREADABLE")" /deny "$USERNAME:(R)" >/dev/null 2>&1
else
  chmod 000 "$UNREADABLE"
fi
if python3 -c 'import sys; open(sys.argv[1], "rb").close()' "$UNREADABLE" 2>/dev/null; then
  printf 'SKIP  unreadable file fails closed (cannot make a file unreadable here)\n'
else
  run_hook "$repo" "$fixture/unreadable.out"
  rc=$?
  assert_cmd "unreadable file fails the backup" test "$rc" -eq 1
  assert_contains "unreadable file is named" "$fixture/unreadable.out" "workspace/locked.md"
  assert_cmd "unreadable file publishes nothing" test "$(count_archives "$target")" = 0
fi
restore_access

# --- a junction is a link: its target never enters a backup ------------------------------
make_junction() {
  MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" >/dev/null
}
# Remove the link itself, so cleanup never walks through it.
remove_junction() {
  MSYS_NO_PATHCONV=1 cmd.exe /c rmdir "$(cygpath -w "$1")" >/dev/null
}
if [ "$WINDOWS_PYTHON" -eq 1 ]; then
  repo="$fixture/junction-repo"
  target="$fixture/junction-backups"
  make_repo "$repo" "$target"
  mkdir -p "$fixture/outside"
  printf 'outside the workspace\n' > "$fixture/outside/outside.txt"
  make_junction "$repo/workspace/kb/linked" "$fixture/outside"
  run_hook "$repo" "$fixture/junction.out"
  rc=$?
  assert_cmd "junction in workspace fails the backup" test "$rc" -eq 1
  assert_contains "junction is named as an unsafe link" "$fixture/junction.out" "workspace/kb/linked"
  assert_cmd "junction publishes nothing" test "$(count_archives "$target")" = 0
  remove_junction "$repo/workspace/kb/linked"

  repo="$fixture/linked-root-repo"
  target="$fixture/linked-root-backups"
  make_repo "$repo" "$target"
  mv "$repo/workspace" "$fixture/moved-workspace"
  make_junction "$repo/workspace" "$fixture/moved-workspace"
  run_hook "$repo" "$fixture/linked-root.out"
  rc=$?
  assert_cmd "workspace that is a junction fails the backup" test "$rc" -eq 1
  assert_contains "junction workspace is reported as a link" "$fixture/linked-root.out" \
    "symbolic link(s) that could escape backup scope"
  assert_cmd "junction workspace publishes nothing" test "$(count_archives "$target")" = 0
  remove_junction "$repo/workspace"
else
  printf 'SKIP  junction in workspace fails the backup (not a Windows host)\n'
fi

# --- validation of real archives, intact and tampered -----------------------------------
source_dir="$fixture/source"
populate_workspace "$source_dir"
bash "$SCAN" --manifest "$source_dir" "$fixture/manifest.json" || fail "source manifest is created"

# tamper.py IN OUT CASE: rewrite a real archive with exactly one thing changed, keeping
# every other member's attributes as the archiver wrote them.
cat > "$fixture/tamper.py" <<'PY'
import copy
import stat
import sys
import zipfile

source, destination, case = sys.argv[1:]
with zipfile.ZipFile(source) as archive:
    members = [(info, archive.read(info)) for info in archive.infolist()]


def dos(info, attributes):
    info.create_system = 0
    info.external_attr = attributes


class Unflagged(zipfile.ZipInfo):
    # What Apple's zip writes: UTF-8 name bytes with the UTF-8 flag left clear.
    __slots__ = ()

    def _encodeFilenameFlags(self):
        return self.filename.encode("utf-8"), self.flag_bits & ~0x800


def real_name(info):
    if info.flag_bits & 0x800:
        return info.filename
    try:
        return info.filename.encode("cp437").decode("utf-8")
    except UnicodeError:
        return info.filename


output = []
for info, data in members:
    info = copy.copy(info)
    if case == "unflagged-names":
        info.filename = real_name(info)
        info.__class__ = Unflagged
    name = info.filename
    if case == "dos-entries":
        # What 7-Zip on Windows writes: no Unix mode, only DOS attributes.
        read_only = name == "read-only.md"
        dos(info, 0x10 if info.is_dir() else (0x21 if read_only else 0x20))
    if name == "context.md":
        if case == "content":
            data = data.replace(b"Context", b"Cont3xt")
        elif case == "size":
            data = data[:-1]
        elif case == "missing":
            continue
        elif case == "unix-mode":
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o601) << 16
        elif case == "dos-host-unix-mode":
            dos(info, ((stat.S_IFREG | 0o601) << 16) | 0x20)
        elif case == "unix-host-no-mode":
            info.create_system = 3
            info.external_attr = 0x20
        elif case == "other-host-no-mode":
            info.create_system = 10
            info.external_attr = 0x20
        elif case == "dos-read-only-added":
            dos(info, 0x21)
        elif case == "link":
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
        elif case == "type":
            info.filename = "context.md/"
            data = b""
    if name == "read-only.md" and case == "dos-read-only-removed":
        dos(info, 0x20)
    output.append((info, data))
if case in {"extra-file", "extra-dir"}:
    extra = zipfile.ZipInfo("extra.md" if case == "extra-file" else "extra/")
    dos(extra, 0x20 if case == "extra-file" else 0x10)
    output.append((extra, b"x" if case == "extra-file" else b""))
with zipfile.ZipFile(destination, "w") as archive:
    for info, data in output:
        archive.writestr(info, data)
if case == "unflagged-names":
    with zipfile.ZipFile(destination) as archive:
        flags = [i.flag_bits & 0x800 for i in archive.infolist() if not i.filename.isascii()]
    if not flags or any(flags):
        sys.exit("unflagged-names: the rewritten archive has no unflagged non-ASCII name")
PY

validate() {
  bash "$SCAN" --archive "$1" "$fixture/manifest.json" > "$fixture/validate.out" 2>&1
}

expect_rejected() {
  local name="$1" archive_path="$2" message="$3" rc
  validate "$archive_path"
  rc=$?
  if [ "$rc" -eq 1 ] && grep -Fq -- "$message" "$fixture/validate.out"; then
    pass "$name"
  else
    cat "$fixture/validate.out" >&2
    fail "$name (exit=$rc)"
  fi
}

for backend in 7z zip; do
  if ! command -v "$backend" >/dev/null 2>&1; then
    printf 'SKIP  %s backend (not installed)\n' "$backend"
    continue
  fi
  intact="$fixture/$backend.zip"
  if [ "$backend" = 7z ]; then
    (cd "$source_dir" && 7z a -tzip -mx=1 -snl -bso0 -bsp0 "$intact" . -x!tmp)
  else
    (cd "$source_dir" && zip -qry "$intact" . -x "tmp/*")
  fi
  assert_cmd "$backend: intact archive validates" validate "$intact"
  while IFS='|' read -r tamper_case message; do
    python3 "$fixture/tamper.py" "$intact" "$fixture/$backend-$tamper_case.zip" "$tamper_case" \
      || { fail "$backend: build $tamper_case"; continue; }
    expect_rejected "$backend: rejects $tamper_case" "$fixture/$backend-$tamper_case.zip" "$message"
  done <<'CASES'
content|changed context.md
size|changed context.md
missing|missing context.md
extra-file|unexpected extra.md
extra-dir|unexpected extra
unix-mode|changed context.md
dos-host-unix-mode|changed context.md
unix-host-no-mode|changed context.md
other-host-no-mode|changed context.md
dos-read-only-added|changed context.md
dos-read-only-removed|changed read-only.md
link|contains unsafe member(s)
type|changed context.md
CASES

  # Entries with no Unix mode are accepted only where the manifest's modes are themselves
  # derived from DOS attributes. A POSIX host keeps comparing them and refuses.
  python3 "$fixture/tamper.py" "$intact" "$fixture/$backend-dos.zip" dos-entries
  if [ "$WINDOWS_PYTHON" -eq 1 ]; then
    assert_cmd "$backend: DOS entries with matching attributes validate" validate "$fixture/$backend-dos.zip"
  else
    expect_rejected "$backend: DOS entries are refused on a POSIX host" \
      "$fixture/$backend-dos.zip" "does not match its source manifest"
  fi

  # Apple's zip stores UTF-8 names without the UTF-8 flag, and no CI host runs it.
  if python3 "$fixture/tamper.py" "$intact" "$fixture/$backend-unflagged.zip" unflagged-names; then
    assert_cmd "$backend: UTF-8 names without the UTF-8 flag validate" validate "$fixture/$backend-unflagged.zip"
  else
    fail "$backend: build unflagged-names"
  fi

  head -c 100 "$intact" > "$fixture/$backend-truncated.zip"
  expect_rejected "$backend: rejects a truncated archive" \
    "$fixture/$backend-truncated.zip" "unreadable or invalid"
done

if [ -n "$SEVEN_ZIP" ]; then
  (cd "$source_dir" && 7z a -tzip -mx=1 -pnot-the-password -bso0 -bsp0 "$fixture/encrypted.zip" . -x!tmp)
  expect_rejected "rejects members it cannot read (encrypted)" \
    "$fixture/encrypted.zip" "coverage is incomplete"
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%d real-archiver test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nAll real-archiver backup tests passed.\n'
