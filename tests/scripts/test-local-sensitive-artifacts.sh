#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

SCAN="$ROOT/tests/check-local-sensitive-artifacts.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

run_scan() {
  local root="$1" output="$2" rc_file="$3"
  shift 3
  set +e
  NASE_SENSITIVE_SCAN_ROOT="$root" bash "$SCAN" "$@" >"$output.out" 2>"$output.err"
  printf '%s\n' "$?" >"$rc_file"
  set -e
}

run_scan "$TMPROOT" "$TMPROOT/empty" "$TMPROOT/empty.rc"
assert_cmd "empty temp root passes" test "$(cat "$TMPROOT/empty.rc")" = "0"

fake_bearer_prefix='Authorization: Bearer '
fake_bearer="${fake_bearer_prefix}eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.fakePayload.fakeSignature # pragma: allowlist secret"

mkdir -p "$TMPROOT/.omc/sessions"
printf '%s\n' "$fake_bearer" >"$TMPROOT/.omc/sessions/request.log"

run_scan "$TMPROOT" "$TMPROOT/hit" "$TMPROOT/hit.rc"
assert_cmd ".omc bearer token fails scan" test "$(cat "$TMPROOT/hit.rc")" = "1"
assert_cmd ".omc path is reported" grep -q '.omc/sessions/request.log' "$TMPROOT/hit.err"

md_root="$TMPROOT/markdown-log-root"
mkdir -p "$md_root/workspace/logs"
printf '%s\n' "$fake_bearer" >"$md_root/workspace/logs/2026-06-10.md"

run_scan "$md_root" "$TMPROOT/md-log" "$TMPROOT/md-log.rc"
assert_cmd "markdown daily log bearer token fails scan" test "$(cat "$TMPROOT/md-log.rc")" = "1"
assert_cmd "markdown daily log path is reported" grep -q 'workspace/logs/2026-06-10.md' "$TMPROOT/md-log.err"

workspace_root="$TMPROOT/full-workspace-root"
mkdir -p "$workspace_root/workspace/scripts"
credential_key='ADMIN_PASSWORD'
printf '%s\n' "$credential_key = \"recovery_canary_4735\"" > "$workspace_root/workspace/scripts/recovery.py"

run_scan "$workspace_root" "$TMPROOT/full-workspace" "$TMPROOT/full-workspace.rc" --workspace
assert_cmd "full workspace scan catches credential assignments in scripts" \
  test "$(cat "$TMPROOT/full-workspace.rc")" = "1"
assert_cmd "full workspace scan reports only the affected path" \
  grep -q 'workspace/scripts/recovery.py' "$TMPROOT/full-workspace.err"
assert_cmd "full workspace scan never echoes the credential value" \
  bash -c '! grep -q recovery_canary_4735 "$1"' _ "$TMPROOT/full-workspace.err"

unreadable_root="$TMPROOT/unreadable-workspace-root"
mkdir -p "$unreadable_root/workspace"
printf 'safe\n' > "$unreadable_root/workspace/unreadable.txt"
chmod 000 "$unreadable_root/workspace/unreadable.txt"
if [[ ! -r "$unreadable_root/workspace/unreadable.txt" ]]; then
  run_scan "$unreadable_root" "$TMPROOT/unreadable-workspace" "$TMPROOT/unreadable-workspace.rc" --workspace
  assert_cmd "unreadable workspace file fails closed" \
    test "$(cat "$TMPROOT/unreadable-workspace.rc")" = "1"
  assert_cmd "unreadable workspace path is reported" \
    grep -q 'workspace/unreadable.txt' "$TMPROOT/unreadable-workspace.err"
fi
chmod 600 "$unreadable_root/workspace/unreadable.txt"

unreadable_dir_root="$TMPROOT/unreadable-directory-root"
mkdir -p "$unreadable_dir_root/workspace/private"
printf '%s\n' "$credential_key = \"directory_canary_1842\"" \
  > "$unreadable_dir_root/workspace/private/credential.txt"
chmod 000 "$unreadable_dir_root/workspace/private"
if [[ ! -r "$unreadable_dir_root/workspace/private" ]]; then
  run_scan "$unreadable_dir_root" "$TMPROOT/unreadable-directory" "$TMPROOT/unreadable-directory.rc" --workspace
  assert_cmd "unreadable workspace directory fails closed" \
    test "$(cat "$TMPROOT/unreadable-directory.rc")" = "1"
  assert_cmd "unreadable workspace directory is reported" \
    grep -q 'workspace/private' "$TMPROOT/unreadable-directory.err"
fi
chmod 700 "$unreadable_dir_root/workspace/private"

