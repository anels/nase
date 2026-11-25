#!/usr/bin/env bash
# Regression tests for .claude/hooks/stop-backup.sh safety guards.
#
# Run from repo root:  bash tests/hooks/test-stop-backup-safety.sh
# Exit 0 = all tests pass, exit N = N failures.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
source "$ROOT/tests/lib/stage-scripts.sh"
HOOK="$ROOT/.claude/hooks/stop-backup.sh"

fail=0
pass=0

assert_exit() {
  local desc="$1" expected="$2" actual="$3" out="$4"
  if [ "$actual" = "$expected" ]; then
    printf 'PASS  %s (exit=%s)\n' "$desc" "$actual"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s (expected exit=%s, got %s)\n      out: %s\n' "$desc" "$expected" "$actual" "$out" >&2
    fail=$((fail + 1))
  fi
}

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# The hook runs on a restricted PATH so a real archiver cannot shadow the stubs. Where
# git, python3, or jq live outside the system directories (Git Bash on Windows), reach
# each through a one-tool wrapper instead of exposing its whole install directory.
SYSPATH="/usr/bin:/bin:/usr/sbin:/sbin"
sysbin="$fixture/sysbin"
mkdir -p "$sysbin"
for tool in git python3 jq; do
  if ! PATH="$SYSPATH" command -v "$tool" >/dev/null 2>&1 && tool_path=$(command -v "$tool" 2>/dev/null); then
    printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$tool_path" > "$sysbin/$tool"
    chmod +x "$sysbin/$tool"
  fi
done
SYSPATH="$SYSPATH:$sysbin"
skips=0
skip() {
  printf 'SKIP  %s\n' "$1"
  skips=$((skips + 1))
}
# Git Bash without native symlink support makes `ln -s` copy the target, so a symlink
# case there would pass or fail for the wrong reason.
if ln -s probe-target "$fixture/symlink-probe" 2>/dev/null && [ -L "$fixture/symlink-probe" ]; then
  SYMLINKS=1
else
  SYMLINKS=0
fi
rm -rf "$fixture/symlink-probe"

# Three stubs wrap a working archiver. Use the system zip where there is one, and the
# Python stand-in defined below where there is not.
if [ -x /usr/bin/zip ]; then
  export REAL_ZIP=/usr/bin/zip
else
  export REAL_ZIP="$fixture/fakebin/zip"
fi

make_repo() {
  local repo_path="$1"
  mkdir -p "$repo_path/.claude/hooks" "$repo_path/.claude/scripts" "$repo_path/tests" "$repo_path/workspace"
  git -C "$repo_path" init -q
  cp "$HOOK" "$repo_path/.claude/hooks/stop-backup.sh"
  stage_hook_lib "$repo_path"
  stage_scripts "$repo_path/.claude/scripts" verify-bundle.py commit-log-append.py
  cp "$ROOT/tests/check-local-sensitive-artifacts.sh" "$repo_path/tests/check-local-sensitive-artifacts.sh"
  printf '# Workspace Context\n' > "$repo_path/workspace/context.md"
  # These tests drive the hook repeatedly within seconds. The production default
  # throttle (30 minutes) would make every run after the first a no-op, so each
  # fixture disables it explicitly; the throttle has its own cases below.
  printf 'backup_min_interval_minutes: 0\n' > "$repo_path/workspace/config.md"
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "$needle" <<< "$haystack"; then
    printf 'PASS  %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n      missing: %s\n      out: %s\n' "$desc" "$needle" "$haystack" >&2
    fail=$((fail + 1))
  fi
}

# stop-backup.sh prefers 7z and only falls back to zip, so a fixture that shadows zip alone
# is bypassed wherever 7z sits on the restricted PATH (/usr/bin on Linux, but not the
# Homebrew prefix on macOS). That silently ran the real archiver: the rejection cases failed
# on CI and the success cases passed vacuously. Shadow 7z in every fixture and route it to
# that fixture's own zip stub so both archiver branches exercise the same fake archive.
install_7z_shim() {
  local dir="$1"
  cat > "$dir/7z" <<'SH'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in
    *.zip) out="$arg"; break ;;
  esac
done
[ -n "$out" ] || exit 2
exec "$(dirname "$0")/zip" -qry "$out" . -x "tmp/*"
SH
  chmod +x "$dir/7z"
}

fakebin="$fixture/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/zip" <<'SH'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) out="$arg"; break ;;
  esac
done
[ -n "$out" ] || exit 1
mkdir -p "$(dirname "$out")"
python3 - "$out" <<'PY'
import os
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    for directory, dirnames, filenames in os.walk("."):
        if directory == ".":
            dirnames[:] = [name for name in dirnames if name != "tmp"]
        for name in dirnames:
            source = os.path.join(directory, name)
            archive.write(source, os.path.relpath(source, "."))
        for name in filenames:
            source = os.path.join(directory, name)
            archive.write(source, os.path.relpath(source, "."))
PY
SH
chmod +x "$fakebin/zip"
install_7z_shim "$fakebin"

# The literal path has depth 3, but canonicalizes to /tmp. The hook must reject
# the resolved path instead of trusting the raw string.
repo="$fixture/shallow-repo"
make_repo "$repo"
printf 'backup-target=/tmp/nase-stop-backup-test/..\n' > "$repo/.local-paths"
out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "reject canonicalized shallow target" 1 "$rc" "$out"
# On a drive-letter host the temp directory is not a shallow system path, so the same
# target is refused as an ancestor of the fixture repo; the resolved path is still named.
if { grep -qF -- "/tmp/nase-stop-backup-test/.." <<< "$out" \
  && grep -Eq -- 'resolves to: /(private/)?tmp' <<< "$out"; } \
  || grep -Eq -- 'target is ancestor of NASE_ROOT: [A-Za-z]:/' <<< "$out"; then
  printf 'PASS  rejection message includes raw and resolved paths\n'
  pass=$((pass + 1))
else
  printf 'FAIL  rejection message missing raw or resolved path\n      out: %s\n' "$out" >&2
  fail=$((fail + 1))
fi

omitbin="$fixture/omitbin"
mkdir -p "$omitbin"
cat > "$omitbin/zip" <<'SH'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) out="$arg"; break ;;
  esac
done
python3 - "$out" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.write("context.md", "context.md")
PY
SH
chmod +x "$omitbin/zip"
install_7z_shim "$omitbin"
repo="$fixture/incomplete-archive-repo"
target="$fixture/incomplete-archive-backups"
make_repo "$repo"
printf 'must be backed up\n' > "$repo/workspace/important.md"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$omitbin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects an archive that omits a source file" 1 "$rc" "$out"
assert_contains "incomplete archive rejection is explicit" "$out" "does not match its source manifest"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  incomplete archive creates no external backup\n'
  pass=$((pass + 1))
