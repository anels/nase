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

if [[ "$failures" -eq 0 ]]; then
  printf '\nlocal-sensitive-artifacts tests passed.\n'
  exit 0
fi

printf '\n%d local-sensitive-artifacts assertion(s) failed.\n' "$failures" >&2
exit 1