manifest_root="$TMPROOT/unreadable-manifest-root"
mkdir -p "$manifest_root/snapshot/private"
printf 'safe\n' > "$manifest_root/snapshot/private/file.txt"
chmod 000 "$manifest_root/snapshot/private"
if [[ ! -r "$manifest_root/snapshot/private" ]]; then
  run_scan "$manifest_root" "$TMPROOT/unreadable-manifest" "$TMPROOT/unreadable-manifest.rc" \
    --manifest "$manifest_root/snapshot" "$manifest_root/manifest.json"
  assert_cmd "unreadable snapshot directory fails manifest closed" \
    test "$(cat "$TMPROOT/unreadable-manifest.rc")" = "1"
  assert_cmd "unreadable snapshot manifest failure is explicit" \
    grep -q 'manifest coverage is incomplete' "$TMPROOT/unreadable-manifest.err"
fi
chmod 700 "$manifest_root/snapshot/private"

symlink_root="$TMPROOT/symlink-workspace-root"
mkdir -p "$symlink_root/workspace" "$symlink_root/outside"
printf 'outside marker\n' > "$symlink_root/outside/credential.txt"
ln -s "$symlink_root/outside/credential.txt" "$symlink_root/workspace/external-link.txt"
run_scan "$symlink_root" "$TMPROOT/symlink-workspace" "$TMPROOT/symlink-workspace.rc" --workspace
assert_cmd "workspace symlink fails closed" test "$(cat "$TMPROOT/symlink-workspace.rc")" = "1"
assert_cmd "workspace symlink path is reported" \
  grep -q 'workspace/external-link.txt' "$TMPROOT/symlink-workspace.err"

root_symlink_root="$TMPROOT/root-symlink-workspace-root"
mkdir -p "$root_symlink_root/outside-workspace"
ln -s "$root_symlink_root/outside-workspace" "$root_symlink_root/workspace"
run_scan "$root_symlink_root" "$TMPROOT/root-symlink-workspace" "$TMPROOT/root-symlink-workspace.rc" --workspace
assert_cmd "workspace root symlink fails closed" \
  test "$(cat "$TMPROOT/root-symlink-workspace.rc")" = "1"
assert_cmd "workspace root symlink path is reported" \
  grep -q '^workspace$' "$TMPROOT/root-symlink-workspace.err"

redacted_path_root="$TMPROOT/redacted-path-root"
mkdir -p "$redacted_path_root/workspace"
sensitive_name="${credential_key}=filename_canary_8391.txt"
printf '%s\n' "$credential_key = \"content_canary_8391\"" \
  > "$redacted_path_root/workspace/$sensitive_name"
run_scan "$redacted_path_root" "$TMPROOT/redacted-path" "$TMPROOT/redacted-path.rc" --workspace
assert_cmd "secret-bearing filename still fails scan" test "$(cat "$TMPROOT/redacted-path.rc")" = "1"
assert_cmd "secret-bearing filename is redacted" \
  grep -q '<redacted-path:' "$TMPROOT/redacted-path.err"
assert_cmd "secret-bearing filename value is never echoed" \
  bash -c '! grep -q filename_canary_8391 "$1"' _ "$TMPROOT/redacted-path.err"

# --- workspace/tmp is out of scope, matching the manifest and the archive ---------------
# `stop-backup.sh` archives with `-x!tmp`, so a scratch file must not be able to block a
# backup that could never have contained it. The identical line under a scanned directory
# must still fail, so this proves scope and not a weakened detector.
tmp_scope_root="$TMPROOT/tmp-scope-root"
mkdir -p "$tmp_scope_root/workspace/tmp/nested" "$tmp_scope_root/workspace/logs"
tmp_credential='DB_PASSWORD = "tmp_scope_canary_5512"'  # pragma: allowlist secret
printf '%s\n' "$tmp_credential" > "$tmp_scope_root/workspace/tmp/draft.md"
printf '%s\n' "$tmp_credential" > "$tmp_scope_root/workspace/tmp/nested/deep.md"

run_scan "$tmp_scope_root" "$TMPROOT/tmp-scope" "$TMPROOT/tmp-scope.rc" --workspace
assert_cmd "credential under workspace/tmp does not block the scan" \
  test "$(cat "$TMPROOT/tmp-scope.rc")" = "0"

printf '%s\n' "$tmp_credential" > "$tmp_scope_root/workspace/logs/2026-08-08.md"
run_scan "$tmp_scope_root" "$TMPROOT/tmp-scope-2" "$TMPROOT/tmp-scope-2.rc" --workspace
assert_cmd "the same credential outside tmp still fails" \
  test "$(cat "$TMPROOT/tmp-scope-2.rc")" = "1"
assert_cmd "only the non-tmp path is reported" \
  grep -q 'workspace/logs/2026-08-08.md' "$TMPROOT/tmp-scope-2.err"
