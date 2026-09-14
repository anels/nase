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
assert data["diff_names"][-1] == "--name-only"
assert "--stat" not in data["diff_names"]
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

assert_cmd "diff stat renders from metadata without gh pr diff" "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# No files at all -> empty string, so callers can treat it as "no delta".
assert module.render_diff_stat({"files": []}) == ""
assert module.render_diff_stat({}) == ""

# Per-file counts present: rows carry them and the summary sums them.
counted = module.render_diff_stat({
    "additions": 7,
    "deletions": 1,
    "files": [
        {"path": "src/a.ts", "additions": 3, "deletions": 1},
        {"path": "src/b.ts", "additions": 4, "deletions": 0},
    ],
})
assert counted.splitlines() == [
    " src/a.ts | 4 +3 -1",
    " src/b.ts | 4 +4 -0",
    " 2 files changed, 7 insertions(+), 1 deletions(-)",
], counted

# Per-file counts absent: fall back to the PR-level totals rather than reporting zeros.
uncounted = module.render_diff_stat({
    "additions": 12,
    "deletions": 5,
    "files": [{"path": "src/a.ts"}],
})
assert uncounted.splitlines() == [
    " src/a.ts",
    " 1 file changed, 12 insertions(+), 5 deletions(-)",
], uncounted

# gh pr view returns at most 100 file rows. Keep the PR-level totals accurate and
# make the omitted rows explicit instead of silently under-reporting a large PR.
truncated = module.render_diff_stat({
    "changedFiles": 3,
    "additions": 12,
    "deletions": 5,
    "files": [
        {"path": "src/a.ts", "additions": 3, "deletions": 1},
        {"path": "src/b.ts", "additions": 4, "deletions": 0},
    ],
})
assert truncated.splitlines() == [
    " src/a.ts | 4 +3 -1",
    " src/b.ts | 4 +4 -0",
    " ... 1 more file omitted by gh pr view",
    " 3 files changed, 12 insertions(+), 5 deletions(-)",
], truncated
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
    # Honour --json the way real gh does: emit ONLY the requested keys. A stub that
    # returns every key regardless hides a caller asking for the wrong field set -
    # `finding-scope` shipped resolving the head ref to "origin/None" because the
    # light variant omits headRefName and this stub handed it over anyway.
    requested=$(printf '%s\n' "$args" | sed -n 's/.*--json \([^ ]*\).*/\1/p')
    PR_HEAD_SHA="${PR_HEAD_SHA:-missing}" GH_REQUESTED_FIELDS="$requested" python3 -c '
import json, os
full = {
    "number": 42,
    "title": "Fix widgets",
    "url": "https://github.com/acme/widgets/pull/42",
    "body": "body text",
    "state": "OPEN",
    "isDraft": True,
    "headRefOid": os.environ["PR_HEAD_SHA"],
    "headRefName": "feature/pr",
    "baseRefName": "main",
    "createdAt": "2026-01-01T00:00:00Z",
    "additions": 1200,
    "deletions": 400,
    "changedFiles": 3,
    "files": [
        {"path": "src/a.ts", "additions": 800, "deletions": 300, "changeType": "MODIFIED"},
        {"path": "src/c.ts", "additions": 400, "deletions": 100, "changeType": "ADDED"},
    ],
    "commits": [{"oid": os.environ["PR_HEAD_SHA"]}],
    "reviewDecision": "REVIEW_REQUIRED",
    "headRepository": {"nameWithOwner": "acme/widgets"},
}
fields = [f for f in os.environ["GH_REQUESTED_FIELDS"].split(",") if f]
missing = [f for f in fields if f not in full]
if missing:
    raise SystemExit("stub has no fixture for requested field(s): " + ",".join(missing))
print(json.dumps({k: full[k] for k in fields} if fields else full))
'
    ;;
  # No `gh pr diff --stat` arm on purpose: that flag was removed from gh, and mocking it
  # is what let the real breakage pass. review-context must derive the stat from metadata.
  *"pr diff 42"*)
    echo "unknown flag" >&2
    exit 1
    ;;
  *"api user"*)
    echo "octo-dev"
    ;;
  *"repos/acme/widgets/pulls/42/comments"*)
    cat <<'JSON'