else
  printf 'FAIL  incomplete archive was published\n' >&2
  fail=$((fail + 1))
fi

authoritybin="$fixture/authoritybin"
mkdir -p "$authoritybin"
cat > "$authoritybin/zip" <<'SH'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) out="$arg"; break ;;
  esac
done
printf '{}\n' > "$(dirname "$out")/source-manifest.json"
exec "$REAL_ZIP" "$@"
SH
chmod +x "$authoritybin/zip"
install_7z_shim "$authoritybin"
repo="$fixture/manifest-authority-repo"
target="$fixture/manifest-authority-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$authoritybin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects an archiver that rewrites the bound manifest" 1 "$rc" "$out"
assert_contains "manifest authority rejection is explicit" "$out" "snapshot authority changed"

extradirbin="$fixture/extradirbin"
mkdir -p "$extradirbin"
cat > "$extradirbin/zip" <<'SH'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) out="$arg"; break ;;
  esac
done
"$REAL_ZIP" "$@" || exit $?
python3 - "$out" <<'PY'
import stat
import sys
import zipfile

entry = zipfile.ZipInfo("unexpected/")
entry.create_system = 3
entry.external_attr = (stat.S_IFDIR | 0o755) << 16
with zipfile.ZipFile(sys.argv[1], "a") as archive:
    archive.writestr(entry, b"")
PY
SH
chmod +x "$extradirbin/zip"
install_7z_shim "$extradirbin"
repo="$fixture/extra-directory-repo"
target="$fixture/extra-directory-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$extradirbin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects an archive with an extra directory" 1 "$rc" "$out"
assert_contains "extra directory rejection is explicit" "$out" "does not match its source manifest"

repo="$fixture/inside-workspace-repo"
make_repo "$repo"
printf 'backup-target=%s\n' "$repo/workspace/backups" > "$repo/.local-paths"
out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "reject target inside workspace" 1 "$rc" "$out"
assert_contains "inside-workspace rejection explains boundary" "$out" "backup target must be outside workspace/"

repo="$fixture/canonical-inside-workspace-repo"
make_repo "$repo"
printf 'backup-target=%s\n' "$repo/workspace/../workspace/backups" > "$repo/.local-paths"
out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "reject canonicalized target inside workspace" 1 "$rc" "$out"
assert_contains "canonical inside-workspace message includes resolved path" "$out" "resolves to:"
assert_contains "canonical inside-workspace message includes workspace target" "$out" "canonical-inside-workspace-repo/workspace/backups"

repo="$fixture/no-repo-paths-repo"
target="$fixture/no-repo-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup succeeds with only backup-target configured" 0 "$rc" "$out"
if find "$target" -name 'nase-backup-*.zip' -print -quit | grep -q .; then
  printf 'PASS  backup archive created without repo path entries\n'
  pass=$((pass + 1))
else
  printf 'FAIL  expected backup archive was not created\n      out: %s\n' "$out" >&2
  fail=$((fail + 1))
fi

repo="$fixture/runtime-reference-repo"
target="$fixture/runtime-reference-backups"
make_repo "$repo"
runtime_field='pass''word'
runtime_client_field='client_''secret'
printf '%s\n' \
  "$runtime_field = secrets.token_urlsafe(32)" \
  "$runtime_client_field = vault.get_secret(\"client-secret\")" \
  "$runtime_field = getpass.getpass()" \
  "$runtime_field = input(\"Password: \")" \
  > "$repo/workspace/safe-runtime-references.py"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "safe runtime credential expressions do not block backup" 0 "$rc" "$out"
if find "$target" -name 'nase-backup-*.zip' -print -quit | grep -q .; then
  printf 'PASS  runtime-reference backup archive created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  runtime-reference backup archive missing\n' >&2
  fail=$((fail + 1))
fi

if [ "$SYMLINKS" != 1 ]; then
  skip "backup rejects workspace symlink before archive (no symlink support)"
  skip "symlink rejection names the security preflight (no symlink support)"
  skip "symlink rejection creates no archive (no symlink support)"
else
repo="$fixture/symlink-source-repo"
target="$fixture/symlink-source-backups"
outside="$fixture/symlink-outside.txt"
make_repo "$repo"
printf 'outside marker\n' > "$outside"
ln -s "$outside" "$repo/workspace/external-link.txt"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects workspace symlink before archive" 1 "$rc" "$out"
assert_contains "symlink rejection names the security preflight" "$out" "workspace security preflight failed"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  symlink rejection creates no archive\n'
  pass=$((pass + 1))
else
  printf 'FAIL  symlink rejection created an archive\n' >&2
  fail=$((fail + 1))
fi
fi

racebin="$fixture/racebin"
mkdir -p "$racebin"
cat > "$racebin/zip" <<'SH'
#!/usr/bin/env bash
rm -f mutable.txt
ln -s "$RACE_OUTSIDE" mutable.txt
exec "$REAL_ZIP" "$@"
SH
chmod +x "$racebin/zip"
install_7z_shim "$racebin"
repo="$fixture/raced-symlink-source-repo"
target="$fixture/raced-symlink-source-backups"
outside="$fixture/raced-symlink-outside.txt"
make_repo "$repo"
printf 'safe before preflight\n' > "$repo/workspace/mutable.txt"
printf 'external marker\n' > "$outside"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && RACE_OUTSIDE="$outside" PATH="$racebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects symlink inserted after live preflight" 1 "$rc" "$out"
assert_contains "raced snapshot rejection is explicit" "$out" "private workspace snapshot changed during archive creation"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  raced symlink creates no external archive\n'
  pass=$((pass + 1))
else
  printf 'FAIL  raced symlink created an external archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/plaintext-source-repo"
target="$fixture/plaintext-source-backups"
make_repo "$repo"
credential_key='ADMIN_PASSWORD'
printf '%s\n' "$credential_key = \"two word canary\"" > "$repo/workspace/local-config.txt"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup with quoted plaintext credential still runs" 0 "$rc" "$out"
assert_contains "quoted plaintext credential is reported as a warning" "$out" "credential-like values in workspace were backed up"
if grep -q '\[WARNING\] credential-like values in workspace were backed up' \
  "$repo/workspace/logs/.backup-status" 2>/dev/null; then
  printf 'PASS  the advisory warning is recorded in .backup-status for the next session\n'
  pass=$((pass + 1))
else
  printf 'FAIL  the advisory warning is missing from .backup-status\n' >&2
  fail=$((fail + 1))
