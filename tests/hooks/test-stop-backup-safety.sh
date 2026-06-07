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
  mkdir -p "$repo_path/.claude/hooks" "$repo_path/workspace"
  git -C "$repo_path" init -q
  cp "$HOOK" "$repo_path/.claude/hooks/stop-backup.sh"
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
: > "$out"
SH
chmod +x "$fakebin/zip"

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

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
exit "$fail"
