#!/usr/bin/env bash
# Regression tests for .claude/lib/hook-common.sh and the hooks that source it.
#
# Covers each lib function, the session-id chain, the two tracking-hook parsing
# fixes (empty @tsv field, multi-line prompt), the fail-open / fail-closed
# behaviour when the lib is missing, and a loop that runs every hook honouring
# NASE_ROOT from an unrelated cwd and asserts nothing lands in that cwd.
#
# Run from repo root:  bash tests/hooks/test-hook-common.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/.claude/lib/hook-common.sh"
HOOKS="$ROOT/.claude/hooks"

failures=0
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Run a command with every root and session variable removed, so a developer's
# real Claude Code session (CLAUDE_CODE_SESSION_ID is set there) cannot leak in.
CLEAN=(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_SESSIONID
  -u CLAUDE_PROJECT_DIR -u NASE_ROOT -u HOOK_EVENT_NAME)

# Evaluate a snippet in a fresh bash with the lib loaded and strict mode on, the
# way the strictest hooks run it. Extra env goes through CLEAN's `env`.
lib_eval() {
  local snippet="$1"
  shift
  "${CLEAN[@]}" "$@" bash -c 'set -euo pipefail; . "$1"; shift; eval "$1"' _ "$LIB" "$snippet"
}

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass "$name"
  else
    fail "$name (want '$want', got '$got')"
  fi
}

# ---------------------------------------------------------------------------
# The lib itself
# ---------------------------------------------------------------------------
assert_cmd "lib exists" test -f "$LIB"
assert_cmd "lib parses under bash -n" bash -n "$LIB"

# The lib must not turn on options or leak variables into its caller.
leak=$("${CLEAN[@]}" bash -c 'before=$(set +o); . "$1"; after=$(set +o); [ "$before" = "$after" ] && echo same || echo changed' _ "$LIB")
assert_eq "sourcing the lib changes no shell option" "same" "$leak"

# --- nase_root --------------------------------------------------------------
repo_a="$TMPROOT/repo-a"
repo_b="$TMPROOT/repo-b"
plain="$TMPROOT/plain"
mkdir -p "$repo_a" "$repo_b" "$plain"
git -C "$repo_a" init -q
git -C "$repo_b" init -q
repo_a_real=$(cd "$repo_a" && pwd -P)

got=$(cd "$repo_b" && lib_eval 'nase_root' NASE_ROOT="$repo_a")
assert_eq "nase_root honours NASE_ROOT over the cwd repo" "$repo_a" "$got"

got=$(cd "$repo_b" && lib_eval 'nase_root' CLAUDE_PROJECT_DIR="$repo_a")
assert_eq "nase_root ignores CLAUDE_PROJECT_DIR (the dispatcher exports NASE_ROOT)" "$(cd "$repo_b" && pwd -P)" "$(cd "$got" && pwd -P)"

got=$(cd "$repo_a" && lib_eval 'nase_root')
assert_eq "nase_root falls back to the git toplevel" "$repo_a_real" "$(cd "$got" && pwd -P)"

got=$(cd "$plain" && lib_eval 'nase_root' NASE_ROOT="")
rc=0
(cd "$plain" && lib_eval 'nase_root >/dev/null' NASE_ROOT="") >/dev/null 2>&1 || rc=$?
assert_eq "nase_root prints nothing outside a repo" "" "$got"
assert_eq "nase_root returns 1 outside a repo" "1" "$rc"

# --- nase_require -----------------------------------------------------------
assert_cmd "nase_require succeeds for present commands" lib_eval 'nase_require bash git'
rc=0
out=$(lib_eval 'nase_require bash definitely-not-a-command-xyz' 2>&1) || rc=$?
assert_eq "nase_require fails when one command is missing" "1" "$rc"
assert_eq "nase_require is silent" "" "$out"
assert_cmd "nase_require with no arguments succeeds" lib_eval 'nase_require'

# --- nase_session_id --------------------------------------------------------
sid() { # sid <json-or-empty> [env...]
  local json="$1"
  shift
  "${CLEAN[@]}" "$@" bash -c 'set -euo pipefail; . "$1"; nase_session_id "$2"' _ "$LIB" "$json"
}

assert_eq "session id: stdin JSON session_id wins over every env var" "from-json" \
  "$(sid '{"session_id":"from-json"}' CLAUDE_CODE_SESSION_ID=code CLAUDE_SESSION_ID=legacy CLAUDE_SESSIONID=legacy2)"