[{"id":501,"body":"very long inline comment body","user":{"login":"reviewer"},"created_at":"2026-06-01T00:00:00Z","path":"src/a.ts","line":2,"in_reply_to_id":500}]
JSON
    ;;
  *"repos/acme/widgets/pulls/42/reviews"*)
    cat <<'JSON'
[{"id":601,"state":"COMMENTED","body":"review body","user":{"login":"lead"},"submitted_at":"2026-06-01T00:10:00Z"},{"id":602,"state":"APPROVED","body":"","user":{"login":"dana"},"submitted_at":"2026-06-01T00:20:00Z"}]
JSON
    ;;
  # SonarCloud posts its quality-gate verdict here, not on a review thread, so a
  # thread-only read reports an honest zero while this is outstanding.
  *"repos/acme/widgets/issues/42/comments"*)
    cat <<'JSON'
[{"id":701,"body":"Quality Gate failed","user":{"login":"sonarcloud[bot]"},"created_at":"2026-06-01T00:30:00Z"}]
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
assert data["changedFilesOmitted"] == 1
assert " src/a.ts | 1100 +800 -300" in data["diffStat"]
assert " ... 1 more file omitted by gh pr view" in data["diffStat"]
assert data["diffStat"].endswith(" 3 files changed, 1200 insertions(+), 400 deletions(-)")
assert data["reviewComments"][0]["body"].endswith("...")
assert data["reviewComments"][0]["path"] == "src/a.ts"
assert data["reviewComments"][0]["line"] == 2
assert data["reviewComments"][0]["inReplyToId"] == 500
assert [item["id"] for item in data["reviewSubmissions"]] == [601], "empty-body approval carries nothing"
assert data["reviewSubmissions"][0]["author"] == "lead"
assert data["viewerLogin"] == "octo-dev"
assert data["issueComments"][0]["author"] == "sonarcloud[bot]"
assert data["issueComments"][0]["authorIsBot"] is True
assert data["kbMentions"] == []
PY

# kb-search.sh exits 2 for "no mentions" and any other non-zero when the scan itself
# failed. Collapsing those two into one empty row reports a broken KB read as "nothing
# references this file", which is a claim the reader acts on.
# Several paths are one kb-search invocation, not one each: the script walks every KB
# file per call, so per-path spawning multiplied a fixed cost by --max-kb-paths. Sections
# are keyed by the header naming their own path, because a path with no hits still gets a
# header and reading by position would shift every later path by one.
assert_cmd "kb mentions sweep once and split by header" "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import subprocess
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

calls = []
real_run = subprocess.run

OUTPUT = "\n".join([
    '## KB Search - "mentions:src/a.ts" - 2 result(s)',
    "",
    "**File:** `workspace/kb/general/a.md`",
    "alpha body",
    "",
    "---",
    "",
    '## KB Search - "mentions:src/gone.ts" - no results',
    "",
    "---",
    "",
    '## KB Search - "mentions:src/b.ts" - 1 result(s)',
    "",
    "**File:** `workspace/kb/general/b.md`",
    "bravo body",
    "",
    "---",
    "",
])


def fake(argv, **kwargs):
    if argv[:1] == ["bash"] and "kb-search.sh" in str(argv[1]):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, OUTPUT, "")
    return real_run(argv, **kwargs)


try:
    subprocess.run = fake
    rows = module.kb_mentions_for_paths(["src/a.ts", "src/gone.ts", "src/b.ts"], 10)
finally:
    subprocess.run = real_run

assert len(calls) == 1, f"expected one sweep, got {len(calls)}"
passed = [arg for arg in calls[0] if arg.startswith("mentions:")]
assert passed == ["mentions:src/a.ts", "mentions:src/gone.ts", "mentions:src/b.ts"], passed

by_path = {row["path"]: row["hits"] for row in rows}
# The path with no hits contributes no row, as before; the other two keep their own body
# and must not borrow each other's.
assert set(by_path) == {"src/a.ts", "src/b.ts"}, sorted(by_path)
assert "alpha body" in by_path["src/a.ts"], by_path["src/a.ts"]
assert "bravo body" not in by_path["src/a.ts"], by_path["src/a.ts"]
assert "bravo body" in by_path["src/b.ts"], by_path["src/b.ts"]
assert "alpha body" not in by_path["src/b.ts"], by_path["src/b.ts"]

# A timeout is one verdict for every path now, which is the trade for one file walk.
def slow(argv, **kwargs):
    if argv[:1] == ["bash"] and "kb-search.sh" in str(argv[1]):
        raise subprocess.TimeoutExpired(argv, 45)
    return real_run(argv, **kwargs)


try:
    subprocess.run = slow
    rows = module.kb_mentions_for_paths(["src/a.ts", "src/b.ts"], 10)
finally:
    subprocess.run = real_run
assert [row["path"] for row in rows] == ["src/a.ts", "src/b.ts"], rows
assert all("timed out" in row["unavailable"] for row in rows), rows
PY

assert_cmd "kb mentions separate an empty answer from a failed scan" "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import subprocess
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

real_run = subprocess.run


def stub(exit_code, out="", err=""):
    def fake(argv, **kwargs):
        if argv[:1] == ["bash"] and "kb-search.sh" in str(argv[1]):
            return subprocess.CompletedProcess(argv, exit_code, out, err)
        return real_run(argv, **kwargs)
    return fake


try:
    # A real hit always renders a `**File:**` line; a stub without one is not the live
    # shape, and the caller uses that marker to tell a rendered entry from a bare
    # "no results" header.
    subprocess.run = stub(0, out="## KB Search - hit\n\n**File:** `workspace/kb/general/a.md`\nbody\n")
    hits = module.kb_mentions_for_paths(["src/a.ts"], 1)
    assert len(hits) == 1 and hits[0]["hits"], hits
    assert "unavailable" not in hits[0], hits

    subprocess.run = stub(2)
    empty = module.kb_mentions_for_paths(["src/a.ts"], 1)
    assert empty == [], empty

    subprocess.run = stub(1, err="kb-search.sh: usage error\n")
    broken = module.kb_mentions_for_paths(["src/a.ts"], 1)
    assert len(broken) == 1, broken
    assert broken[0]["hits"] == "", broken
    assert "exited 1" in broken[0]["unavailable"], broken
    assert "usage error" in broken[0]["unavailable"], broken
finally:
    subprocess.run = real_run
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
# The reviewer-facing branches (no courtesy opener for a bot decline, no Slack re-review
# ping for a bot) read this flag instead of re-deriving the bot set in prose.
assert t1["comments"][0]["authorIsBot"] is True, "suffix-less bot login 'claude'"
assert t1["firstComment"]["authorIsBot"] is True
assert data["threads"][1]["comments"][0]["authorIsBot"] is False, "human login 'carol'"
# Feedback also lands off the thread surface, so a zero here is only one third of an answer.
assert [item["id"] for item in data["reviewSubmissions"]] == [601], "empty-body approval carries nothing"
assert data["issueComments"][0]["author"] == "sonarcloud[bot]"
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
# Merge readiness reads all three feedback surfaces, not threads alone.
assert [item["id"] for item in data["reviewSubmissions"]] == [601]
assert data["issueComments"][0]["body"] == "Quality Gate failed"
PY

# --- same-repo guards ---------------------------------------------------------
# /nase:address-comments mutates exactly one repo and used to prove that with a
# hand-written sed pipeline over `git remote get-url origin`. These assert the
# field comparison that replaced it, including the shapes the pipeline handled.

assert_cmd "normalize_repo_slug handles every GitHub remote spelling" \
  "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

for url in (
    "https://github.com/Acme/Widgets.git",
    "https://user@github.com/acme/widgets",
    "git@github.com:acme/widgets.git",
    "ssh://git@github.com/acme/widgets/",
    "https://github.com/acme/widgets\n",
):
    assert module.normalize_repo_slug(url) == "acme/widgets", url
# A different host must not normalize into a bare owner/repo that could match.
assert module.normalize_repo_slug("https://example.com/acme/widgets") != "acme/widgets"
PY

guards_repo="$TMPDIR_TEST/guards-repo"
git init -q "$guards_repo"
git -C "$guards_repo" remote add origin git@github.com:Acme/Widgets.git

assert_cmd "same_repo_guards passes when origin, head repo, and head ref agree" \
  "$PYTHON_BIN" - "$SCRIPT" "$guards_repo" <<'PY'
import importlib.util
import subprocess
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

repo = Path(sys.argv[2])
env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@e", "PATH": "/usr/bin:/bin:/usr/local/bin"}
(repo / "f.txt").write_text("x\n", encoding="utf-8")
subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=env)
subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "chore: init"], check=True, env=env)
subprocess.run(
    ["git", "-C", str(repo), "update-ref", "refs/remotes/origin/feature/pr", "HEAD"],
    check=True, env=env,
)

pr = module.normalized_pr("acme", "widgets", 42)
response = {
    "headRefName": "feature/pr",
    "headRepository": {"nameWithOwner": "Acme/Widgets"},
}
guards = module.same_repo_guards(pr, repo, response)
# Case-insensitive on both axes: GitHub preserves display case, the slug does not.
assert guards["originOk"] is True, guards
assert guards["sameRepoOk"] is True, guards
assert guards["headRefOk"] is True, guards

fork = module.same_repo_guards(
    pr, repo, {"headRefName": "feature/pr", "headRepository": {"nameWithOwner": "someone/widgets"}}
)
assert fork["sameRepoOk"] is False, "a fork head must not pass the single-repo gate"

missing_ref = module.same_repo_guards(
    pr, repo, {"headRefName": "no/such/branch", "headRepository": {"nameWithOwner": "acme/widgets"}}
)
assert missing_ref["headRefOk"] is False, "an unfetched head ref must not pass"

null_head = module.same_repo_guards(pr, repo, {"headRefName": None, "headRepository": None})
assert null_head["sameRepoOk"] is False and null_head["headRefOk"] is False

other = module.normalized_pr("other", "repo", 1)
assert module.same_repo_guards(other, repo, response)["originOk"] is False
PY

# --- finding-scope ------------------------------------------------------------
# Step 4a/4b used to run one hand-typed `git show origin/{base}:{path}` per candidate.

scope_candidates="$TMPDIR_TEST/candidates.json"
cat > "$scope_candidates" <<'JSON'
[{"id":"c1","path":"src/a.ts","line":2},{"id":"c2","path":"src/new.ts","line":1},{"id":"c3","path":"src/gone.ts","line":1}]
JSON
scope_out="$TMPDIR_TEST/finding-scope.json"
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" \
  finding-scope "acme/widgets#42" --local-repo "$repo" --candidates "$scope_candidates" \
  --context-lines 1 > "$scope_out"

# An unfetched or missing ref makes every `git diff` fail, and diff_for_file returns ""
# on any non-zero exit - indistinguishable per-candidate from "the PR did not touch this
# path", which the caller is told to drop silently. refsResolved is the tell.
scope_norefs="$TMPDIR_TEST/finding-scope-norefs.json"
norefs_repo="$TMPDIR_TEST/norefs-repo"
git init -q "$norefs_repo"
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" \
  finding-scope "acme/widgets#42" --local-repo "$norefs_repo" --candidates "$scope_candidates" \
  > "$scope_norefs"
assert_cmd "finding-scope reports unresolved refs instead of a silent all-clean verdict" \
  "$PYTHON_BIN" - "$scope_norefs" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["refsResolved"] is False, "neither origin ref exists in a bare fresh repo"
# Without the flag this output is identical to "the PR touched nothing", which is the
# shape that silently discards a whole review.
assert all(item["touchedByPr"] is False for item in data["candidates"])
PYEOF

# PR scope is measured from the merge-base. With two-dot `base..head`, a commit that
# lands on the base branch after the PR forked reads as a change this PR made - and
# finding_scope turns that reading into a silent drop-or-keep decision.
scope_moved_base="$TMPDIR_TEST/finding-scope-moved-base.json"
(
  cd "$repo" || exit 1
  git checkout -q -B base-advance refs/remotes/origin/main
  printf 'advanced on base after the PR forked\n' > src/base_only.ts
  git add src/base_only.ts
  ALLOW_RAW_GIT_COMMIT=1 git commit -q -m "chore: advance base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q --detach refs/remotes/origin/feature/pr
)
cat > "$TMPDIR_TEST/candidates-base.json" <<'JSON'
[{"id":"b1","path":"src/base_only.ts","line":1}]
JSON
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" \
  finding-scope "acme/widgets#42" --local-repo "$repo" --candidates "$TMPDIR_TEST/candidates-base.json" \
  > "$scope_moved_base"
assert_cmd "finding-scope does not attribute a post-fork base commit to the PR" \
  "$PYTHON_BIN" - "$scope_moved_base" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
candidate = data["candidates"][0]
# The PR never touched this path; only the base branch moved.
assert candidate["touchedByPr"] is False, candidate
PYEOF

# A fork PR whose branch name collides with one this origin already has: the name
# resolves, so refsResolved is true, but it points at the WRONG commit. Preferring
# refs/pull/{n}/head is what keeps the head honest; crossRepo + headFromPullRef are what
# tell the caller when the fallback was used.
git -C "$repo" update-ref "refs/pull/42/head" refs/remotes/origin/feature/pr
scope_fork="$TMPDIR_TEST/finding-scope-fork.json"
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" \
  finding-scope "acme/widgets#42" --local-repo "$repo" --candidates "$scope_candidates" \
  > "$scope_fork"
assert_cmd "finding-scope prefers the pull ref over a collidable branch name" \
  "$PYTHON_BIN" - "$scope_fork" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["headFromPullRef"] is True, data
assert data["headRef"] == "refs/pull/42/head", data["headRef"]
assert data["refsResolved"] is True
# Same head commit as the branch name happens to point at here, so the verdicts hold.
assert {item["id"] for item in data["candidates"]} == {"c1", "c2", "c3"}
PYEOF

git -C "$repo" update-ref -d "refs/pull/42/head"
scope_nopull="$TMPDIR_TEST/finding-scope-nopull.json"
PR_HEAD_SHA="$head_sha" PATH="$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" "$SCRIPT" \
  finding-scope "acme/widgets#42" --local-repo "$repo" --candidates "$scope_candidates" \
  > "$scope_nopull"
assert_cmd "finding-scope reports when it fell back to the branch name" \
  "$PYTHON_BIN" - "$scope_nopull" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["headFromPullRef"] is False, data
assert data["headRef"] == "origin/feature/pr", data["headRef"]
# Same-repo here, so the fallback is sound - but the caller can only know that because
# crossRepo says so.
assert data["crossRepo"] is False, data
PYEOF

# A deleted fork returns headRepository: null. Reading that as same-repo would bless the
# branch-name fallback exactly when it is least sound, so an unknown head repo counts as
# cross-repo.
assert_cmd "unknown head repo counts as cross-repo, not same-repo" \
  "$PYTHON_BIN" - "$SCRIPT" <<'PYEOF'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

pr = module.normalized_pr("acme", "widgets", 42)
for metadata in ({"headRepository": None}, {}):
    head_repo = (metadata.get("headRepository") or {}).get("nameWithOwner")
    cross = head_repo is None or head_repo.lower() != pr["repo_full_name"].lower()
    assert cross is True, metadata
PYEOF

assert_cmd "finding-scope answers diff scope per candidate without a per-finding git show" \
  "$PYTHON_BIN" - "$scope_out" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
by_id = {item["id"]: item for item in data["candidates"]}
assert data["baseRef"] == "origin/main"
assert data["headRef"] == "origin/feature/pr"

# Modified by the PR: present in both refs, and the diff is non-empty.
a = by_id["c1"]
assert a["inBase"] is True and a["inHead"] is True
assert a["touchedByPr"] is True
assert a["headExcerpt"]["available"] is True
assert a["baseExcerpt"]["available"] is True

# A path that does not exist at either ref cannot support a finding.
gone = by_id["c3"]
assert gone["inBase"] is False and gone["inHead"] is False
assert gone["touchedByPr"] is False
assert gone["headExcerpt"] == {"available": False}
PY

assert_cmd "review-context issues its independent reads concurrently" \
  "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import json
