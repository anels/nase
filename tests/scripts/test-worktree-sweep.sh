#!/usr/bin/env bash
# Regression tests for .claude/scripts/worktree-sweep.py.
#
# The sweep decides what is safe to delete permanently, so these tests pin the two
# directions that matter: a spent worktree is removed, and everything that could still hold
# work is kept. `gh` is a PATH shim keyed by commit SHA, so no network is involved.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/worktree-sweep.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0

report() {
  local ok="$1" name="$2" detail="${3:-}"
  if [[ "$ok" -eq 0 ]]; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s%s\n' "$name" "${detail:+: $detail}" >&2
    failures=$((failures + 1))
  fi
}

assert_jq() {
  local name="$1" file="$2" filter="$3"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    report 0 "$name"
  else
    report 1 "$name" "$(jq -c '[.items[] | {name, category, reason}]' "$file" 2>/dev/null)"
  fi
}

assert_exists() {
  local name="$1" path="$2"
  if [[ -e "$path" ]]; then report 0 "$name"; else report 1 "$name" "missing $path"; fi
}

assert_absent() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then report 0 "$name"; else report 1 "$name" "still present $path"; fi
}

g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

SHIM="$TMPDIR_TEST/shim"
GH_STATE="$TMPDIR_TEST/gh-state"
mkdir -p "$SHIM" "$GH_STATE"
cat > "$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
# Fake `gh api repos/o/r/commits/<sha>/pulls`. State lives in $GH_STATE/<sha>.json, or
# $GH_STATE/<sha>.missing for a commit GitHub has never seen.
sha=$(printf '%s\n' "$@" | sed -n 's#.*commits/\([0-9a-f]*\)/pulls#\1#p')
if [[ -f "$GH_STATE/$sha.missing" ]]; then
  echo 'gh: No commit found for SHA: '"$sha"' (HTTP 422)' >&2
  exit 1
fi
if [[ -f "$GH_STATE/$sha.json" ]]; then cat "$GH_STATE/$sha.json"; else echo '[]'; fi
EOF
chmod +x "$SHIM/gh"
export GH_STATE
export PATH="$SHIM:$PATH"

REPO="$TMPDIR_TEST/repo"
WT="$TMPDIR_TEST/worktrees"
mkdir -p "$REPO" "$WT"
g -C "$REPO" init -q -b main
g -C "$REPO" remote add origin https://github.com/acme/widget.git
g -C "$REPO" commit -q --allow-empty -m base

# add_wt <dir name> <branch> -> prints HEAD sha, one commit past base so each is distinct
add_wt() {
  g -C "$REPO" worktree add -q -b "$2" "$WT/$1" main
  g -C "$WT/$1" commit -q --allow-empty -m "$2"
  g -C "$WT/$1" rev-parse HEAD
}

merged_json='[{"number":7,"state":"closed","merged_at":"2026-01-01T00:00:00Z"}]'
open_json='[{"number":8,"state":"open","merged_at":null}]'
closed_json='[{"number":9,"state":"closed","merged_at":null}]'

sha=$(add_wt merged br-merged);       printf '%s' "$merged_json" > "$GH_STATE/$sha.json"
sha=$(add_wt open br-open);           printf '%s' "$open_json" > "$GH_STATE/$sha.json"
sha=$(add_wt dirty br-dirty);         printf '%s' "$merged_json" > "$GH_STATE/$sha.json"
echo wip > "$WT/dirty/scratch.txt"
sha=$(add_wt unpushed br-unpushed);   : > "$GH_STATE/$sha.missing"
sha=$(add_wt nopr br-nopr);           printf '%s' "$closed_json" > "$GH_STATE/$sha.json"
sha=$(add_wt locked br-locked);       printf '%s' "$merged_json" > "$GH_STATE/$sha.json"
g -C "$REPO" worktree lock "$WT/locked"
sha=$(add_wt .quar.nase-cleanup-abc br-quar); printf '%s' "$merged_json" > "$GH_STATE/$sha.json"
g -C "$REPO" worktree lock "$WT/.quar.nase-cleanup-abc"
sha=$(add_wt moved br-moved);         printf '%s' "$merged_json" > "$GH_STATE/$sha.json"
mkdir "$WT/not-a-worktree"

OUT="$TMPDIR_TEST/report.json"
python3 -I "$SCRIPT" scan --root "$WT" --out "$OUT" > "$TMPDIR_TEST/scan.txt"

assert_jq "merged PR is removable" "$OUT" '.items[] | select(.name=="merged") | .category=="removable"'
assert_jq "locked quarantine of a merged PR is removable" "$OUT" '.items[] | select(.name==".quar.nase-cleanup-abc") | .category=="removable"'
assert_jq "open PR is kept" "$OUT" '.items[] | select(.name=="open") | .category=="keep-open-pr"'
assert_jq "untracked file keeps a merged worktree" "$OUT" '.items[] | select(.name=="dirty") | .category=="keep-dirty"'
assert_jq "commit GitHub never saw is unpushed" "$OUT" '.items[] | select(.name=="unpushed") | .category=="keep-unpushed"'
assert_jq "closed unmerged PR is not removable" "$OUT" '.items[] | select(.name=="nopr") | .category=="keep-no-pr"'
assert_jq "foreign lock is kept" "$OUT" '.items[] | select(.name=="locked") | .category=="keep-locked"'
assert_jq "plain directory is unreadable, never removable" "$OUT" '.items[] | select(.name=="not-a-worktree") | .category=="keep-unreadable"'
assert_jq "only the two merged worktrees plus moved are removable" "$OUT" '[.items[] | select(.category=="removable") | .name] | sort == [".quar.nase-cleanup-abc","merged","moved"]'

