#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/pr-github-helper.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

parsed="$TMPDIR_TEST/parsed.json"
"$PYTHON_BIN" "$SCRIPT" parse "https://github.com/acme/widgets/pull/42/files" > "$parsed"
assert_cmd "parse GitHub URL" "$PYTHON_BIN" - "$parsed" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["owner"] == "acme"
assert data["repo"] == "widgets"
assert data["number"] == 42
assert data["repo_full_name"] == "acme/widgets"
PY

short="$TMPDIR_TEST/short.json"
"$PYTHON_BIN" "$SCRIPT" parse "77" --repo "acme/widgets" > "$short"
assert_cmd "parse number with repo hint" "$PYTHON_BIN" - "$short" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["number"] == 77
assert data["url"] == "https://github.com/acme/widgets/pull/77"
PY

assert_cmd "number without repo hint fails" bash -c '"$1" "$2" parse 77 >/dev/null 2>&1; test "$?" -eq 2' _ "$PYTHON_BIN" "$SCRIPT"

plan="$TMPDIR_TEST/plan.json"
"$PYTHON_BIN" "$SCRIPT" commands "acme/widgets#42" --variant full > "$plan"
assert_cmd "command plan includes full metadata fields" "$PYTHON_BIN" - "$plan" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
metadata = data["metadata"]
assert metadata[:4] == ["gh", "pr", "view", "42"]
fields = metadata[-1].split(",")
assert "commits" in fields
assert "createdAt" in fields
assert "headRefOid" in fields
assert "reviewDecision" in fields
assert "isDraft" in fields
assert data["review_threads"][0:3] == ["gh", "api", "graphql"]
assert "pageInfo" in data["review_threads"][-1]
PY

assert_cmd "size gate keeps its boundaries" "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

for metadata, total, mode, warned in (
    ({"additions": 50, "deletions": 25}, 75, "full", False),
    ({"additions": 1000, "deletions": 500}, 1500, "full", False),
    ({"additions": 1000, "deletions": 501}, 1501, "stat", True),
    ({"additions": 4000, "deletions": 1501}, 5501, "stat", True),
):
    result = module.size_gate(metadata, 1500, 1500)
    assert result["total_lines"] == total
    assert result["diff_mode"] == mode
    assert result["review_warning"] is warned
PY

mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/gh" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" > "$GH_ARGS_FILE"
printf '{"number":42,"additions":1,"deletions":2}\n'
SH
chmod +x "$TMPDIR_TEST/bin/gh"
metadata_out="$TMPDIR_TEST/metadata.json"
GH_ARGS_FILE="$TMPDIR_TEST/gh-args.txt" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" metadata "acme/widgets#42" --variant light > "$metadata_out"
assert_cmd "metadata command shells out to gh safely" "$PYTHON_BIN" - "$metadata_out" "$TMPDIR_TEST/gh-args.txt" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
args = open(sys.argv[2], encoding="utf-8").read()
assert data["number"] == 42
assert "pr view 42 --repo acme/widgets --json" in args
assert "headRefOid" in args
PY

cat > "$TMPDIR_TEST/bin/gh" <<'SH'
#!/usr/bin/env sh
args="$*"
case "$args" in
  *threadId=T1*commentCursor=COMMENT_PAGE_2*)
    cat <<'JSON'
{"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":"COMMENT_END"},"nodes":[{"databaseId":101,"body":"decline","author":{"login":"alice"},"createdAt":"2026-06-01T00:01:00Z"}]}}}}
JSON
    ;;
  *threadCursor=THREAD_PAGE_2*)
    cat <<'JSON'
{"data":{"repository":{"pullRequest":{"headRefName":"feature/pr","baseRefName":"main","headRepository":{"nameWithOwner":"acme/widgets"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":"THREAD_END"},"nodes":[{"id":"T2","isResolved":true,"path":"src/b.ts","line":20,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":"C2"},"nodes":[{"databaseId":200,"body":"done","author":{"login":"bob"},"createdAt":"2026-06-01T00:02:00Z"}]}},{"id":"T3","isResolved":false,"path":"src/c.ts","line":30,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":"C3"},"nodes":[{"databaseId":300,"body":"still broken","author":{"login":"carol"},"createdAt":"2026-06-01T00:03:00Z"}]}}]}}}}}
JSON
    ;;
  *)
    cat <<'JSON'
{"data":{"repository":{"pullRequest":{"headRefName":"feature/pr","baseRefName":"main","headRepository":{"nameWithOwner":"acme/widgets"},"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"THREAD_PAGE_2"},"nodes":[{"id":"T1","isResolved":false,"path":"src/a.ts","line":10,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"COMMENT_PAGE_2"},"nodes":[{"databaseId":100,"body":"fix this","author":{"login":"bot"},"createdAt":"2026-06-01T00:00:00Z"}]}}]}}}}}
JSON
    ;;
esac
SH
chmod +x "$TMPDIR_TEST/bin/gh"
threads_out="$TMPDIR_TEST/threads.json"
PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" review-threads "acme/widgets#42" --unresolved-only > "$threads_out"
assert_cmd "review-threads paginates and filters unresolved threads" "$PYTHON_BIN" - "$threads_out" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["headRefName"] == "feature/pr"
assert data["baseRefName"] == "main"
assert data["headRepository"]["nameWithOwner"] == "acme/widgets"
assert [thread["id"] for thread in data["threads"]] == ["T1", "T3"]
assert [comment["databaseId"] for comment in data["threads"][0]["comments"]["nodes"]] == [100, 101]
PY

repo="$TMPDIR_TEST/local-repo"
mkdir -p "$repo/src"
(
  cd "$repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name Test
  cat > src/a.ts <<'EOF'
export function value() {
  return "base";
}
EOF
  git add src/a.ts
  git commit -q -m "base"
  git branch -M main
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b feature/pr
  cat > src/a.ts <<'EOF'
export function value() {
  return "head";
}
EOF
  cat > src/c.ts <<'EOF'
export const c = 1;
EOF
  git add src/a.ts src/c.ts
  git commit -q -m "feature"
  git update-ref refs/remotes/origin/feature/pr HEAD
)
head_sha=$(git -C "$repo" rev-parse refs/remotes/origin/feature/pr)
mkdir -p "$TMPDIR_TEST/state"
cat > "$TMPDIR_TEST/state/prep-merge-acme-widgets-42-abort.json" <<JSON
{"branch_sha":"old","base_sha":"old","conflict_files":["src/a.ts"],"timestamp":"2026-06-01T00:00:00Z"}
JSON

cat > "$TMPDIR_TEST/bin/gh" <<'SH'
#!/usr/bin/env sh
args="$*"
case "$args" in
  *"pr view 42"*)
    cat <<JSON
{"number":42,"title":"Fix widgets","url":"https://github.com/acme/widgets/pull/42","body":"body text","state":"OPEN","isDraft":true,"headRefOid":"${PR_HEAD_SHA:-missing}","headRefName":"feature/pr","baseRefName":"main","createdAt":"2026-01-01T00:00:00Z","additions":1200,"deletions":400,"changedFiles":2,"files":[{"path":"src/a.ts"},{"path":"src/c.ts"}],"commits":[{"oid":"${PR_HEAD_SHA:-missing}"}],"reviewDecision":"REVIEW_REQUIRED"}
JSON
    ;;
  *"pr diff 42"*"--stat"*)
    printf ' src/a.ts | 2 +-\n src/c.ts | 1 +\n 2 files changed, 2 insertions(+), 1 deletion(-)\n'
    ;;
  *"repos/acme/widgets/pulls/42/comments"*)
    cat <<'JSON'
[{"id":501,"body":"very long inline comment body","user":{"login":"reviewer"},"created_at":"2026-06-01T00:00:00Z","path":"src/a.ts","line":2,"in_reply_to_id":500}]
JSON
    ;;
  *"repos/acme/widgets/pulls/42/reviews"*)
    cat <<'JSON'
[{"id":601,"state":"COMMENTED","body":"review body","user":{"login":"lead"},"submitted_at":"2026-06-01T00:10:00Z"}]
JSON
    ;;
  *threadId=T1*commentCursor=COMMENT_PAGE_2*)
    cat <<'JSON'
{"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":"COMMENT_END"},"nodes":[{"databaseId":101,"body":"decline with evidence","author":{"login":"alice"},"createdAt":"2026-06-01T00:01:00Z"}]}}}}
JSON
    ;;
  *threadCursor=THREAD_PAGE_2*)
    cat <<'JSON'
{"data":{"repository":{"pullRequest":{"headRefName":"feature/pr","baseRefName":"main","headRepository":{"nameWithOwner":"acme/widgets"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":"THREAD_END"},"nodes":[{"id":"T2","isResolved":true,"path":"src/b.ts","line":20,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":"C2"},"nodes":[{"databaseId":200,"body":"done","author":{"login":"bob"},"createdAt":"2026-06-01T00:02:00Z"}]}},{"id":"T3","isResolved":false,"path":"src/c.ts","line":1,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":"C3"},"nodes":[{"databaseId":300,"body":"still broken","author":{"login":"carol"},"createdAt":"2026-06-01T00:03:00Z"}]}}]}}}}}
JSON
    ;;
  *)
    cat <<'JSON'
{"data":{"repository":{"pullRequest":{"headRefName":"feature/pr","baseRefName":"main","headRepository":{"nameWithOwner":"acme/widgets"},"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"THREAD_PAGE_2"},"nodes":[{"id":"T1","isResolved":false,"path":"src/a.ts","line":2,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"COMMENT_PAGE_2"},"nodes":[{"databaseId":100,"body":"fix this long reviewer claim","author":{"login":"claude"},"createdAt":"2026-06-01T00:00:00Z"}]}}]}}}}}
JSON
    ;;
esac
SH
chmod +x "$TMPDIR_TEST/bin/gh"

review_context="$TMPDIR_TEST/review-context.json"
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" review-context "acme/widgets#42" --max-body-chars 12 --max-kb-paths 0 > "$review_context"
assert_cmd "review-context emits compact metadata, comments, reviews, and stat" "$PYTHON_BIN" - "$review_context" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["sizeGate"]["total_lines"] == 1600
assert data["sizeGate"]["diff_mode"] == "stat"
assert data["changedFiles"] == ["src/a.ts", "src/c.ts"]
assert "2 files changed" in data["diffStat"]
assert data["reviewComments"][0]["body"].endswith("...")
assert data["reviewComments"][0]["path"] == "src/a.ts"
assert data["reviewComments"][0]["line"] == 2
assert data["reviewComments"][0]["inReplyToId"] == 500
assert data["reviews"][0]["author"] == "lead"
assert data["kbMentions"] == []
PY

dossiers_out="$TMPDIR_TEST/dossiers.json"
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" comment-dossiers "acme/widgets#42" --local-repo "$repo" --unresolved-only --context-lines 1 --max-body-chars 16 > "$dossiers_out"
assert_cmd "comment-dossiers includes unresolved local excerpts and diff flag" "$PYTHON_BIN" - "$dossiers_out" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert [thread["id"] for thread in data["threads"]] == ["T1", "T3"]
t1 = data["threads"][0]
assert t1["headExcerpt"]["available"] is True
assert 'return "head"' in t1["headExcerpt"]["content"]
assert t1["baseExcerpt"]["available"] is True
assert t1["diffAvailable"] is True
assert t1["comments"][0]["body"].endswith("...")
PY

prep_out="$TMPDIR_TEST/prep-state.json"
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" prep-state "acme/widgets#42" --local-repo "$repo" --state-dir "$TMPDIR_TEST/state" > "$prep_out"
assert_cmd "prep-state emits branch, thread, abort, and overlap state" "$PYTHON_BIN" - "$prep_out" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["remoteHead"]["matchesMetadata"] is True
assert len(data["reviewThreads"]["unresolved"]) == 2
assert [thread["id"] for thread in data["reviewThreads"]["botDeclineCandidates"]] == ["T1"]
assert data["priorAbort"]["exists"] is True
assert data["priorAbort"]["matchesCurrent"] is False
assert data["adjacentSameFileOverlap"]["scanRan"] is True
assert any(item["path"] == "src/a.ts" for item in data["adjacentSameFileOverlap"]["files"])
PY

assert_cmd "is_bot_login classifies epixa and suffix bots but not humans" "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# epixa has no [bot]/-bot suffix, so it must be in the explicit set to be caught.
assert "uipathepixa" in mod.BOT_LOGINS
assert mod.is_bot_login("uipathepixa") is True
assert mod.is_bot_login("UiPathEpixa") is True  # case-insensitive
assert mod.is_bot_login("github-actions[bot]") is True
assert mod.is_bot_login("some-bot") is True
assert mod.is_bot_login("carol") is False
assert mod.is_bot_login(None) is False

# an epixa-authored thread with a human decline is a bot-decline candidate.
threads = [
    {
        "isResolved": False,
        "comments": {
            "nodes": [
                {"author": {"login": "uipathepixa"}, "body": "config risk"},
                {"author": {"login": "carol"}, "body": "declined, by design"},
            ]
        },
    }
]
candidates = mod.bot_decline_candidates(threads, 200)
assert len(candidates) == 1
PY

if [[ "$failures" -eq 0 ]]; then
  printf '\npr-github-helper tests passed.\n'
  exit 0
fi

printf '\n%d pr-github-helper assertion(s) failed.\n' "$failures" >&2
exit 1