assert_cmd "tmp path is never reported" \
  bash -c '! grep -q "workspace/tmp/" "$1"' _ "$TMPROOT/tmp-scope-2.err"

# a directory merely NAMED tmp deeper in the tree is still scanned
nested_tmp_root="$TMPROOT/nested-tmp-root"
mkdir -p "$nested_tmp_root/workspace/kb/tmp"
printf '%s\n' "$tmp_credential" > "$nested_tmp_root/workspace/kb/tmp/notes.md"
run_scan "$nested_tmp_root" "$TMPROOT/nested-tmp" "$TMPROOT/nested-tmp.rc" --workspace
assert_cmd "a nested directory named tmp is still scanned" \
  test "$(cat "$TMPROOT/nested-tmp.rc")" = "1"

# --- reviewed allowlist: acknowledges one line, never a file or a pattern ----------------
allow_root="$TMPROOT/allowlist-root"
mkdir -p "$allow_root/workspace/kb"
doc="$allow_root/workspace/kb/runbook.md"
prose_line='Docs example: set the admin password = prose_seed before the first boot.'
real_line='SERVICE_PASSWORD = "allowlist_canary_7781"'  # pragma: allowlist secret
printf '%s\n' "$prose_line" > "$doc"
prose_hash=$(printf '%s' "$prose_line" | shasum -a 256 | cut -d' ' -f1)

run_scan "$allow_root" "$TMPROOT/allow-before" "$TMPROOT/allow-before.rc" --workspace
assert_cmd "prose line fails before it is acknowledged" \
  test "$(cat "$TMPROOT/allow-before.rc")" = "1"

printf '%s  kb/runbook.md  # reviewed prose\n' "$prose_hash" \
  > "$allow_root/workspace/.secret-scan-allowlist"
run_scan "$allow_root" "$TMPROOT/allow-after" "$TMPROOT/allow-after.rc" --workspace
assert_cmd "acknowledged line passes" test "$(cat "$TMPROOT/allow-after.rc")" = "0"

# the scan must RESUME past a skipped line, not stop at the first hit
printf '%s\n' "$real_line" >> "$doc"
run_scan "$allow_root" "$TMPROOT/allow-resume" "$TMPROOT/allow-resume.rc" --workspace
assert_cmd "a real credential later in an acknowledged file still fails" \
  test "$(cat "$TMPROOT/allow-resume.rc")" = "1"
assert_cmd "the resumed hit reports the later line number" \
  grep -q 'workspace/kb/runbook.md:2' "$TMPROOT/allow-resume.err"
assert_cmd "the resumed hit never echoes the credential value" \
  bash -c '! grep -q allowlist_canary_7781 "$1"' _ "$TMPROOT/allow-resume.err"

# content-pinned: editing the acknowledged line re-opens the finding
printf '%s\n' "$prose_line EDITED" > "$doc"
run_scan "$allow_root" "$TMPROOT/allow-edited" "$TMPROOT/allow-edited.rc" --workspace
assert_cmd "editing an acknowledged line re-opens the finding" \
  test "$(cat "$TMPROOT/allow-edited.rc")" = "1"

# an entry never absolves the same content in a different file
printf '%s\n' "$prose_line" > "$doc"
printf '%s\n' "$prose_line" > "$allow_root/workspace/kb/other.md"
run_scan "$allow_root" "$TMPROOT/allow-other" "$TMPROOT/allow-other.rc" --workspace
assert_cmd "an entry does not absolve the same line in another file" \
  test "$(cat "$TMPROOT/allow-other.rc")" = "1"
assert_cmd "only the unacknowledged file is reported" \
  grep -q 'workspace/kb/other.md' "$TMPROOT/allow-other.err"
rm "$allow_root/workspace/kb/other.md"

# a stale entry warns but does not fail
printf '%s  kb/gone.md  # target removed\n' "$prose_hash" \
  >> "$allow_root/workspace/.secret-scan-allowlist"
run_scan "$allow_root" "$TMPROOT/allow-stale" "$TMPROOT/allow-stale.rc" --workspace
assert_cmd "a stale allowlist entry does not fail the scan" \
  test "$(cat "$TMPROOT/allow-stale.rc")" = "0"
assert_cmd "a stale allowlist entry is reported" \
  grep -q 'WARNING:.*matched nothing' "$TMPROOT/allow-stale.err"

# malformed allowlists fail closed
for bad in 'notahash  kb/runbook.md' \
           "$prose_hash" \
           "$prose_hash  ../escape.md" \
           "$prose_hash  kb/*.md" \
           "$prose_hash  /abs/path.md"; do
  printf '%s\n' "$bad" > "$allow_root/workspace/.secret-scan-allowlist"
  run_scan "$allow_root" "$TMPROOT/allow-bad" "$TMPROOT/allow-bad.rc" --workspace
  assert_cmd "malformed allowlist entry fails closed: ${bad:0:24}" \
    test "$(cat "$TMPROOT/allow-bad.rc")" = "1"
