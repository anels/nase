#!/usr/bin/env bash
# Regression tests for .claude/scripts/git-commit-context.py.
#
# Covers the two properties /nase:improve-commit-message depends on: merge/initial-commit
# detection, and fail-closed publish state (a failed remote refresh must never read as
# "not pushed", because that is what authorizes an unattended amend).

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/git-commit-context.py"
TMPROOT=$(mktemp -d)
failures=0
source "$ROOT/tests/lib/assert.sh"
trap 'rm -rf "$TMPROOT"' EXIT

new_repo() {
  local dir="$1"
  git init --quiet -b main "$dir"
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
}

context() {
  python3 "$SCRIPT" --repo "$1" "${@:2}"
}

field() {
  printf '%s' "$1" | jq -r "$2"
}

# --- initial commit, no remotes ----------------------------------------------
REPO="$TMPROOT/repo"
new_repo "$REPO"
printf 'one\n' > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "feat: first" -m "body line"
out=$(context "$REPO")
assert_cmd "initial commit reports zero parents" test "$(field "$out" .parent_count)" = 0
assert_cmd "initial commit is flagged" test "$(field "$out" .is_initial_commit)" = true
assert_cmd "initial commit is not a merge" test "$(field "$out" .is_merge)" = false
assert_cmd "subject is split from the body" test "$(field "$out" .subject)" = "feat: first"
assert_cmd "body is split from the subject" test "$(field "$out" .body)" = "body line"
assert_cmd "no remotes reads as not-pushed" test "$(field "$out" .push_state)" = not-pushed
assert_cmd "no remotes is not published" test "$(field "$out" .is_pushed)" = false

# --- second commit ------------------------------------------------------------
printf 'two\n' > "$REPO/b.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "feat: second"
out=$(context "$REPO")
assert_cmd "second commit is not initial" test "$(field "$out" .is_initial_commit)" = false
assert_cmd "second commit has one parent" test "$(field "$out" .parent_count)" = 1

# --- merge commit -------------------------------------------------------------
git -C "$REPO" checkout --quiet -b side HEAD~1
printf 'side\n' > "$REPO/c.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "feat: side"
git -C "$REPO" checkout --quiet main
git -C "$REPO" merge --quiet --no-ff -m "merge side" side
out=$(context "$REPO")
assert_cmd "merge commit is flagged" test "$(field "$out" .is_merge)" = true
assert_cmd "merge commit reports two parents" test "$(field "$out" .parent_count)" = 2

# --- publish state against a working remote -----------------------------------
REMOTE="$TMPROOT/origin.git"
git init --quiet --bare "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push --quiet -u origin main
out=$(context "$REPO")
assert_cmd "pushed HEAD reads as pushed" test "$(field "$out" .push_state)" = pushed
assert_cmd "pushed HEAD is published" test "$(field "$out" .is_pushed)" = true

printf 'three\n' > "$REPO/d.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "feat: unpushed"
out=$(context "$REPO")
assert_cmd "unpushed HEAD with a live remote reads as not-pushed" \
  test "$(field "$out" .push_state)" = not-pushed
assert_cmd "unpushed HEAD is not published" test "$(field "$out" .is_pushed)" = false

# --- fail-closed: a refresh that fails must not read as not-pushed ------------
BROKEN="$TMPROOT/broken"
new_repo "$BROKEN"
printf 'x\n' > "$BROKEN/a.txt"
git -C "$BROKEN" add -A
git -C "$BROKEN" commit --quiet -m "feat: only"
git -C "$BROKEN" remote add origin "$TMPROOT/does-not-exist.git"
out=$(context "$BROKEN")
assert_cmd "failed remote refresh reads as unknown" test "$(field "$out" .push_state)" = unknown
assert_cmd "unknown publish state fails closed to published" test "$(field "$out" .is_pushed)" = true

out=$(context "$BROKEN" --no-fetch)
assert_cmd "--no-fetch cannot establish freshness, so state stays unknown" \
  test "$(field "$out" .push_state)" = unknown