fi
if find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  quoted plaintext credential is advisory and the archive is created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  quoted plaintext credential blocked the archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/escaped-json-source-repo"
target="$fixture/escaped-json-source-backups"
make_repo "$repo"
printf '{\\"%s\\":\\"%s\\"}\n' "$credential_key" "escaped-json-canary-4831" \
  > "$repo/workspace/escaped.json"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup with escaped JSON credential still runs" 0 "$rc" "$out"
assert_contains "escaped JSON credential is reported as a warning" "$out" "credential-like values in workspace were backed up"
if find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  escaped JSON credential is advisory and the archive is created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  escaped JSON credential blocked the archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/triple-quoted-source-repo"
target="$fixture/triple-quoted-source-backups"
make_repo "$repo"
printf '%s=%s%s%s\n' "$credential_key" '"""' "triple-quoted-canary-4831" '"""' \
  > "$repo/workspace/local-config.py"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup with triple-quoted credential still runs" 0 "$rc" "$out"
assert_contains "triple-quoted credential is reported as a warning" "$out" "credential-like values in workspace were backed up"
if find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  triple-quoted credential is advisory and the archive is created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  triple-quoted credential blocked the archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/short-declaration-source-repo"
target="$fixture/short-declaration-source-backups"
make_repo "$repo"
printf '%s := "%s"\n' "$credential_key" "short-declaration-canary" > "$repo/workspace/local-config.go"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup with a short-declaration credential still runs" 0 "$rc" "$out"
assert_contains "a short-declaration credential is reported as a warning" "$out" "credential-like values in workspace were backed up"
if find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  a short-declaration credential is advisory and the archive is created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  a short-declaration credential blocked the archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/overlong-credential-source-repo"
target="$fixture/overlong-credential-source-backups"
make_repo "$repo"
printf '%s="' "$credential_key" > "$repo/workspace/local-config.txt"
printf '%04097d' 0 | tr '0' 'x' >> "$repo/workspace/local-config.txt"
printf '"\n' >> "$repo/workspace/local-config.txt"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup with an overlong quoted credential still runs" 0 "$rc" "$out"
assert_contains "an overlong quoted credential is reported as a warning" "$out" "credential-like values in workspace were backed up"
if find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  an overlong quoted credential is advisory and the archive is created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  an overlong quoted credential blocked the archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/sensitive-commit-subject-repo"
target="$fixture/sensitive-commit-subject-backups"
commit_repo="$fixture/sensitive-commit-source"
make_repo "$repo"
mkdir -p "$commit_repo"
git -C "$commit_repo" init -q
git -C "$commit_repo" config user.email "nase-test@example.com"
git -C "$commit_repo" config user.name "nase test"
printf 'safe\n' > "$commit_repo/file.txt"
git -C "$commit_repo" add file.txt
commit_subject="$credential_key = \"subject_canary_2481\""
git -C "$commit_repo" commit -q -m "$commit_subject"
printf 'second\n' >> "$commit_repo/file.txt"
git -C "$commit_repo" add file.txt
escaped_subject="{\\\"$credential_key\\\":\\\"escaped_subject_canary_2481\\\"}"
git -C "$commit_repo" commit -q -m "$escaped_subject"
printf 'backup-target=%s\nsource=%s\n' "$target" "$commit_repo" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "credential-like commit subject is skipped before workspace write" 0 "$rc" "$out"
assert_contains "credential-like commit subject skip is reported" "$out" "skipped a commit summary containing a credential-like value"
if ! grep -R -q subject_canary_2481 "$repo/workspace"; then
  printf 'PASS  credential-like commit subject never reaches workspace\n'
  pass=$((pass + 1))
else
  printf 'FAIL  credential-like commit subject reached workspace\n' >&2
  fail=$((fail + 1))
fi
if ! grep -R -q escaped_subject_canary_2481 "$repo/workspace"; then
  printf 'PASS  escaped credential commit subject never reaches workspace\n'
  pass=$((pass + 1))
else
  printf 'FAIL  escaped credential commit subject reached workspace\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/tilde-target-repo"