assert_eq "session id: stdin JSON sessionId is accepted" "camel" \
  "$(sid '{"sessionId":"camel"}' CLAUDE_CODE_SESSION_ID=code)"
assert_eq "session id: CLAUDE_CODE_SESSION_ID beats the legacy names" "code" \
  "$(sid '{}' CLAUDE_CODE_SESSION_ID=code CLAUDE_SESSION_ID=legacy CLAUDE_SESSIONID=legacy2)"
assert_eq "session id: CLAUDE_SESSION_ID beats CLAUDE_SESSIONID" "legacy" \
  "$(sid '' CLAUDE_SESSION_ID=legacy CLAUDE_SESSIONID=legacy2)"
assert_eq "session id: CLAUDE_SESSIONID is the last resort" "legacy2" \
  "$(sid '' CLAUDE_SESSIONID=legacy2)"
assert_eq "session id: empty when nothing is known" "" "$(sid '')"
assert_eq "session id: malformed JSON falls through to env" "code" \
  "$(sid 'not json' CLAUDE_CODE_SESSION_ID=code)"
assert_eq "session id: empty JSON field falls through to env" "code" \
  "$(sid '{"session_id":""}' CLAUDE_CODE_SESSION_ID=code)"
rc=0
"${CLEAN[@]}" bash -c 'set -e; . "$1"; x=$(nase_session_id); echo ok' _ "$LIB" >/dev/null 2>&1 || rc=$?
assert_eq "nase_session_id returns 0 when empty (safe under set -e)" "0" "$rc"

