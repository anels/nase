#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/citation-validator.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/gh-only" "$TMPDIR_TEST/one/src" "$TMPDIR_TEST/two/src" "$TMPDIR_TEST/outside"
printf 'first\nsecond\n' > "$TMPDIR_TEST/one/src/file.py"
printf 'other\n' > "$TMPDIR_TEST/two/src/other.py"
printf 'outside\n' > "$TMPDIR_TEST/outside/file.py"
ln -s "$TMPDIR_TEST/outside/file.py" "$TMPDIR_TEST/one/link.py"

cat > "$TMPDIR_TEST/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import sys
import time

args = sys.argv[1:]
if args == ["auth", "status", "--hostname", "github.com"]:
    print("authenticated")
    raise SystemExit(0)
if args[:2] == ["repo", "view"]:
    repo = args[2]
    if repo == "hidden/private":
        print("repository not found", file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps({"nameWithOwner": repo}))
    raise SystemExit(0)
if args[:2] != ["pr", "view"]:
    raise SystemExit(9)
number = args[2]
if number == "1":
    print(json.dumps({"number": 1, "title": "Fixed", "state": "MERGED", "mergedAt": "2026-08-01T00:00:00Z", "author": {"login": "alice"}, "url": "https://github.com/example/service/pull/1"}))
    raise SystemExit(0)
if number == "2":
    print(json.dumps({"number": 2, "title": "ghp_" + "A" * 24, "state": "OPEN", "mergedAt": None, "author": {"login": "alice"}, "url": "https://github.com/example/service/pull/2"}))
    raise SystemExit(0)
if number == "404":
    print("pull request not found", file=sys.stderr)
elif number == "401":
    print("authentication required", file=sys.stderr)
elif number == "429":
    print("rate limit exceeded", file=sys.stderr)
elif number == "408":
    time.sleep(3)
else:
    print("unclassified TOPSECRET_FIXTURE_TOKEN", file=sys.stderr)
raise SystemExit(1)
PY

cat > "$TMPDIR_TEST/bin/acli" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time

args = sys.argv[1:]
if args == ["auth", "status"]:
    if os.environ.get("ACLI_MODE") == "unauth":
        print("not authenticated", file=sys.stderr)
        raise SystemExit(1)
    print("authenticated")
    raise SystemExit(0)
key = args[3]
if key == "TEST-1":
    print(json.dumps({"fields": {"summary": "Issue", "status": {"name": "Done"}, "assignee": {"displayName": "Alice"}}}))
    raise SystemExit(0)
if key == "TEST-2":
    print(json.dumps({"fields": {"summary": "ghp_" + "A" * 24, "status": {"name": "Done"}, "assignee": {"displayName": "Alice"}}}))
    raise SystemExit(0)
if key == "TEST-404":
    print("work item not found", file=sys.stderr)
elif key == "TEST-408":
    time.sleep(3)
else:
    print("unknown TOPSECRET_FIXTURE_TOKEN", file=sys.stderr)
raise SystemExit(1)
PY
chmod +x "$TMPDIR_TEST/bin/gh" "$TMPDIR_TEST/bin/acli"
cp "$TMPDIR_TEST/bin/gh" "$TMPDIR_TEST/gh-only/gh"

export PATH="$TMPDIR_TEST/bin:$PATH"
failures=0
source "$ROOT/tests/lib/assert.sh"

write_artifact() {
  printf '%s\n' "$2" > "$1"
}

run_validator() {
  local artifact="$1" output="$2"
  shift 2
  "$PYTHON_BIN" "$SCRIPT" "$artifact" --root "one=$TMPDIR_TEST/one" --format json "$@" > "$output"
}

assert_status() {
  local name="$1" expected_rc="$2" artifact_text="$3" expected_status="$4" expected_detail="$5"
  local artifact="$TMPDIR_TEST/one/artifact.md" output="$TMPDIR_TEST/result.json" rc
  write_artifact "$artifact" "$artifact_text"
  set +e
  run_validator "$artifact" "$output" --repo-root "two=$TMPDIR_TEST/two" --timeout-seconds 1
  rc=$?
  set -e
  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "$name"
    return
  fi
  if "$PYTHON_BIN" - "$output" "$expected_status" "$expected_detail" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["results"]
assert data["results"][0]["status"] == sys.argv[2]
assert data["results"][0]["detail"] == sys.argv[3]
PY
  then
    pass "$name"
  else
    fail "$name"
  fi
}

write_artifact "$TMPDIR_TEST/one/artifact.md" "No eligible references."
assert_cmd "no citations exits zero" run_validator "$TMPDIR_TEST/one/artifact.md" "$TMPDIR_TEST/no-citations.json"

assert_status "qualified path resolves" 0 '`one:src/file.py:2`' OK resolved
assert_status "missing qualified path is broken" 1 '`one:src/missing.py:1`' BROKEN missing-file
assert_status "line overflow is broken" 1 '`one:src/file.py:9`' BROKEN line-out-of-range
assert_status "path traversal is broken" 1 '`one:../outside/file.py:1`' BROKEN path-escape
assert_status "symlink escape is broken" 1 '`one:link.py:1`' BROKEN symlink-escape
assert_status "unknown alias is unknown" 2 '`missing:src/file.py:1`' UNKNOWN unavailable-root
assert_status "unique legacy path resolves" 0 '`src/file.py:1`' OK resolved
assert_status "missing legacy path is unknown" 2 '`src/missing.py:1`' UNKNOWN unqualified-root

cp "$TMPDIR_TEST/one/src/file.py" "$TMPDIR_TEST/two/src/file.py"
assert_status "ambiguous legacy path is unknown" 2 '`src/file.py:1`' UNKNOWN ambiguous-root
rm "$TMPDIR_TEST/two/src/file.py"

write_artifact "$TMPDIR_TEST/one/artifact.md" 'Ignore `/nase:design`, `src/*.py:1`, `src/{slug}.py:1`, `$(pwd):1`, `https://example.com/a.py:1`, and `src/file.py`.'
assert_cmd "commands globs placeholders expressions URLs and no-line paths are ignored" bash -c '
  "$1" "$2" "$3" --root "one=$4" --format json > "$5"
  "$1" - "$5" <<"PY"
import json
import sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["results"] == []
PY
' _ "$PYTHON_BIN" "$SCRIPT" "$TMPDIR_TEST/one/artifact.md" "$TMPDIR_TEST/one" "$TMPDIR_TEST/ignored.json"

absolute_path="$TMPDIR_TEST/one/src/file.py"
write_artifact "$TMPDIR_TEST/one/artifact.md" "\`$absolute_path:1\`"
assert_cmd "absolute path resolves without leaking root" bash -c '
  "$1" "$2" "$3" --root "one=$4" --format json > "$5"
  ! grep -Fq "$4" "$5"
  "$1" - "$5" <<"PY"
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["results"][0]["ref"] == "one:src/file.py:1"
PY
' _ "$PYTHON_BIN" "$SCRIPT" "$TMPDIR_TEST/one/artifact.md" "$TMPDIR_TEST/one" "$TMPDIR_TEST/absolute.json"

assert_status "GitHub PR resolves" 0 'https://github.com/example/service/pull/1' OK resolved
assert_status "inaccessible GitHub repository is unknown" 2 'https://github.com/hidden/private/pull/404' UNKNOWN repository-unavailable
assert_status "GitHub 404 is broken" 1 'https://github.com/example/service/pull/404' BROKEN not-found
assert_status "GitHub auth failure is unknown" 2 'https://github.com/example/service/pull/401' UNKNOWN auth-unavailable
assert_status "GitHub rate limit is unknown" 2 'https://github.com/example/service/pull/429' UNKNOWN rate-limited
assert_status "GitHub timeout is unknown" 2 'https://github.com/example/service/pull/408' UNKNOWN timeout
assert_status "GitHub unknown error is redacted" 2 'https://github.com/example/service/pull/500' UNKNOWN authority-error
assert_cmd "fake CLI token is absent from JSON" bash -c '! grep -Fq TOPSECRET_FIXTURE_TOKEN "$1"' _ "$TMPDIR_TEST/result.json"

assert_status "GitHub metadata secret is redacted" 0 'https://github.com/example/service/pull/2' OK resolved
assert_cmd "GitHub metadata secret is absent from JSON" bash -c '
  ! grep -Fq "ghp_" "$1"
  grep -Fq "<redacted-sensitive-value>" "$1"
' _ "$TMPDIR_TEST/result.json"