home_dir="$fixture/home"
target="$home_dir/nase-backups"
mkdir -p "$home_dir"
make_repo "$repo"
printf 'backup-target=~/nase-backups\n' > "$repo/.local-paths"
out=$(cd "$repo" && HOME="$home_dir" PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup expands tilde target before archive" 0 "$rc" "$out"
if find "$target" -name 'nase-backup-*.zip' -print -quit | grep -q .; then
  printf 'PASS  tilde backup archive created under HOME\n'
  pass=$((pass + 1))
else
  printf 'FAIL  expected tilde backup archive under HOME\n      out: %s\n' "$out" >&2
  fail=$((fail + 1))
fi
if [ ! -d "$repo/~/nase-backups" ]; then
  printf 'PASS  no literal tilde backup directory created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  literal tilde backup directory was created\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/append-only-log-repo"
target="$fixture/append-only-backups"
make_repo "$repo"
git -C "$repo" config user.email "nase-test@example.com"
git -C "$repo" config user.name "nase test"
git -C "$repo" add workspace/context.md
git -C "$repo" commit -q -m "seed workspace"
today=$(date +%Y-%m-%d)
mkdir -p "$repo/workspace/logs"
cat > "$repo/workspace/logs/$today.md" <<'LOG'
# Work Log

## Sessions
- 09:00 | test: keep this session entry

## Commits
manual commit note that must stay
LOG
printf 'backup-target=%s\nself=%s\n' "$target" "$repo" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup keeps existing commit log content" 0 "$rc" "$out"
if grep -qF "manual commit note that must stay" "$repo/workspace/logs/$today.md"; then
  printf 'PASS  existing commit section was not rewritten\n'
  pass=$((pass + 1))
else
  printf 'FAIL  existing commit section was rewritten\n      log: %s\n' "$(cat "$repo/workspace/logs/$today.md")" >&2
  fail=$((fail + 1))
fi
assert_contains "new commit summary appended" "$(cat "$repo/workspace/logs/$today.md")" "seed workspace"

# --- content dedup: an unchanged workspace must not publish a second archive ----------
# The hook appends to workspace/logs/.backup-status on every run, so a naive manifest
# fingerprint would differ every time and dedup would never fire. These cases pin that
# the churn file is excluded from the fingerprint but real content changes are not.
count_archives() {
  ls -1 "$1"/nase-backup-*.zip 2>/dev/null | wc -l | tr -d ' '
}

repo="$fixture/dedup-repo"
target="$fixture/dedup-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
# A real workspace already has logs/; without it the first run would create the
# directory and the second would see a genuinely different tree.
mkdir -p "$repo/workspace/logs"
cat > "$repo/workspace/logs/$(date +%Y-%m-%d).md" <<'LOG'
# Work Log

## Sessions
- 09:00 | test: seed entry
LOG

out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "first backup succeeds" 0 "$rc" "$out"
assert_exit "first run published one archive" 1 "$(count_archives "$target")" "$out"

sleep 1
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "unchanged rerun succeeds" 0 "$rc" "$out"
assert_contains "unchanged rerun reports a skip" "$out" "workspace unchanged since last archive"
assert_exit "unchanged rerun published no second archive" 1 "$(count_archives "$target")" "$out"

sleep 1
printf 'changed content\n' > "$repo/workspace/context.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "changed workspace succeeds" 0 "$rc" "$out"
assert_exit "changed workspace published a second archive" 2 "$(count_archives "$target")" "$out"

# Dedup must stay bound to the exact validated archive. If that archive disappears
# while an older one remains, the older bytes cannot satisfy the current fingerprint.
latest_archive=$(ls -1 "$target"/nase-backup-*.zip | sort | tail -1)
rm -f "$latest_archive"
sleep 1
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "missing fingerprint-bound archive re-publishes" 0 "$rc" "$out"
assert_exit "older unrelated archive does not suppress replacement" 2 "$(count_archives "$target")" "$out"

# The recorded archive name alone is not enough: storage corruption must not
# leave an empty or changed file satisfying the current workspace fingerprint.
latest_archive=$(ls -1 "$target"/nase-backup-*.zip | sort | tail -1)
: > "$latest_archive"
sleep 1
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "corrupted fingerprint-bound archive re-publishes" 0 "$rc" "$out"
assert_exit "corrupted archive does not suppress replacement" 3 "$(count_archives "$target")" "$out"

# Dedup must never mean "no current backup": once the fingerprint-bound archive
# falls outside a days policy, the hook publishes a replacement before pruning it.
rm -f "$target"/nase-backup-*.zip "$repo/.nase-backup-state"
printf 'backup_retention: days:1\nbackup_min_interval_minutes: 0\n' > "$repo/workspace/config.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "days-policy seed backup succeeds" 0 "$rc" "$out"
latest_archive=$(ls -1 "$target"/nase-backup-*.zip | sort | tail -1)
expired_archive="$target/nase-backup-20000101-000000.zip"
mv "$latest_archive" "$expired_archive"
sed -i.bak 's/^last-archive=.*/last-archive=nase-backup-20000101-000000.zip/' "$repo/.nase-backup-state"
rm -f "$repo/.nase-backup-state.bak"
sleep 1
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "expired fingerprint-bound archive triggers replacement" 0 "$rc" "$out"
assert_exit "expired archive is pruned after replacement" 1 "$(count_archives "$target")" "$out"

# With the same content but every archive removed, the hook has to publish again
# rather than trust the stored fingerprint.
sleep 1
rm -f "$target"/nase-backup-*.zip
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "empty target re-publishes despite matching fingerprint" 0 "$rc" "$out"
assert_exit "empty target regained an archive" 1 "$(count_archives "$target")" "$out"

# --- retention: a count clause bounds what a single day can leave behind ---------------
repo="$fixture/retention-repo"
target="$fixture/retention-backups"
make_repo "$repo"
mkdir -p "$target"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf 'backup_retention: days:30,count:2\nbackup_min_interval_minutes: 0\n' > "$repo/workspace/config.md"
today=$(date +%Y%m%d)
for stamp in 000001 000002 000003 000004; do
  printf 'placeholder\n' > "$target/nase-backup-${today}-${stamp}.zip"
done
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "combined retention run succeeds" 0 "$rc" "$out"
assert_exit "count clause caps same-day archives" 2 "$(count_archives "$target")" "$out"

# An unparsable clause must not silently disable retention.
repo="$fixture/retention-invalid-repo"
target="$fixture/retention-invalid-backups"
make_repo "$repo"
mkdir -p "$target"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf 'backup_retention: weeks:4\nbackup_min_interval_minutes: 0\n' > "$repo/workspace/config.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "unusable retention policy still backs up" 0 "$rc" "$out"
assert_contains "unusable retention policy warns" "$out" "invalid retention clause"
assert_contains "unusable retention policy falls back" "$out" "using default count:100"

# A zero count would delete the archive that was just published. Treat it as
# unusable input and keep the fail-safe default instead.
repo="$fixture/retention-zero-repo"
target="$fixture/retention-zero-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf 'backup_retention: count:0\nbackup_min_interval_minutes: 0\n' > "$repo/workspace/config.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "zero retention count still backs up" 0 "$rc" "$out"
assert_contains "zero retention count warns" "$out" "invalid retention clause"
assert_exit "zero retention count cannot delete the new archive" 1 "$(count_archives "$target")" "$out"

# A required replacement must not fail when the current second still maps to
# the changed archive's existing name.
repo="$fixture/same-second-collision-repo"
target="$fixture/same-second-collision-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "same-second collision seed backup succeeds" 0 "$rc" "$out"
latest_archive=$(ls -1 "$target"/nase-backup-*.zip | sort | tail -1)
collision_timestamp=$(basename "$latest_archive" | sed 's/^nase-backup-//; s/\.zip$//')
: > "$latest_archive"
collisionbin="$fixture/collisionbin"
mkdir -p "$collisionbin"
cp "$fakebin/zip" "$fakebin/7z" "$collisionbin/"
cat > "$collisionbin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = '+%Y%m%d-%H%M%S' ] && mkdir "$NASE_DATE_ONCE" 2>/dev/null; then
  printf '%s\n' "$NASE_COLLISION_TIMESTAMP"
  exit 0
fi
exec "$NASE_REAL_DATE" "$@"
SH
chmod +x "$collisionbin/date"
out=$(cd "$repo" \
  && NASE_COLLISION_TIMESTAMP="$collision_timestamp" \
  NASE_DATE_ONCE="$fixture/date-once" \
  NASE_REAL_DATE="$(command -v date)" \
  PATH="$collisionbin:$SYSPATH" \
  bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "same-second collision publishes a replacement" 0 "$rc" "$out"
assert_exit "same-second collision preserves both archives" 2 "$(count_archives "$target")" "$out"

# --- minimum-interval throttle --------------------------------------------------------
# `Stop` fires once per assistant turn, so a working session reaches the hook every few
# minutes with genuinely changed content that dedup cannot suppress. These cases pin that
# the throttle bounds that rate, and that it never leaves a target with no archive.
repo="$fixture/throttle-repo"
target="$fixture/throttle-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
# No throttle key: the production default (30 minutes) has to apply.
printf '# Workspace Config\n' > "$repo/workspace/config.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "throttle default seed backup succeeds" 0 "$rc" "$out"
assert_exit "throttle default published one archive" 1 "$(count_archives "$target")" "$out"

sleep 1
printf 'changed content\n' > "$repo/workspace/context.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "throttled rerun succeeds" 0 "$rc" "$out"
assert_contains "throttled rerun reports the throttle" "$out" "throttled (backup_min_interval_minutes: 30)"
assert_exit "throttled rerun published no second archive" 1 "$(count_archives "$target")" "$out"

# The throttle is anchored on the newest archive, not on a state file: once every
# archive has aged past the window, the next run must publish again.
latest_archive=$(ls -1 "$target"/nase-backup-*.zip | sort | tail -1)
mv "$latest_archive" "$target/nase-backup-20000101-000000.zip"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "aged-out archive lifts the throttle" 0 "$rc" "$out"
assert_exit "aged-out archive got a replacement" 2 "$(count_archives "$target")" "$out"

# An empty target has no interval to be too soon after. The throttle must never be
# the reason a configured target holds no backup at all.
repo="$fixture/throttle-empty-repo"
target="$fixture/throttle-empty-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf '# Workspace Config\n' > "$repo/workspace/config.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "empty target backs up despite the default throttle" 0 "$rc" "$out"
assert_exit "empty target gained an archive" 1 "$(count_archives "$target")" "$out"

# An unparsable interval must warn and fall back, not silently disable the throttle.
repo="$fixture/throttle-invalid-repo"
target="$fixture/throttle-invalid-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf 'backup_min_interval_minutes: half-hour\n' > "$repo/workspace/config.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "invalid throttle interval still backs up" 0 "$rc" "$out"
assert_contains "invalid throttle interval warns" "$out" "invalid backup_min_interval_minutes"
sleep 1
printf 'changed again\n' > "$repo/workspace/context.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "invalid throttle interval falls back to the default" 0 "$rc" "$out"
assert_exit "invalid throttle interval did not disable throttling" 1 "$(count_archives "$target")" "$out"

# A concurrent owner creates the lock dir before it writes its pid. A run that lands in
# that window must treat the lock as held, not delete it as stale and race the owner.
repo="$fixture/lock-window-repo"
target="$fixture/lock-window-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
mkdir -p "$target/.backup-lock"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "fresh lock without a pid skips the run" 0 "$rc" "$out"
assert_contains "fresh lock without a pid is reported as in progress" "$out" "another backup is already in progress"
lock_present=no
[ -d "$target/.backup-lock" ] && lock_present=yes
assert_contains "fresh lock without a pid is left in place" "$lock_present" "yes"
assert_exit "fresh lock without a pid publishes no archive" 0 "$(count_archives "$target")" "$out"

# The same lock dir left behind by a run that died before writing its pid is stale.
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 minutes' +%Y%m%d%H%M.%S)" "$target/.backup-lock"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "old lock without a pid is recovered" 0 "$rc" "$out"
assert_contains "old lock without a pid is reported stale" "$out" "removing stale backup lock"
assert_exit "old lock without a pid lets the backup publish" 1 "$(count_archives "$target")" "$out"

# Several runs that all see the same dead owner must not each reclaim the lock. The harness
# runs the hook's own lock block (cut out by markers) in parallel and counts the runs that
# hold the lock at the same time. rm -rf then mkdir lets two of them in. A run that takes the
# lock after the first holder released it is legal, so a late starter on a slow CI runner
# must not count: each holder claims a "held" marker for its whole hold, and a failed claim
# means two holders overlapped.
lock_block_script() {
  local hook_file="$1" out_file="$2" tail_cmd="$3"
  {
    printf 'set -euo pipefail\nlog_status() { :; }\nTARGET="$1"\n'
    printf 'while [ ! -e "$TARGET/go" ]; do :; done\n'
    sed -n '/^LOCK_DIR=/,/^trap cleanup_backup EXIT/p' "$hook_file"
    printf '%s\n' "$tail_cmd"
  } > "$out_file"
}

lock_race_rounds_with_overlap() { # <script> <rounds> [stale|free]
  local acq="$1" rounds="$2" start="${3:-stale}" bad=0 t n dead
  for _ in $(seq "$rounds"); do
    t=$(mktemp -d "$fixture/lock-race.XXXXXX")
    if [ "$start" = stale ]; then
      sleep 0 & dead=$!
      wait "$dead"
      mkdir "$t/.backup-lock"
      printf '%s\n' "$dead" > "$t/.backup-lock/pid"
    fi
    for _ in 1 2 3 4 5 6; do
      bash "$acq" "$t" >> "$t/out" 2>/dev/null &
    done
    sleep 0.2
    : > "$t/go"
    wait
    n=$(grep -c OVERLAP "$t/out" || true)
    [ "$n" -gt 0 ] && bad=$((bad + 1))
    rm -rf "$t"
  done
  printf '%s' "$bad"
}

acq_new="$fixture/lock-acq-new.sh"
# The marker is claimed with bash's exclusive create, so detection stays exact where mkdir is not.
lock_block_script "$HOOK" "$acq_new" 'if (set -C; : > "$TARGET/held") 2>/dev/null; then sleep 0.3; rm -f "$TARGET/held"; else echo OVERLAP; fi'
overlap_rounds=$(lock_race_rounds_with_overlap "$acq_new" 20)
assert_exit "concurrent stale-lock reclaim never admits two holders" 0 "$overlap_rounds" "rounds with >1 holder: $overlap_rounds"

# uutils mkdir before 0.11.0 (Ubuntu 26.04 ships it) checks that the path is absent, then reports
# success when the create fails on an existing directory, so two runs racing on one path can both
# exit 0. The stub widens that gap.
racy_mkdir_overlaps() { # <rounds> [stale|free]
  (
    mkdir() { [ ! -e "$1" ] || return 1; sleep 0.1; command mkdir "$1" 2>/dev/null || [ -d "$1" ]; }
    export -f mkdir
    lock_race_rounds_with_overlap "$acq_new" "$@"
  )
}
overlap_rounds=$(racy_mkdir_overlaps 5)
assert_exit "a non-exclusive mkdir never admits two holders" 0 "$overlap_rounds" "rounds with >1 holder: $overlap_rounds"

# With no lock to reclaim, every run races on the lock mkdir itself, so only the pid claim picks one.
overlap_rounds=$(racy_mkdir_overlaps 5 free)
assert_exit "a non-exclusive mkdir on a free lock admits one holder" 0 "$overlap_rounds" "rounds with >1 holder: $overlap_rounds"

# The race above only sometimes lands in the narrow windows, so each one is staged here.
# The probe runs the hook's own lock_is_stale; its second argument sets up the interleaving.
stale_probe="$fixture/lock-probe.sh"
{
  printf 'set -uo pipefail\nLOCK_DIR="$1/.backup-lock"\nLOCK_PID="$LOCK_DIR/pid"\n'
  sed -n '/^lock_is_stale()/,/^}/p' "$HOOK"
  printf 'eval "$2"\nif lock_is_stale; then echo stale; else echo held; fi\n'
} > "$stale_probe"
probe_lock() { # <setup snippet>
  local t
  t=$(mktemp -d "$fixture/lock-probe.XXXXXX")
  bash "$stale_probe" "$t" "$1" 2>&1
}
assert_contains "fresh lock with an unwritten pid is held" \
  "$(probe_lock 'mkdir "$LOCK_DIR"; : > "$LOCK_PID"')" "held"
assert_contains "old lock with an empty pid is stale" \
  "$(probe_lock 'mkdir "$LOCK_DIR"; : > "$LOCK_PID"; touch -t 200001010000 "$LOCK_DIR"')" "stale"
assert_contains "a lock released before the check is not reclaimed" "$(probe_lock ':')" "held"
assert_contains "a lock whose owner exits during the check is not reclaimed" \
  "$(probe_lock 'mkdir "$LOCK_DIR"; echo 4242 > "$LOCK_PID"; kill() { rm -rf "$LOCK_DIR"; return 1; }')" "held"
assert_contains "a dead owner that left its lock is stale" \
  "$(probe_lock 'mkdir "$LOCK_DIR"; echo 4242 > "$LOCK_PID"; kill() { return 1; }')" "stale"

# A reclaim mutex released between the failed claim and its age check may already belong
# to the next reclaimer, so it must not be removed.
acq_mutex="$fixture/lock-acq-mutex.sh"
lock_block_script "$HOOK" "$acq_mutex" 'true'
t=$(mktemp -d "$fixture/lock-mutex.XXXXXX")
: > "$t/go"
mkdir "$t/.backup-lock"
touch -t 200001010000 "$t/.backup-lock"
mutex="$t/.backup-lock.reclaim"
printf '1\n' > "$mutex"
out=$(
  stat() { case "$*" in *.reclaim) command rm -f "${@: -1}"; return 1 ;; esac; command stat "$@"; }
  rm() { case "$*" in *.reclaim) echo "removed the mutex" ;; *) command rm "$@" ;; esac; }
  export -f stat rm
  bash "$acq_mutex" "$t" 2>&1
)
assert_exit "a vanished reclaim mutex is not removed" "" "$out" "$out"
mutex_left_after_probe() {
  touch -t 200001010000 "$mutex"
  bash "$acq_mutex" "$t" >/dev/null 2>&1
  if [ -e "$mutex" ]; then echo present; else echo removed; fi
}
printf '1\n' > "$mutex"
assert_contains "an abandoned reclaim mutex is removed" "$(mutex_left_after_probe)" "removed"
# Earlier versions of the hook made the mutex a directory.
mkdir "$mutex"
assert_contains "an abandoned reclaim mutex directory is removed" "$(mutex_left_after_probe)" "removed"
# A fresh directory belongs to an older hook that is reclaiming right now.
mkdir "$mutex"
bash "$acq_mutex" "$t" >/dev/null 2>&1
state=reclaimed
[ -d "$mutex" ] && [ -d "$t/.backup-lock" ] && state=held
assert_contains "a fresh reclaim mutex directory holds the reclaim off" "$state" "held"
rmdir "$mutex"

