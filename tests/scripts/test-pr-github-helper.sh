#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/pr-github-helper.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

failures=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_cmd() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

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
assert data["review_threads"][0:3] == ["gh", "api", "graphql"]
assert "pageInfo" in data["review_threads"][-1]
PY

cat > "$TMPDIR_TEST/small.json" <<'JSON'
{"additions": 50, "deletions": 25}
JSON
gate_small="$TMPDIR_TEST/gate-small.json"
"$PYTHON_BIN" "$SCRIPT" size-gate --metadata "$TMPDIR_TEST/small.json" > "$gate_small"
assert_cmd "small PR uses full diff" "$PYTHON_BIN" - "$gate_small" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["total_lines"] == 75
assert data["diff_mode"] == "full"
assert data["review_warning"] is False
PY

cat > "$TMPDIR_TEST/boundary.json" <<'JSON'
{"additions": 1000, "deletions": 500}
JSON
gate_boundary="$TMPDIR_TEST/gate-boundary.json"
"$PYTHON_BIN" "$SCRIPT" size-gate --metadata "$TMPDIR_TEST/boundary.json" > "$gate_boundary"
assert_cmd "1500-line PR keeps full diff without warning" "$PYTHON_BIN" - "$gate_boundary" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["total_lines"] == 1500
assert data["diff_mode"] == "full"
assert data["review_warning"] is False
PY

cat > "$TMPDIR_TEST/mid.json" <<'JSON'
{"additions": 1000, "deletions": 501}
JSON
gate_mid="$TMPDIR_TEST/gate-mid.json"
"$PYTHON_BIN" "$SCRIPT" size-gate --metadata "$TMPDIR_TEST/mid.json" > "$gate_mid"
assert_cmd "PR over 1500 lines uses stat diff and warns" "$PYTHON_BIN" - "$gate_mid" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["total_lines"] == 1501
assert data["diff_mode"] == "stat"
assert data["review_warning"] is True
assert data["stat_threshold"] == 1500
PY

cat > "$TMPDIR_TEST/large.json" <<'JSON'
{"additions": 4000, "deletions": 1501}
JSON
gate_large="$TMPDIR_TEST/gate-large.json"
"$PYTHON_BIN" "$SCRIPT" size-gate --metadata "$TMPDIR_TEST/large.json" > "$gate_large"
assert_cmd "large PR uses stat diff and warns" "$PYTHON_BIN" - "$gate_large" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["total_lines"] == 5501
assert data["diff_mode"] == "stat"
assert data["review_warning"] is True
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

if [[ "$failures" -eq 0 ]]; then
  printf '\npr-github-helper tests passed.\n'
  exit 0
fi

printf '\n%d pr-github-helper assertion(s) failed.\n' "$failures" >&2
exit 1