# A session commits into a removable worktree between scan and apply.
g -C "$WT/moved" commit -q --allow-empty -m late

python3 -I "$SCRIPT" apply --root "$WT" --report "$OUT" > "$TMPDIR_TEST/apply.txt"

assert_absent "apply removes the merged worktree" "$WT/merged"
assert_absent "apply unlocks and removes the quarantine" "$WT/.quar.nase-cleanup-abc"
assert_exists "apply keeps a worktree whose HEAD moved after scan" "$WT/moved"
assert_exists "apply keeps the open-PR worktree" "$WT/open"
assert_exists "apply keeps the dirty worktree and its file" "$WT/dirty/scratch.txt"
assert_exists "apply keeps the unpushed worktree" "$WT/unpushed"
assert_exists "apply keeps the foreign-locked worktree" "$WT/locked"
assert_exists "apply keeps the plain directory" "$WT/not-a-worktree"

if grep -q 'SKIP moved - HEAD moved since scan' "$TMPDIR_TEST/apply.txt"; then
  report 0 "apply names why it skipped the moved worktree"
else
  report 1 "apply names why it skipped the moved worktree" "$(cat "$TMPDIR_TEST/apply.txt")"
fi

if g -C "$REPO" worktree list --porcelain | grep -q "worktree .*/merged$"; then
  report 1 "git no longer lists the removed worktree"
else
  report 0 "git no longer lists the removed worktree"
fi

# A forged report must not turn into deletion outside the root.
OUTSIDE="$TMPDIR_TEST/outside"
mkdir -p "$OUTSIDE"
jq --arg p "$OUTSIDE" '.items = [{name:"outside",path:$p,repo:"x",head:"x",category:"removable"}]' "$OUT" > "$TMPDIR_TEST/forged.json"
python3 -I "$SCRIPT" apply --root "$WT" --report "$TMPDIR_TEST/forged.json" > "$TMPDIR_TEST/forged.txt"
assert_exists "apply refuses a path outside the root" "$OUTSIDE"

# A malformed item is skipped, not a traceback that aborts the rest of the report.
jq '.items=[{name:"nopath",category:"removable"}]' "$OUT" > "$TMPDIR_TEST/nopath.json"
python3 -I "$SCRIPT" apply --root "$WT" --report "$TMPDIR_TEST/nopath.json" > "$TMPDIR_TEST/nopath.txt"
if grep -q 'SKIP nopath - item has no path' "$TMPDIR_TEST/nopath.txt"; then
  report 0 "apply skips a report item without a path"
else
  report 1 "apply skips a report item without a path" "$(cat "$TMPDIR_TEST/nopath.txt")"
fi

# A report whose own root points outside the sweep root must not widen the deletion area.
set +e
python3 -I "$SCRIPT" apply --root "$OUTSIDE" --report "$OUT" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
  report 0 "apply refuses a report whose root does not match --root"
else
  report 1 "apply refuses a report whose root does not match --root" "exit $rc"
fi

# The wrap-up predicate reads `removable=0` off the summary, so the key is always present.
mkdir -p "$TMPDIR_TEST/empty-root"
python3 -I "$SCRIPT" scan --root "$TMPDIR_TEST/empty-root" --out "$TMPDIR_TEST/empty.json" > "$TMPDIR_TEST/empty.txt"
if grep -q 'removable=0' "$TMPDIR_TEST/empty.txt"; then
  report 0 "empty root prints removable=0 in the summary"
else
  report 1 "empty root prints removable=0 in the summary" "$(cat "$TMPDIR_TEST/empty.txt")"
fi
assert_jq "empty root reports removable 0 in the report" "$TMPDIR_TEST/empty.json" '.counts.removable==0'

# The directory the scan runs from is never removable. Precedence matters here: `open`
# would otherwise be kept only because its PR is open.
(
  cd "$WT/open" || exit 1
  python3 -I "$SCRIPT" scan --root "$WT" --out "$TMPDIR_TEST/inuse.json" > "$TMPDIR_TEST/inuse.txt"
)
assert_jq "worktree containing the scanning process is kept in use" "$TMPDIR_TEST/inuse.json" \
  '.items[] | select(.name=="open") | .category=="keep-in-use"'

set +e
python3 -I "$SCRIPT" apply --report "$TMPDIR_TEST/missing.json" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
  report 0 "apply exits 2 on an unreadable report"
else
  report 1 "apply exits 2 on an unreadable report" "exit $rc"
fi

if [[ "$failures" -gt 0 ]]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi
