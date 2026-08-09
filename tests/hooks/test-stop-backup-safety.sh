#!/usr/bin/env bash
# Regression tests for .claude/hooks/stop-backup.sh safety guards.
#
# Run from repo root:  bash tests/hooks/test-stop-backup-safety.sh
# Exit 0 = all tests pass, exit N = N failures.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
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

make_repo() {
  local repo_path="$1"
  mkdir -p "$repo_path/.claude/hooks" "$repo_path/.claude/scripts" "$repo_path/tests" "$repo_path/workspace"
  git -C "$repo_path" init -q
  cp "$HOOK" "$repo_path/.claude/hooks/stop-backup.sh"
  cp "$ROOT/.claude/scripts/codex-verify-bundle.py" "$repo_path/.claude/scripts/codex-verify-bundle.py"
  cp "$ROOT/tests/check-local-sensitive-artifacts.sh" "$repo_path/tests/check-local-sensitive-artifacts.sh"
  printf '# Workspace Context\n' > "$repo_path/workspace/context.md"
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
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
if printf '%s' "$out" | grep -qF '/tmp/nase-stop-backup-test/..' \
  && printf '%s' "$out" | grep -Eq 'resolves to: /(private/)?tmp'; then
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
out=$(cd "$repo" && PATH="$omitbin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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
exec /usr/bin/zip "$@"
SH
chmod +x "$authoritybin/zip"
install_7z_shim "$authoritybin"
repo="$fixture/manifest-authority-repo"
target="$fixture/manifest-authority-backups"
make_repo "$repo"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$authoritybin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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
/usr/bin/zip "$@" || exit $?
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
out=$(cd "$repo" && PATH="$extradirbin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "safe runtime credential expressions do not block backup" 0 "$rc" "$out"
if find "$target" -name 'nase-backup-*.zip' -print -quit | grep -q .; then
  printf 'PASS  runtime-reference backup archive created\n'
  pass=$((pass + 1))
else
  printf 'FAIL  runtime-reference backup archive missing\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/symlink-source-repo"
target="$fixture/symlink-source-backups"
outside="$fixture/symlink-outside.txt"
make_repo "$repo"
printf 'outside marker\n' > "$outside"
ln -s "$outside" "$repo/workspace/external-link.txt"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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

racebin="$fixture/racebin"
mkdir -p "$racebin"
cat > "$racebin/zip" <<'SH'
#!/usr/bin/env bash
rm -f mutable.txt
ln -s "$RACE_OUTSIDE" mutable.txt
exec /usr/bin/zip "$@"
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
out=$(cd "$repo" && RACE_OUTSIDE="$outside" PATH="$racebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects quoted plaintext credential before archive" 1 "$rc" "$out"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  credential rejection creates no archive\n'
  pass=$((pass + 1))
else
  printf 'FAIL  credential rejection created an archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/escaped-json-source-repo"
target="$fixture/escaped-json-source-backups"
make_repo "$repo"
printf '{\\"%s\\":\\"%s\\"}\n' "$credential_key" "escaped-json-canary-4831" \
  > "$repo/workspace/escaped.json"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects escaped JSON credential before archive" 1 "$rc" "$out"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  escaped JSON credential creates no archive\n'
  pass=$((pass + 1))
else
  printf 'FAIL  escaped JSON credential created an archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/triple-quoted-source-repo"
target="$fixture/triple-quoted-source-backups"
make_repo "$repo"
printf '%s=%s%s%s\n' "$credential_key" '"""' "triple-quoted-canary-4831" '"""' \
  > "$repo/workspace/local-config.py"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects triple-quoted credential before archive" 1 "$rc" "$out"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  triple-quoted credential creates no archive\n'
  pass=$((pass + 1))
else
  printf 'FAIL  triple-quoted credential created an archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/short-declaration-source-repo"
target="$fixture/short-declaration-source-backups"
make_repo "$repo"
printf '%s := "%s"\n' "$credential_key" "short-declaration-canary" > "$repo/workspace/local-config.go"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects a short-declaration credential" 1 "$rc" "$out"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  short-declaration rejection creates no archive\n'
  pass=$((pass + 1))
else
  printf 'FAIL  short-declaration rejection created an archive\n' >&2
  fail=$((fail + 1))
fi

repo="$fixture/overlong-credential-source-repo"
target="$fixture/overlong-credential-source-backups"
make_repo "$repo"
printf '%s="' "$credential_key" > "$repo/workspace/local-config.txt"
printf '%04097d' 0 | tr '0' 'x' >> "$repo/workspace/local-config.txt"
printf '"\n' >> "$repo/workspace/local-config.txt"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "backup rejects an overlong quoted credential" 1 "$rc" "$out"
if ! find "$target" -name 'nase-backup-*.zip' -print -quit 2>/dev/null | grep -q .; then
  printf 'PASS  overlong credential rejection creates no archive\n'
  pass=$((pass + 1))
else
  printf 'FAIL  overlong credential rejection created an archive\n' >&2
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
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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
out=$(cd "$repo" && HOME="$home_dir" PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
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

out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "first backup succeeds" 0 "$rc" "$out"
assert_exit "first run published one archive" 1 "$(count_archives "$target")" "$out"

sleep 1
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "unchanged rerun succeeds" 0 "$rc" "$out"
assert_contains "unchanged rerun reports a skip" "$out" "workspace unchanged since last archive"
assert_exit "unchanged rerun published no second archive" 1 "$(count_archives "$target")" "$out"

sleep 1
printf 'changed content\n' > "$repo/workspace/context.md"
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "changed workspace succeeds" 0 "$rc" "$out"
assert_exit "changed workspace published a second archive" 2 "$(count_archives "$target")" "$out"

# Dedup must never mean "no backup": with the same content but every archive expired,
# the hook has to publish again rather than trust the stored fingerprint.
sleep 1
rm -f "$target"/nase-backup-*.zip
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "empty target re-publishes despite matching fingerprint" 0 "$rc" "$out"
assert_exit "empty target regained an archive" 1 "$(count_archives "$target")" "$out"

# --- retention: a count clause bounds what a single day can leave behind ---------------
repo="$fixture/retention-repo"
target="$fixture/retention-backups"
make_repo "$repo"
mkdir -p "$target"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf 'backup_retention: days:30,count:2\n' > "$repo/workspace/config.md"
today=$(date +%Y%m%d)
for stamp in 000001 000002 000003 000004; do
  printf 'placeholder\n' > "$target/nase-backup-${today}-${stamp}.zip"
done
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "combined retention run succeeds" 0 "$rc" "$out"
assert_exit "count clause caps same-day archives" 2 "$(count_archives "$target")" "$out"

# An unparsable clause must not silently disable retention.
repo="$fixture/retention-invalid-repo"
target="$fixture/retention-invalid-backups"
make_repo "$repo"
mkdir -p "$target"
printf 'backup-target=%s\n' "$target" > "$repo/.local-paths"
printf 'backup_retention: weeks:4\n' > "$repo/workspace/config.md"
out=$(cd "$repo" && PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" bash .claude/hooks/stop-backup.sh 2>&1)
rc=$?
assert_exit "unusable retention policy still backs up" 0 "$rc" "$out"
assert_contains "unusable retention policy warns" "$out" "invalid retention clause"
assert_contains "unusable retention policy falls back" "$out" "using default count:100"

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit "$fail"