# --- nase_now_utc -----------------------------------------------------------
now=$(lib_eval 'nase_now_utc')
if [[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  pass "nase_now_utc prints an ISO-8601 UTC timestamp"
else
  fail "nase_now_utc prints an ISO-8601 UTC timestamp (got '$now')"
fi

# --- nase_append_jsonl ------------------------------------------------------
jl="$TMPROOT/deep/er/log.jsonl"
lib_eval 'nase_append_jsonl "'"$jl"'" "{\"a\":1}"; nase_append_jsonl "'"$jl"'" "{\"a\":2}"'
assert_eq "nase_append_jsonl creates the parent dir and appends lines" "2" "$(wc -l < "$jl" | tr -d ' ')"
assert_eq "nase_append_jsonl keeps the payload intact" '{"a":2}' "$(tail -1 "$jl")"

rc=0
lib_eval 'nase_append_jsonl "'"$jl"'" ""' >/dev/null 2>&1 || rc=$?
assert_eq "nase_append_jsonl rejects an empty line" "1" "$rc"
assert_eq "nase_append_jsonl wrote nothing for the empty line" "2" "$(wc -l < "$jl" | tr -d ' ')"

rc=0
lib_eval 'nase_append_jsonl ""' >/dev/null 2>&1 || rc=$?
assert_eq "nase_append_jsonl rejects a missing file argument" "2" "$rc"

mkdir -p "$TMPROOT/ro"
chmod 555 "$TMPROOT/ro"
rc=0
err=$(lib_eval 'nase_append_jsonl "'"$TMPROOT"'/ro/x.jsonl" "{}"' 2>&1 >/dev/null) || rc=$?
chmod 755 "$TMPROOT/ro"
if [ "$(id -u)" = "0" ]; then
  pass "nase_append_jsonl unwritable target (skipped as root)"
else
  assert_eq "nase_append_jsonl returns non-zero for an unwritable target" "1" "$rc"
  assert_eq "nase_append_jsonl keeps stderr quiet for an unwritable target" "" "$err"
fi

# Concurrent appends: 8 background writers x 40 lines must yield 320 intact lines.
cj="$TMPROOT/concurrent/log.jsonl"
for w in 1 2 3 4 5 6 7 8; do
  (
    # shellcheck source=.claude/lib/hook-common.sh
    . "$LIB"
    i=0
    while [ "$i" -lt 40 ]; do
      nase_append_jsonl "$cj" "{\"writer\":$w,\"seq\":$i,\"pad\":\"$(printf 'x%.0s' $(seq 1 120))\"}"
      i=$((i + 1))
    done
  ) &
done
wait
assert_eq "concurrent appends keep every line" "320" "$(wc -l < "$cj" | tr -d ' ')"
intact=$(jq -c 'select(.writer != null and .seq != null)' "$cj" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "concurrent appends never interleave (every line parses)" "320" "$intact"

# ---------------------------------------------------------------------------
# track-skill: an empty field must not shift the others
# ---------------------------------------------------------------------------
ws="$TMPROOT/ws-skill"
mkdir -p "$ws/workspace/stats"
skill_log="$ws/workspace/stats/skill-usage.jsonl"

printf '{"tool_input":{"skill":"nase:fsd"},"tool_response":{},"session_id":"sess-no-dur"}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" bash "$HOOKS/track-skill.sh" >/dev/null 2>&1
last=$(grep '"source":"skill-hook"' "$skill_log" | tail -1)
assert_eq "track-skill: empty duration keeps session_id in its own field" "sess-no-dur" \
  "$(printf '%s' "$last" | jq -r '.session_id // "MISSING"')"
assert_eq "track-skill: empty duration logs no duration_ms" "false" \
  "$(printf '%s' "$last" | jq 'has("duration_ms")')"

printf '{"tool_input":{"skill":"nase:fsd"},"tool_response":{"is_error":true},"duration_ms":1500,"session_id":"sess-dur"}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" bash "$HOOKS/track-skill.sh" >/dev/null 2>&1
last=$(grep '"source":"skill-hook"' "$skill_log" | tail -1)
assert_eq "track-skill: duration and session both land" "1500|sess-dur|tool_failed" \
  "$(printf '%s' "$last" | jq -r '"\(.duration_ms)|\(.session_id)|\(.event_type)"')"

printf '{"tool_input":{"skill":"nase:fsd"},"tool_response":{}}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" CLAUDE_CODE_SESSION_ID=env-code bash "$HOOKS/track-skill.sh" >/dev/null 2>&1
last=$(grep '"source":"skill-hook"' "$skill_log" | tail -1)
assert_eq "track-skill: falls back to CLAUDE_CODE_SESSION_ID" "env-code" \
  "$(printf '%s' "$last" | jq -r '.session_id // "MISSING"')"

printf '{"tool_input":{"skill":"nase:fsd"},"tool_response":{}}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" bash "$HOOKS/track-skill.sh" >/dev/null 2>&1
last=$(grep '"source":"skill-hook"' "$skill_log" | tail -1)
assert_eq "track-skill: no session anywhere omits session_id" "false" \
  "$(printf '%s' "$last" | jq 'has("session_id")')"

before=$(wc -l < "$skill_log" | tr -d ' ')
printf '{"tool_input":{"skill":"other:thing"},"tool_response":{}}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" bash "$HOOKS/track-skill.sh" >/dev/null 2>&1
assert_eq "track-skill: non-nase skill is ignored" "$before" "$(wc -l < "$skill_log" | tr -d ' ')"

# ---------------------------------------------------------------------------
# track-skill-prompt: only the first line of the prompt may name the skill
# ---------------------------------------------------------------------------
ws="$TMPROOT/ws-prompt"
mkdir -p "$ws/workspace/stats"
prompt_log="$ws/workspace/stats/skill-usage.jsonl"

run_prompt() { # run_prompt <event> <json> [env...]
  local event="$1" json="$2"
  shift 2
  printf '%s' "$json" | "${CLEAN[@]}" NASE_ROOT="$ws" HOOK_EVENT_NAME="$event" "$@" \
    bash "$HOOKS/track-skill-prompt.sh" >/dev/null 2>&1
}
count_prompt() { # count_prompt <skill>
  if [ -f "$prompt_log" ]; then
    jq -c --arg s "$1" 'select(.skill == $s and (.source == "prompt" or .source == "prompt-expansion"))' "$prompt_log" | wc -l | tr -d ' '
  else
    echo 0
  fi
}

run_prompt UserPromptSubmit '{"prompt":"please run this\n/nase:learn something"}'
assert_eq "prompt: a /nase: line after the first line is not an invocation" "0" "$(count_prompt learn)"

run_prompt UserPromptSubmit '{"prompt":"/nase:fsd do it\n/nase:learn later"}'
assert_eq "prompt: first-line skill is logged" "1" "$(count_prompt fsd)"
assert_eq "prompt: later-line skill in the same prompt is not logged" "0" "$(count_prompt learn)"

run_prompt UserPromptSubmit '{"prompt":"\n/nase:today"}'
assert_eq "prompt: a leading blank line does not promote line two" "0" "$(count_prompt today)"

run_prompt UserPromptExpansion '{"prompt":"context\n/nase:doctor"}'
assert_eq "prompt expansion: later-line skill is not logged" "0" "$(count_prompt doctor)"

run_prompt UserPromptExpansion '{"command_name":"nase:design"}'
assert_eq "prompt expansion: command_name still logs" "1" "$(count_prompt design)"

run_prompt UserPromptSubmit '{"prompt":"/nase:recap"}' CLAUDE_CODE_SESSION_ID=code-sess
assert_eq "prompt: falls back to CLAUDE_CODE_SESSION_ID" "code-sess" \
  "$(jq -r 'select(.skill == "recap" and .source == "prompt") | .session_id' "$prompt_log" | tail -1)"

run_prompt UserPromptSubmit '{"prompt":"/nase:wrap-up","session_id":"json-sess"}' CLAUDE_CODE_SESSION_ID=code-sess
assert_eq "prompt: stdin session_id beats CLAUDE_CODE_SESSION_ID" "json-sess" \
  "$(jq -r 'select(.skill == "wrap-up" and .source == "prompt") | .session_id' "$prompt_log" | tail -1)"

# ---------------------------------------------------------------------------
# track-kb-read and the other trackers: session fallback + appends
# ---------------------------------------------------------------------------
ws="$TMPROOT/ws-kbread"
mkdir -p "$ws/workspace/kb/projects"
printf '# x\n' > "$ws/workspace/kb/projects/example.md"
printf '{"tool_input":{"file_path":"%s"}}' "$ws/workspace/kb/projects/example.md" \
  | "${CLEAN[@]}" NASE_ROOT="$ws" CLAUDE_CODE_SESSION_ID=read-sess bash "$HOOKS/track-kb-read.sh" >/dev/null 2>&1
assert_eq "track-kb-read: records the read under CLAUDE_CODE_SESSION_ID" "read-sess" \
  "$(jq -r '.session // .session_id // "MISSING"' "$ws/workspace/stats/kb-usage.jsonl" 2>/dev/null | tail -1)"

ws="$TMPROOT/ws-fail"
mkdir -p "$ws"
printf '{"tool_name":"Bash","error":"boom token=abc123"}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" CLAUDE_CODE_SESSION_ID=fail-sess bash "$HOOKS/track-tool-failure.sh" >/dev/null 2>&1
assert_eq "track-tool-failure: session falls back to CLAUDE_CODE_SESSION_ID" "fail-sess" \
  "$(jq -r '.session' "$ws/workspace/stats/tool-failures.jsonl" 2>/dev/null | tail -1)"
assert_eq "track-tool-failure: error is still redacted" "false" \
  "$(jq 'any(.error; contains("abc123"))' "$ws/workspace/stats/tool-failures.jsonl" 2>/dev/null | tail -1)"

printf '{"error":"api down"}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" CLAUDE_CODE_SESSION_ID=fail-sess bash "$HOOKS/track-session-failure.sh" >/dev/null 2>&1
assert_eq "track-session-failure: session falls back to CLAUDE_CODE_SESSION_ID" "fail-sess" \
  "$(jq -r '.session' "$ws/workspace/stats/session-failures.jsonl" 2>/dev/null | tail -1)"

printf '{"agent_type":"worker"}' \
  | "${CLEAN[@]}" NASE_ROOT="$ws" CLAUDE_CODE_SESSION_ID=fail-sess bash "$HOOKS/track-subagent.sh" >/dev/null 2>&1
assert_eq "track-subagent: session falls back to CLAUDE_CODE_SESSION_ID" "fail-sess" \
  "$(jq -r '.session' "$ws/workspace/stats/subagent-usage.jsonl" 2>/dev/null | tail -1)"

# ---------------------------------------------------------------------------
# pre-edit-write-fact-force: once-per-session state keyed by the real session id
# ---------------------------------------------------------------------------
ff_tmp="$TMPROOT/ff"
mkdir -p "$ff_tmp"
ff_src="$TMPROOT/ff-src/app.py"
mkdir -p "$(dirname "$ff_src")"
touch "$ff_src"
ff_payload=$(printf '{"tool_input":{"file_path":"%s"}}' "$ff_src")

printf '%s' "$ff_payload" | "${CLEAN[@]}" TMPDIR="$ff_tmp" CLAUDE_CODE_SESSION_ID=ff-code bash "$HOOKS/pre-edit-write-fact-force.sh" >/dev/null 2>&1
assert_cmd "fact-force: state file is keyed by CLAUDE_CODE_SESSION_ID" test -f "$ff_tmp/nase-fact-force.ff-code.state"

printf '{"session_id":"ff-json","tool_input":{"file_path":"%s"}}' "$ff_src" \
  | "${CLEAN[@]}" TMPDIR="$ff_tmp" CLAUDE_CODE_SESSION_ID=ff-code bash "$HOOKS/pre-edit-write-fact-force.sh" >/dev/null 2>&1
assert_cmd "fact-force: stdin session_id beats the env var" test -f "$ff_tmp/nase-fact-force.ff-json.state"

# Two different PPIDs (separate bash -c parents) with one real session id must share state.
out_first=$(bash -c 'printf "%s" "$1" | "${@:2}" bash "$0"' "$HOOKS/pre-edit-write-fact-force.sh" "$ff_payload" \
  env -u CLAUDE_SESSION_ID -u CLAUDE_SESSIONID TMPDIR="$ff_tmp" CLAUDE_CODE_SESSION_ID=ff-shared)
out_second=$(bash -c 'printf "%s" "$1" | "${@:2}" bash "$0"' "$HOOKS/pre-edit-write-fact-force.sh" "$ff_payload" \
  env -u CLAUDE_SESSION_ID -u CLAUDE_SESSIONID TMPDIR="$ff_tmp" CLAUDE_CODE_SESSION_ID=ff-shared)
if [ -n "$out_first" ] && [ -z "$out_second" ]; then
  pass "fact-force: a real session id survives a changed parent pid (warns once)"
else
  fail "fact-force: a real session id survives a changed parent pid (first='${out_first:0:40}' second='${out_second:0:40}')"
fi

printf '%s' "$ff_payload" | "${CLEAN[@]}" TMPDIR="$ff_tmp" bash "$HOOKS/pre-edit-write-fact-force.sh" >/dev/null 2>&1
if ls "$ff_tmp"/nase-fact-force.[0-9]*.state >/dev/null 2>&1; then
  pass "fact-force: falls back to the parent pid with no session id"
else
  fail "fact-force: falls back to the parent pid with no session id"
fi

printf '{"session_id":"../../evil","tool_input":{"file_path":"%s"}}' "$ff_src" \
  | "${CLEAN[@]}" TMPDIR="$ff_tmp" bash "$HOOKS/pre-edit-write-fact-force.sh" >/dev/null 2>&1
assert_cmd "fact-force: a hostile session id cannot escape the state dir" test ! -e "$ff_tmp/../evil.state"

# ---------------------------------------------------------------------------
# Lib missing or broken: guards fail closed (exit 2), the rest fail open (exit 0)
# ---------------------------------------------------------------------------
GUARDS=(jira-write-guard atlassian-generic-write-guard confluence-size-guard
  external-cli-write-guard slack-send-guard block-dangerous-git)
LIFECYCLE=(track-kb-read track-skill track-skill-prompt track-subagent track-tool-failure
  track-session-failure pre-compact-archive session-start stop-todos stop-backup
  worktree-log prose-lint-guard pre-edit-write-fact-force)

stage_hook() { # stage_hook <name> <lib-mode: missing|return1|syntax>
  local name="$1" mode="$2" dir
  dir=$(mktemp -d "$TMPROOT/stage.XXXXXX")
  mkdir -p "$dir/.claude/hooks" "$dir/.claude/lib" "$dir/.claude/scripts"
  cp "$HOOKS/$name.sh" "$dir/.claude/hooks/$name.sh"
  case "$mode" in
    return1) printf 'return 1\n' > "$dir/.claude/lib/hook-common.sh" ;;
    syntax) printf 'nase_root() {{{ if then\n' > "$dir/.claude/lib/hook-common.sh" ;;
  esac
  printf '%s' "$dir"
}

payload='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls","file_path":"/x/app.py"},"prompt":"hi"}'
for mode in missing return1 syntax; do
  for name in "${GUARDS[@]}"; do
    dir=$(stage_hook "$name" "$mode")
    rc=0
    printf '%s' "$payload" | "${CLEAN[@]}" NASE_ROOT="$dir" TMPDIR="$dir" bash "$dir/.claude/hooks/$name.sh" >/dev/null 2>&1 || rc=$?
    assert_eq "guard $name fails closed when the lib is $mode" "2" "$rc"
  done
  for name in "${LIFECYCLE[@]}"; do
    dir=$(stage_hook "$name" "$mode")
    rc=0
    printf '%s' "$payload" | "${CLEAN[@]}" NASE_ROOT="$dir" bash "$dir/.claude/hooks/$name.sh" >/dev/null 2>&1 || rc=$?
    assert_eq "hook $name fails open when the lib is $mode" "0" "$rc"
  done
done

# A guard with a missing jq still blocks with its own message (jq check goes through the lib).
for name in slack-send-guard atlassian-generic-write-guard confluence-size-guard external-cli-write-guard; do
  out=$(printf '%s' "$payload" | env -i PATH=/nonexistent-nase-jq-test NASE_ROOT="$TMPROOT" "$(command -v bash)" "$HOOKS/$name.sh" 2>&1)
  rc=$?
  if [ "$rc" = "2" ] && [[ "$out" == *"jq is required"* ]]; then
    pass "guard $name blocks with a clear message when jq is missing"
  else
    fail "guard $name blocks with a clear message when jq is missing (rc=$rc out=$out)"
  fi
done

# ---------------------------------------------------------------------------
# Every hook that honours NASE_ROOT must write only under NASE_ROOT
# ---------------------------------------------------------------------------
snapshot() { # snapshot <dir>
  (
    cd "$1" || exit 1
    find . -path ./.git -prune -o -print | LC_ALL=C sort
    find . -path ./.git -prune -o -type f -exec cksum {} + | LC_ALL=C sort
  )
}

unrelated_git="$TMPROOT/unrelated-git"
unrelated_plain="$TMPROOT/unrelated-plain"
mkdir -p "$unrelated_git" "$unrelated_plain"
git -C "$unrelated_git" init -q
printf 'keep\n' > "$unrelated_git/keep.txt"
printf 'keep\n' > "$unrelated_plain/keep.txt"
fake_home="$TMPROOT/home"
fake_tmp="$TMPROOT/tmp-loop"
mkdir -p "$fake_home" "$fake_tmp"

loop_ws="$TMPROOT/loop-ws"
mkdir -p "$loop_ws/workspace/logs" "$loop_ws/workspace/stats"
git -C "$loop_ws" init -q

root_hooks=()
for f in "$HOOKS"/*.sh; do
  if grep -qE 'NASE_ROOT|nase_root' "$f"; then
    root_hooks+=("$f")
  fi
done
if [ "${#root_hooks[@]}" -ge 12 ]; then
  pass "found ${#root_hooks[@]} hooks that honour NASE_ROOT"
else
  fail "expected at least 12 hooks that honour NASE_ROOT, found ${#root_hooks[@]}"
fi

jira_payload='{"session_id":"loop","tool_name":"mcp__x__transitionJiraIssue","tool_input":{"issueIdOrKey":"X-1"}}'
for hook in "${root_hooks[@]}"; do
  name=$(basename "$hook" .sh)
  for cwd_kind in git plain; do
    if [ "$cwd_kind" = git ]; then cwd="$unrelated_git"; else cwd="$unrelated_plain"; fi
    before=$(snapshot "$cwd")
    git_before=""
    [ "$cwd_kind" = git ] && git_before=$(git -C "$cwd" status --porcelain)
    for p in "$payload" "$jira_payload"; do
      (
        cd "$cwd" || exit 1
        printf '%s' "$p" | env -u CLAUDE_PROJECT_DIR HOME="$fake_home" TMPDIR="$fake_tmp" \
          NASE_ROOT="$loop_ws" bash "$hook" >/dev/null 2>&1
      ) || true
    done
    after=$(snapshot "$cwd")
    git_after=""
    [ "$cwd_kind" = git ] && git_after=$(git -C "$cwd" status --porcelain)
    if [ "$before" = "$after" ] && [ "$git_before" = "$git_after" ]; then
      pass "$name leaves an unrelated $cwd_kind cwd untouched"
    else
      fail "$name wrote into an unrelated $cwd_kind cwd"
      diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
    fi
  done
done
assert_cmd "the loop ran hooks against NASE_ROOT (workspace log created)" \
  bash -c 'ls "$1"/workspace/logs/*.md >/dev/null 2>&1' _ "$loop_ws"

# ---------------------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
  printf '\nhook-common tests passed.\n'
  exit 0
fi
printf '\n%d hook-common assertion(s) failed.\n' "$failures" >&2
exit 1