import sys
import threading

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# A barrier asserts the overlap without timing: every one of the five reads must be
# in flight before any returns, so a serial implementation deadlocks on the timeout.
barrier = threading.Barrier(5, timeout=10)
metadata = {
    "number": 42,
    "title": "t",
    "url": "https://github.com/acme/widgets/pull/42",
    "body": "",
    "state": "OPEN",
    "isDraft": False,
    "headRefOid": "deadbeef",
    "additions": 1,
    "deletions": 1,
    "changedFiles": 1,
    "files": [{"path": "src/a.ts", "additions": 1, "deletions": 0, "changeType": "MODIFIED"}],
    "baseRefName": "main",
}


def fake_run_gh(args):
    barrier.wait()
    if args[:2] == ["gh", "pr"]:
        return json.dumps(metadata)
    if args[:3] == ["gh", "api", "user"]:
        return "octo-dev\n"
    return "[]"


module.run_gh = fake_run_gh
context = module.review_context(module.normalized_pr("acme", "widgets", 42), 200, 0)
assert context["metadata"]["number"] == 42
assert context["reviewComments"] == []
assert context["reviewSubmissions"] == []
assert context["issueComments"] == []
assert context["viewerLogin"] == "octo-dev"
PY

assert_cmd "run_gh_all keeps a single read serial" \
  "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.run_gh = lambda args: " ".join(args)
assert module.run_gh_all({"only": ["gh", "pr", "view"]}) == {"only": "gh pr view"}
PY

assert_cmd "is_bot_login classifies configured and suffix bots but not humans" \
  env NASE_BOT_LOGINS="severity-reviewer, Another-Reviewer" "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# A configured bot has no [bot]/-bot suffix, so only the explicit set catches it, and the
# shared default set must stay free of any one org's accounts.
assert "severity-reviewer" not in mod.BOT_LOGINS
assert mod.EXTRA_BOT_LOGINS == {"severity-reviewer", "another-reviewer"}
assert mod.is_bot_login("severity-reviewer") is True
assert mod.is_bot_login("Another-Reviewer") is True  # case-insensitive
assert mod.is_bot_login("github-actions[bot]") is True
assert mod.is_bot_login("some-bot") is True
assert mod.is_bot_login("carol") is False
assert mod.is_bot_login(None) is False

# Suffix-less AI reviewers the shared docs name as bots must be in the default set, or the
# Phase 9b reviewer-ping filter would Slack-DM them.
for suffixless_ai_reviewer in ("chatgpt-codex-connector", "coderabbitai", "sonarcloud"):
    assert mod.is_bot_login(suffixless_ai_reviewer) is True, suffixless_ai_reviewer

# a bot-authored thread with a human decline is a bot-decline candidate.
threads = [
    {
        "isResolved": False,
        "comments": {
            "nodes": [
                {"author": {"login": "severity-reviewer"}, "body": "config risk"},
                {"author": {"login": "carol"}, "body": "declined, by design"},
            ]
        },
    }
]
candidates = mod.bot_decline_candidates(threads, 200)
assert len(candidates) == 1
PY

mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/gh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
chmod +x "$TMPDIR_TEST/bin/gh"

assert_cmd "a hung gh read is killed and reported, not waited on" \
  env "PATH=$TMPDIR_TEST/bin:$PATH" "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import io
import sys
from contextlib import redirect_stderr

spec = importlib.util.spec_from_file_location("pr_github_helper", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# The real bound is 60s. Shrinking it here keeps the test fast; what is under test is
# that the bound exists and that main() maps the kill onto its own exit code.
module.GH_TIMEOUT_SECONDS = 1
captured = io.StringIO()
with redirect_stderr(captured):
    rc = module.main(["metadata", "acme/widgets#42"])
assert rc == module.GH_TIMEOUT_EXIT, rc
assert rc == 124, rc
message = captured.getvalue()
assert "command timed out" in message, message
assert "gh pr view" in message, message
PY

if [[ "$failures" -eq 0 ]]; then
  printf '\npr-github-helper tests passed.\n'
  exit 0
fi

printf '\n%d pr-github-helper assertion(s) failed.\n' "$failures" >&2
exit 1