# The exit trap must not delete a lock that another run has since taken over.
acq_own="$fixture/lock-acq-own.sh"
lock_block_script "$HOOK" "$acq_own" 'echo 4242 > "$LOCK_PID"'
t=$(mktemp -d "$fixture/lock-own.XXXXXX")
: > "$t/go"
bash "$acq_own" "$t" >/dev/null 2>&1
lock_present=no
[ -d "$t/.backup-lock" ] && lock_present=yes
assert_contains "exit trap leaves a lock that another pid owns" "$lock_present" "yes"
t=$(mktemp -d "$fixture/lock-own2.XXXXXX")
: > "$t/go"
acq_plain="$fixture/lock-acq-plain.sh"
lock_block_script "$HOOK" "$acq_plain" 'true'
bash "$acq_plain" "$t" >/dev/null 2>&1
lock_present=no
[ -d "$t/.backup-lock" ] && lock_present=yes
assert_contains "exit trap removes the lock its own run holds" "$lock_present" "no"

# --- .local-paths without a backup-target= line -------------------------------------
# grep exits 1 on no match; under pipefail that used to abort the script silently, so the
# "target path is empty" ERROR below it was unreachable and nothing ever got backed up.
repo="$fixture/no-target-line-repo"
make_repo "$repo"
printf 'Repo=%s\n' "$fixture/some-repo" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "missing backup-target line exits 1" 1 "$rc" "$out"
assert_contains "missing backup-target line reports the empty target" "$out" "backup target path is empty"