done

# --- bracketed redaction markers are placeholders, real values are not -------------------
marker_root="$TMPROOT/marker-root"
mkdir -p "$marker_root/workspace/kb"
{
  printf 'The redactor emits `Password=[REDACTED]`, `token=[JWT_REDACTED]`.\n'
  printf 'Bare form: password=[REDACTED]\n'
} > "$marker_root/workspace/kb/redaction.md"
run_scan "$marker_root" "$TMPROOT/marker" "$TMPROOT/marker.rc" --workspace
assert_cmd "bracketed redaction markers are not credentials" \
  test "$(cat "$TMPROOT/marker.rc")" = "0"

printf 'password=[NotAMarker_9182]\n' > "$marker_root/workspace/kb/redaction.md"
run_scan "$marker_root" "$TMPROOT/marker-neg" "$TMPROOT/marker-neg.rc" --workspace
assert_cmd "a bracketed value that is not a redaction marker still fails" \
  test "$(cat "$TMPROOT/marker-neg.rc")" = "1"

# --- the archive scan honours the SAME allowlist, read from inside the zip --------------
# The published archive is scanned separately from the live workspace, and its members are
# already workspace-relative. Before this was wired up, an acknowledged line passed the
# workspace gate and then failed the archive gate, so no backup could be produced.
archive_root="$TMPROOT/archive-root"
mkdir -p "$archive_root/workspace/kb"
printf '%s\n' "$prose_line" > "$archive_root/workspace/kb/runbook.md"
printf '%s  kb/runbook.md  # reviewed prose\n' "$prose_hash" \
  > "$archive_root/workspace/.secret-scan-allowlist"

build_archive() {
  local src="$1" zip_path="$2" manifest="$3"
  rm -f "$zip_path"
  ( cd "$src" && zip -qry "$zip_path" . ) || return 1
  bash "$SCAN" --manifest "$src" "$manifest"
}

if command -v zip >/dev/null 2>&1; then
  build_archive "$archive_root/workspace" "$TMPROOT/ok.zip" "$TMPROOT/ok-manifest.json"
  set +e
  bash "$SCAN" --archive "$TMPROOT/ok.zip" "$TMPROOT/ok-manifest.json" \
    >"$TMPROOT/archive-ok.out" 2>"$TMPROOT/archive-ok.err"
  printf '%s\n' "$?" >"$TMPROOT/archive-ok.rc"
  set -e
  assert_cmd "archive scan honours the archived allowlist" \
    test "$(cat "$TMPROOT/archive-ok.rc")" = "0"

  printf '%s\n' "$real_line" >> "$archive_root/workspace/kb/runbook.md"
  build_archive "$archive_root/workspace" "$TMPROOT/bad.zip" "$TMPROOT/bad-manifest.json"
  set +e
  bash "$SCAN" --archive "$TMPROOT/bad.zip" "$TMPROOT/bad-manifest.json" \
    >"$TMPROOT/archive-bad.out" 2>"$TMPROOT/archive-bad.err"
  printf '%s\n' "$?" >"$TMPROOT/archive-bad.rc"
  set -e
  assert_cmd "archive scan still catches a real credential past an acknowledged line" \
    test "$(cat "$TMPROOT/archive-bad.rc")" = "1"
  assert_cmd "archive scan never echoes the credential value" \
    bash -c '! grep -q allowlist_canary_7781 "$1"' _ "$TMPROOT/archive-bad.err"

  printf '%s\n' "$prose_line" > "$archive_root/workspace/kb/runbook.md"
  printf 'notahash  kb/runbook.md\n' > "$archive_root/workspace/.secret-scan-allowlist"
  build_archive "$archive_root/workspace" "$TMPROOT/malformed.zip" \
    "$TMPROOT/malformed-manifest.json"
  set +e
  bash "$SCAN" --archive "$TMPROOT/malformed.zip" "$TMPROOT/malformed-manifest.json" \
    >"$TMPROOT/archive-malformed.out" 2>"$TMPROOT/archive-malformed.err"
  printf '%s\n' "$?" >"$TMPROOT/archive-malformed.rc"
  set -e
  assert_cmd "a malformed archived allowlist fails the archive scan closed" \
    test "$(cat "$TMPROOT/archive-malformed.rc")" = "1"
else
  printf 'SKIP  archive allowlist tests (zip not installed)\n'
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nlocal-sensitive-artifacts tests passed.\n'
  exit 0
fi

printf '\n%d local-sensitive-artifacts assertion(s) failed.\n' "$failures" >&2
exit 1