assert_status "Jira resolves" 0 'TEST-1' OK resolved
assert_status "Jira metadata secret is redacted" 0 'TEST-2' OK resolved
assert_cmd "Jira metadata secret is absent from JSON" bash -c '
  ! grep -Fq "ghp_" "$1"
  grep -Fq "<redacted-sensitive-value>" "$1"
' _ "$TMPDIR_TEST/result.json"
assert_status "Jira 404 is broken" 1 'TEST-404' BROKEN not-found
ACLI_MODE=unauth assert_status "Jira unauthenticated is unknown" 2 'TEST-1' UNKNOWN auth-unavailable
assert_status "Jira timeout is unknown" 2 'TEST-408' UNKNOWN timeout
assert_status "Jira unknown error is redacted" 2 'TEST-500' UNKNOWN authority-error

write_artifact "$TMPDIR_TEST/one/artifact.md" 'TEST-1'
set +e
PATH="$TMPDIR_TEST/gh-only:/usr/bin:/bin" "$PYTHON_BIN" "$SCRIPT" "$TMPDIR_TEST/one/artifact.md" --root "one=$TMPDIR_TEST/one" --format json > "$TMPDIR_TEST/missing-acli.json"
missing_rc=$?
set -e
if [[ "$missing_rc" -eq 2 ]] && grep -Fq 'missing-cli' "$TMPDIR_TEST/missing-acli.json"; then pass "missing acli is unknown"; else fail "missing acli is unknown"; fi

assert_status "Confluence requires MCP authority" 2 'https://example.atlassian.net/wiki/spaces/ENG/pages/123/Test' UNKNOWN mcp-required

write_artifact "$TMPDIR_TEST/one/artifact.md" '`one:missing.py:1` and TEST-500'
set +e
run_validator "$TMPDIR_TEST/one/artifact.md" "$TMPDIR_TEST/mixed.json" --timeout-seconds 1
mixed_rc=$?
set -e
if [[ "$mixed_rc" -eq 1 ]] && "$PYTHON_BIN" - "$TMPDIR_TEST/mixed.json" <<'PY'
import json
import sys
statuses = {item["status"] for item in json.load(open(sys.argv[1], encoding="utf-8"))["results"]}
assert statuses == {"BROKEN", "UNKNOWN"}
PY
then pass "broken takes precedence while unknown is retained"; else fail "broken takes precedence while unknown is retained"; fi

write_artifact "$TMPDIR_TEST/one/artifact.md" 'https://github.com/example/service/pull/1 https://github.com/example/service/pull/1'
run_validator "$TMPDIR_TEST/one/artifact.md" "$TMPDIR_TEST/stable-one.json"
run_validator "$TMPDIR_TEST/one/artifact.md" "$TMPDIR_TEST/stable-two.json"
assert_cmd "duplicate references are validated once and JSON is stable" bash -c '
  cmp "$1" "$2"
  "$3" - "$1" <<"PY"
import json
import sys
assert len(json.load(open(sys.argv[1], encoding="utf-8"))["results"]) == 1
PY
' _ "$TMPDIR_TEST/stable-one.json" "$TMPDIR_TEST/stable-two.json" "$PYTHON_BIN"

ln -s "$TMPDIR_TEST/one/artifact.md" "$TMPDIR_TEST/one/artifact-link.md"
assert_cmd "symlink artifact is rejected before extraction" bash -c '! "$1" "$2" --root "one=$3" --format json >/dev/null 2>&1' _ "$PYTHON_BIN" "$SCRIPT" "$TMPDIR_TEST/one/artifact-link.md" "$TMPDIR_TEST/one"
write_artifact "$TMPDIR_TEST/outside/artifact.md" 'No citations.'
assert_cmd "artifact outside primary root is rejected" bash -c '! "$1" "$2" --root "one=$3" --format json >/dev/null 2>&1' _ "$PYTHON_BIN" "$SCRIPT" "$TMPDIR_TEST/outside/artifact.md" "$TMPDIR_TEST/one"
assert_cmd "validator never requests a shell" bash -c '! grep -Eq "shell[[:space:]]*=[[:space:]]*True" "$1"' _ "$SCRIPT"

if [[ "$failures" -eq 0 ]]; then
  printf '\ncitation-validator tests passed.\n'
  exit 0
fi

printf '\n%d citation-validator assertion(s) failed.\n' "$failures" >&2
exit 1