assert_cmd "--no-fetch never authorizes an unattended amend" \
  test "$(field "$out" .is_pushed)" = true
assert_cmd "--no-fetch is recorded" test "$(field "$out" .fetched)" = false

# A containment query that errors must not read as "not pushed" either. Only the
# subprocess layer can produce that state, so drive push_state() directly.
python3 - "$SCRIPT" "$REPO" <<'PY'
import importlib.util
import subprocess
import sys

spec = importlib.util.spec_from_file_location("git_commit_context", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

real_git = module.git


def failing_contains(repo, *args):
    if args[:1] == ("branch",):
        return subprocess.CompletedProcess(args, 128, "", "fatal: malformed object name")
    return real_git(repo, *args)


module.git = failing_contains
state = module.push_state(module.Path(sys.argv[2]), fetch=True)
module.git = real_git
if state["push_state"] != "unknown" or state["is_pushed"] is not True:
    raise SystemExit(f"failed containment query read as {state['push_state']!r}")
PY
assert_cmd "a failed containment query fails closed to unknown" test "$?" = 0

# A repo with no remotes has nothing to be published to, so skipping the refresh is safe.
NOREMOTE="$TMPROOT/noremote"
new_repo "$NOREMOTE"
printf 'x\n' > "$NOREMOTE/a.txt"
git -C "$NOREMOTE" add -A
git -C "$NOREMOTE" commit --quiet -m "feat: local only"
out=$(context "$NOREMOTE" --no-fetch)
assert_cmd "--no-fetch on a remoteless repo stays not-pushed" \
  test "$(field "$out" .push_state)" = not-pushed

# --- commitlint discovery -----------------------------------------------------
out=$(context "$REPO" --no-fetch)
assert_cmd "repo without commitlint config reports none" \
  test "$(field "$out" .commitlint.found)" = false

printf '%s\n' '{"extends":["@commitlint/config-conventional"],"rules":{"header-max-length":[2,"always",100],"type-enum":[2,"always",["feat","fix"]],"subject-case":[0],"subject-full-stop":[2,"never","."]}}' \
  > "$REPO/.commitlintrc.json"
printf 'module.exports = {};\n' > "$REPO/commitlint.config.js"
out=$(context "$REPO" --no-fetch)
assert_cmd "commitlint config is found" test "$(field "$out" .commitlint.found)" = true
assert_cmd "JSON config is parsed" \
  test "$(field "$out" '.commitlint.candidates[] | select(.file == ".commitlintrc.json") | .parsed')" = true
assert_cmd "header-max-length is extracted" \
  test "$(field "$out" '.commitlint.candidates[] | select(.file == ".commitlintrc.json") | .rules["header-max-length"][2]')" = 100
assert_cmd "type-enum is extracted" \
  test "$(field "$out" '.commitlint.candidates[] | select(.file == ".commitlintrc.json") | .rules["type-enum"][2] | join(",")')" = "feat,fix"
assert_cmd "subject-case level is preserved" \
  test "$(field "$out" '.commitlint.candidates[] | select(.file == ".commitlintrc.json") | .rules["subject-case"][0]')" = 0
assert_cmd "extends is surfaced" \
  test "$(field "$out" '.commitlint.candidates[] | select(.file == ".commitlintrc.json") | .extends[0]')" = "@commitlint/config-conventional"
assert_cmd "non-JSON candidate is listed unparsed, not silently dropped" \
  test "$(field "$out" '.commitlint.candidates[] | select(.file == "commitlint.config.js") | .parsed')" = false

printf 'not json\n' > "$REPO/.commitlintrc.json"
out=$(context "$REPO" --no-fetch)
assert_cmd "unparseable JSON config is reported, not fatal" \
  test "$(field "$out" '.commitlint.candidates[] | select(.file == ".commitlintrc.json") | .parsed')" = false

if [[ "$failures" -eq 0 ]]; then
  printf '\ngit-commit-context tests passed.\n'
  exit 0
fi

printf '\n%d git-commit-context assertion(s) failed.\n' "$failures" >&2
exit "$failures"