# --- NASE_ROOT exported by hook-dispatch.sh wins over the cwd's git toplevel ---------
repo="$fixture/nase-root-override-repo"
target="$fixture/nase-root-override-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
nongit="$fixture/nase-root-override-nongit"
mkdir -p "$nongit"
out=$(cd "$nongit" && NASE_ROOT="$repo" PATH="$fakebin:$SYSPATH" bash "$repo/.claude/hooks/stop-backup.sh" 2>&1)
rc=$?
assert_exit "NASE_ROOT override works from a non-git cwd" 0 "$rc" "$out"
assert_exit "NASE_ROOT override publishes into the overridden workspace's target" 1 "$(count_archives "$target")" "$out"
othergit="$fixture/nase-root-override-othergit"
mkdir -p "$othergit"
git -C "$othergit" init -q
out=$(cd "$othergit" && NASE_ROOT="$repo" PATH="$fakebin:$SYSPATH" bash "$repo/.claude/hooks/stop-backup.sh" 2>&1)
rc=$?
assert_exit "NASE_ROOT override beats a different git repo cwd" 0 "$rc" "$out"
if [ ! -e "$othergit/workspace" ]; then
  printf 'PASS  NASE_ROOT override leaves the cwd repo untouched\n'
  pass=$((pass + 1))
else
  printf 'FAIL  NASE_ROOT override wrote into the cwd repo\n' >&2
  fail=$((fail + 1))
fi

# --- a kill mid-publish must not leave a truncated nase-backup-*.zip -----------------
repo="$fixture/partial-publish-repo"
target="$fixture/partial-publish-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
killdir="$fixture/kill-before-rename"
mkdir -p "$killdir"
cat > "$killdir/sitecustomize.py" <<'PY'
import os
import signal

_rename = os.rename


def _kill_on_publish(src, dst, *args, **kwargs):
    if os.path.basename(str(src)).startswith(".nase-backup-"):
        # Windows has no SIGKILL; SIGTERM there is TerminateProcess, the same hard stop.
        os.kill(os.getpid(), getattr(signal, "SIGKILL", signal.SIGTERM))
    return _rename(src, dst, *args, **kwargs)


os.rename = _kill_on_publish
PY
out=$(cd "$repo" && PYTHONPATH="$killdir" PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "killed publish is reported as a failure" 1 "$rc" "$out"
assert_exit "killed publish leaves no nase-backup-*.zip" 0 "$(count_archives "$target")" "$out"
partials=$(find "$target" -maxdepth 1 -name '.nase-backup-*.partial' | wc -l | tr -d ' ')
assert_exit "killed publish leaves only a hidden .partial" 1 "$partials" "$out"
assert_exit "no unhidden partial name is visible to restore/retention globs" 0 \
  "$(ls -1 "$target"/nase-backup-* 2>/dev/null | wc -l | tr -d ' ')" "$out"

# The next run publishes normally, is not throttled by the debris, and keeps a young .partial.
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "run after a killed publish succeeds" 0 "$rc" "$out"
assert_exit "run after a killed publish publishes one archive" 1 "$(count_archives "$target")" "$out"
partials=$(find "$target" -maxdepth 1 -name '.nase-backup-*.partial' | wc -l | tr -d ' ')
assert_exit "a young .partial is kept" 1 "$partials" "$out"

# An old .partial is stale debris and is removed on the next run.
stale_partial=$(find "$target" -maxdepth 1 -name '.nase-backup-*.partial' | head -1)
touch -t "$(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null || date -d '-3 hours' +%Y%m%d%H%M.%S)" "$stale_partial"
sleep 1
printf 'changed after partial\n' > "$repo/workspace/context.md"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "run with a stale .partial succeeds" 0 "$rc" "$out"
partials=$(find "$target" -maxdepth 1 -name '.nase-backup-*.partial' | wc -l | tr -d ' ')
assert_exit "a stale .partial is removed" 0 "$partials" "$out"

# --- commit summary display survives hex-like subjects and empty subjects ------------
# `substr($0, index($0,$2))` finds $2 inside the 40-char hash when the subject starts with
# a hex-like word ("add" sits inside the hash below), and prints the hash twice when the
# subject is empty.
repo="$fixture/hex-subject-repo"
target="$fixture/hex-subject-backups"
make_repo "$repo"
commit_repo="$fixture/hex-subject-source"
mkdir -p "$commit_repo"
git -C "$commit_repo" init -q
printf 'backup-target=%s\nsource=%s\n' "$target" "$commit_repo" > "$repo/.local-paths"
real_git=$(command -v git)
hexbin="$fixture/hexbin"
mkdir -p "$hexbin"
cat > "$hexbin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "--format=%H %s" ]; then
    printf '%s\n' '1fadd5e0a1b2c3d4e5f60718293a4b5c6d7e8f90 add retry logic'
    printf '%s\n' 'abcdef0123456789abcdef0123456789abcdef01 '
    exit 0
  fi
done
exec "$real_git" "\$@"
SH
chmod +x "$hexbin/git"
out=$(cd "$repo" && PATH="$hexbin:$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "hex-like commit subject run succeeds" 0 "$rc" "$out"
hex_log=$(cat "$repo/workspace/logs/$(date +%Y-%m-%d).md" 2>/dev/null)
if grep -qxF '1fadd5e add retry logic' <<< "$hex_log"; then
  printf 'PASS  hex-like subject prints short hash then the full subject\n'
  pass=$((pass + 1))
else
  printf 'FAIL  hex-like subject garbled\n      log: %s\n' "$hex_log" >&2
  fail=$((fail + 1))
fi
if grep -Eq '^abcdef0 +$' <<< "$hex_log"; then
  printf 'PASS  empty subject prints the short hash once\n'
  pass=$((pass + 1))
else
  printf 'FAIL  empty subject line wrong\n      log: %s\n' "$hex_log" >&2
  fail=$((fail + 1))
fi

repo="$fixture/attribution-lines-repo"
target="$fixture/attribution-lines-backups"
commit_repo="$fixture/attribution-lines-source"
make_repo "$repo"
mkdir -p "$commit_repo"
git -C "$commit_repo" init -q
printf 'backup-target=%s\nSourceRepo=%s\nSourceRepo-ai-attribution=on\nOtherRepo-ai-attribution=off\n' \
  "$target" "$commit_repo" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "attribution switches in .local-paths do not break the run" 0 "$rc" "$out"
if grep -qF 'configured repo path not found' <<< "$out"; then
  printf 'FAIL  -ai-attribution lines were read as repo paths\n      out: %s\n' "$out" >&2
  fail=$((fail + 1))
else
  printf 'PASS  -ai-attribution lines are not read as repo paths\n'
  pass=$((pass + 1))
fi

# Top-level workspace/tmp is excluded when the snapshot is copied, not only when it is
# zipped, so a large scratch tree is never duplicated on every run. Nested tmp dirs and
# dotfiles still reach the archive.
cpbin="$fixture/cpbin"
mkdir -p "$cpbin"
cat > "$cpbin/zip" <<SH
#!/usr/bin/env bash
ls -A "\$PWD" > "\$SNAPSHOT_LS"
exec "$fakebin/zip" "\$@"
SH
chmod +x "$cpbin/zip"
install_7z_shim "$cpbin"
repo="$fixture/tmp-copy-repo"
target="$fixture/tmp-copy-backups"
make_repo "$repo"
mkdir -p "$repo/workspace/tmp" "$repo/workspace/logs/tmp"
printf 'scratch\n' > "$repo/workspace/tmp/big-scratch.bin"
printf 'nested\n' > "$repo/workspace/logs/tmp/keep.txt"
printf 'hidden\n' > "$repo/workspace/.hidden-note"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
export SNAPSHOT_LS="$fixture/snapshot-ls.txt"
out=$(cd "$repo" && PATH="$cpbin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup with a workspace/tmp tree succeeds" 0 "$rc" "$out"
if [ ! -s "$SNAPSHOT_LS" ]; then
  printf 'FAIL  snapshot listing was not captured\n' >&2
  fail=$((fail + 1))
elif grep -qx 'tmp' "$SNAPSHOT_LS"; then
  printf 'FAIL  top-level tmp was copied into the snapshot\n' >&2
  fail=$((fail + 1))
else
  printf 'PASS  top-level tmp is not copied into the snapshot\n'
  pass=$((pass + 1))
fi
tmp_zip=$(find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null)
tmp_listing=$(python3 -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$tmp_zip" 2>&1)
assert_contains "archive keeps a nested tmp directory" "$tmp_listing" "logs/tmp/keep.txt"
assert_contains "archive keeps dotfiles" "$tmp_listing" ".hidden-note"
assert_contains "archive keeps top-level files" "$tmp_listing" "context.md"
if grep -q 'big-scratch' <<< "$tmp_listing"; then
  printf 'FAIL  archive contains top-level tmp\n' >&2
  fail=$((fail + 1))
else
  printf 'PASS  archive omits top-level tmp\n'
  pass=$((pass + 1))
fi

# A symlinked workspace/ must still be copied (find does not descend into a symlink start
# path unless it ends in `/.`), and an empty snapshot must never be published.
if [ "$SYMLINKS" != 1 ]; then
  skip "symlinked workspace is copied, not archived empty (no symlink support)"
else
repo="$fixture/symlink-ws-repo"
target="$fixture/symlink-ws-backups"
make_repo "$repo"
mv "$repo/workspace" "$repo/real-workspace"
ln -s real-workspace "$repo/workspace"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$cpbin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
link_zip=$(find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null)
if [ -z "$link_zip" ]; then
  printf 'PASS  symlinked workspace publishes no archive when it is refused (rc=%s)\n' "$rc"
  pass=$((pass + 1))
else
  link_listing=$(python3 -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$link_zip" 2>&1)
  assert_contains "symlinked workspace is copied, not archived empty" "$link_listing" "context.md"
fi
fi

# --- retention owns only the names it generates, and never the archive just published ---
repo="$fixture/retention-names-repo"
target="$fixture/retention-names-backups"
make_repo "$repo"
mkdir -p "$target"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf 'backup_retention: count:1\nbackup_min_interval_minutes: 0\n' > "$repo/workspace/config.md"
printf 'placeholder\n' > "$target/nase-backup-before-migration.zip"
printf 'placeholder\n' > "$target/nase-backup-20000101-000000.zip"
# A future stamp sorts after the archive about to be written, so count:1 would prune the
# new archive if retention did not exempt it.
printf 'placeholder\n' > "$target/nase-backup-29990101-000000.zip"
out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
file_state() { if [ -f "$1" ]; then printf 'present'; else printf 'absent'; fi; }
published=$(sed -n 's/^last-archive=//p' "$repo/.nase-backup-state")
assert_exit "retention run with a hand-named archive succeeds" 0 "$rc" "$out"
assert_exit "hand-named archive is not pruned" present "$(file_state "$target/nase-backup-before-migration.zip")" "$out"
assert_exit "old timestamped archive is pruned" absent "$(file_state "$target/nase-backup-20000101-000000.zip")" "$out"
assert_exit "the archive just published survives count:1" present "$(file_state "$target/$published")" "$out"

# --- a stale snapshot the hook cannot delete must not stop the backup ------------------
repo="$fixture/stale-sweep-repo"
target="$fixture/stale-sweep-backups"
stale_tmp="$fixture/stale-sweep-tmp"
make_repo "$repo"
mkdir -p "$target" "$stale_tmp/nase-backup.AAAAAA/workspace/locked"
printf 'x\n' > "$stale_tmp/nase-backup.AAAAAA/workspace/locked/file"
chmod 555 "$stale_tmp/nase-backup.AAAAAA/workspace/locked"
touch -t 200001010000 "$stale_tmp/nase-backup.AAAAAA"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && TMPDIR="$stale_tmp" PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
chmod -R u+w "$stale_tmp" 2>/dev/null || true
assert_exit "an undeletable stale snapshot does not abort the backup" 0 "$rc" "$out"
assert_exit "the backup is still published after a failed sweep" present "$(file_state "$target/$(sed -n 's/^last-archive=//p' "$repo/.nase-backup-state")")" "$out"

# --- a target above the repo is refused whatever form its path takes -------------------
repo="$fixture/ancestor-target-repo"
make_repo "$repo"
printf 'backup-target=%s\n' "$fixture" > "$repo/.local-paths"
out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "reject target that contains the repo" 1 "$rc" "$out"
if grep -Eq -- 'ancestor of NASE_ROOT|too shallow|unsafe target' <<< "$out"; then
  printf 'PASS  ancestor rejection names a path guard\n'
  pass=$((pass + 1))
else
  printf 'FAIL  ancestor rejection names a path guard\n      out: %s\n' "$out" >&2
  fail=$((fail + 1))
fi

# Drive-letter hosts: the same guards must hold for backslash and differently-cased paths,
# and a one-level target under a drive-style root must not be refused as too shallow.
if command -v cygpath >/dev/null 2>&1 && [[ "$(cygpath -m "$fixture")" == [A-Za-z]:/* ]]; then
  repo="$fixture/drive-form-repo"
  make_repo "$repo"
  printf 'backup-target=%s\n' "$(cygpath -w "$repo/workspace/backups")" > "$repo/.local-paths"
  out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
  rc=$?
  assert_exit "reject backslash target inside workspace" 1 "$rc" "$out"
  assert_contains "backslash inside-workspace rejection explains boundary" "$out" "backup target must be outside workspace/"

  printf 'backup-target=%s\n' "$(cygpath -w "$fixture" | tr '[:upper:]' '[:lower:]')" > "$repo/.local-paths"
  out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
  rc=$?
  assert_exit "reject lower-cased backslash ancestor target" 1 "$rc" "$out"
  assert_contains "lower-cased ancestor rejection names the guard" "$out" "target is ancestor of NASE_ROOT"

  printf 'backup-target=%s\n' "$(cygpath -w "$HOME")" > "$repo/.local-paths"
  out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
  rc=$?
  assert_exit "reject backslash HOME target" 1 "$rc" "$out"

  drive=$(cygpath -m "$fixture" | cut -c1-2)
  printf 'backup-target=%s\n' "$drive\Windows" > "$repo/.local-paths"
  out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
  rc=$?
  assert_exit "reject a system directory under the drive root" 1 "$rc" "$out"
  assert_contains "system directory rejection is the denylist" "$out" "unsafe target path"

  printf 'backup-target=%s\n' "$drive\\" > "$repo/.local-paths"
  out=$(cd "$repo" && bash .claude/hooks/stop-backup.sh 2>&1)
  rc=$?
  assert_exit "reject a bare drive root" 1 "$rc" "$out"

  target="$fixture/drive-form-backups"
  printf 'backup-target=%s\n' "$(cygpath -w "$target")" > "$repo/.local-paths"
  out=$(cd "$repo" && PATH="$fakebin:$SYSPATH" bash .claude/hooks/stop-backup.sh 2>&1)
  rc=$?
  assert_exit "backslash target outside the repo backs up" 0 "$rc" "$out"
  assert_exit "backslash target received an archive" 1 "$(count_archives "$target")" "$out"
else
  skip "drive-letter target forms (not a drive-letter host)"
fi

printf '\n--- %d pass, %d fail, %d skipped ---\n' "$pass" "$fail" "$skips"
exit "$fail"
