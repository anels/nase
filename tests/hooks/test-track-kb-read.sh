#!/usr/bin/env bash
# Regression tests for .claude/hooks/track-kb-read.sh.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/track-kb-read.sh"
LOGGER="$ROOT/.claude/scripts/kb-usage-log.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/workspace/kb/general" "$FIXTURE/workspace/kb/projects" "$FIXTURE/workspace/tmp"
printf '# read fixture\n' > "$FIXTURE/workspace/kb/general/read.md"
printf 'select 1;\n' > "$FIXTURE/workspace/kb/general/data.sql"
printf '# domain map\n' > "$FIXTURE/workspace/kb/.domain-map.md"
printf '# unsupported\n' > "$FIXTURE/workspace/kb/projects/notes.txt"
mkdir -p "$FIXTURE/workspace/docs"
printf '# not kb\n' > "$FIXTURE/workspace/docs/not-kb.md"

pass=0
fail=0

pass_msg() {
  pass=$((pass + 1))
  printf 'PASS  %s\n' "$1"
}

fail_msg() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1" >&2
}

assert_jq() {
  local desc="$1"
  local expr="$2"
  local file="$FIXTURE/workspace/stats/kb-usage.jsonl"
  if [ -f "$file" ] && jq -e "$expr" "$file" >/dev/null 2>&1; then
    pass_msg "$desc"
  else
    fail_msg "$desc"
    [ -f "$file" ] && cat "$file" >&2
  fi
}

assert_count() {
  local desc="$1"
  local expected="$2"
  local expr="$3"
  local file="$FIXTURE/workspace/stats/kb-usage.jsonl"
  local actual=0
  if [ -f "$file" ]; then
    actual=$(jq -s "$expr" "$file" 2>/dev/null || echo "jq-error")
  fi
  if [ "$actual" = "$expected" ]; then
    pass_msg "$desc"
  else
    fail_msg "$desc (expected $expected, got $actual)"
    [ -f "$file" ] && cat "$file" >&2
  fi
}

run_hook() {
  local file_path="$1"
  local session="$2"
  printf '{"tool_input":{"file_path":"%s"}}' "$file_path" \
    | NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="$session" bash "$HOOK" >/dev/null 2>&1
}

activate_skill() {
  local skill="$1"
  local session="$2"
  NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="$session" \
    python3 "$LOGGER" activate --skill "$skill" --source test >/dev/null 2>&1
}

activate_skill "fsd" "hook-active"
run_hook "workspace/kb/general/read.md" "hook-active"
assert_jq "T1: relative KB read records active skill" \
  'select(.skill == "fsd" and .file == "workspace/kb/general/read.md" and .access == "read" and .source == "read-hook" and .session == "hook-active")'

printf '{"session_id":"input-session","tool_input":{"file_path":"workspace/kb/general/read.md"}}' \
  | NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="different-env-session" bash "$HOOK" >/dev/null 2>&1
assert_jq "T1b: hook input session wins over environment fallback" \
  'select(.skill == "unknown" and .file == "workspace/kb/general/read.md" and .session == "input-session")'

run_hook "$FIXTURE/workspace/kb/general/data.sql" "hook-unknown"
assert_jq "T2: absolute SQL KB read records unknown skill" \
  'select(.skill == "unknown" and .file == "workspace/kb/general/data.sql" and .access == "read" and .source == "read-hook" and .session == "hook-unknown")'

before=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
run_hook "workspace/kb/.domain-map.md" "hook-skip"
run_hook "workspace/docs/not-kb.md" "hook-skip"
run_hook "workspace/kb/projects/notes.txt" "hook-skip"
after=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
if [ "$before" = "$after" ]; then
  pass_msg "T3: skips domain map, non-KB paths, and unsupported extensions"
else
  fail_msg "T3: skip rules changed ledger count (before $before, after $after)"
fi

activate_skill "design" "hook-dedupe"
run_hook "workspace/kb/general/read.md" "hook-dedupe"
run_hook "workspace/kb/general/read.md" "hook-dedupe"
assert_count "T4: dedupes repeated same-file reads in a short window" "1" \
  '[.[] | select(.session == "hook-dedupe" and .file == "workspace/kb/general/read.md" and .access == "read")] | length'

env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_SESSIONID NASE_ROOT="$FIXTURE" \
  python3 "$LOGGER" activate --skill "learn" --source test >/dev/null 2>&1
run_hook "workspace/kb/general/read.md" "hook-fallback"
assert_jq "T5: falls back to active skill when hook sessions differ" \
  'select(.skill == "learn" and .file == "workspace/kb/general/read.md" and .access == "read" and .source == "read-hook" and .session == "hook-fallback")'

# ── Grep, Glob and Bash reach the KB too ─────────────────────────────────────
printf '# other fixture\n' > "$FIXTURE/workspace/kb/projects/other.md"

run_payload() {
  local session="$1" payload="$2"
  printf '%s' "$payload" \
    | NASE_ROOT="$FIXTURE" CLAUDE_CODE_SESSION_ID="$session" bash "$HOOK" >/dev/null 2>&1
}

payload=$(jq -nc --arg p "$FIXTURE/workspace/kb/general/read.md" \
  '{tool_name:"Read",tool_input:{file_path:$p},tool_response:{file:{content:"twelve chars"}}}')
run_payload "hook-chars" "$payload"
assert_jq "T6: a Read records the characters of the file text, not of the JSON around it" \
  'select(.session == "hook-chars" and .source == "read-hook" and .chars == 12)'

payload=$(jq -nc --arg p "$FIXTURE/workspace/kb/general/read.md" '{tool_name:"Read",tool_input:{file_path:$p}}')
run_payload "hook-no-response" "$payload"
assert_jq "T6b: a Read with no response records no size" \
  'select(.session == "hook-no-response" and (has("chars") | not))'

payload=$(jq -nc --arg p "$FIXTURE/workspace/kb/general/read.md" '{tool_name:"Read",tool_input:{file_path:$p},tool_response:{file:{content:"first chunk"}}}')
run_payload "hook-chunks" "$payload"
payload=$(jq -nc --arg p "$FIXTURE/workspace/kb/general/read.md" '{tool_name:"Read",tool_input:{file_path:$p},tool_response:{file:{content:"a longer second chunk"}}}')
run_payload "hook-chunks" "$payload"
assert_count "T6c: two chunked Reads of one file both count" "2" \
  '[.[] | select(.session == "hook-chunks")] | length'

payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"grep -n foo workspace/kb/projects/other.md | head -5"}}')
run_payload "hook-bash" "$payload"
assert_jq "T7: a Bash grep on a KB file records a read with the bash source" \
  'select(.session == "hook-bash" and .file == "workspace/kb/projects/other.md" and .access == "read" and .source == "bash-hook")'

payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"cat notes > workspace/kb/projects/written.md"}}')
run_payload "hook-bash-write" "$payload"
payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"rm workspace/kb/projects/other.md"}}')
run_payload "hook-bash-write" "$payload"
payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"sed -i s/a/b/ workspace/kb/projects/other.md"}}')
run_payload "hook-bash-write" "$payload"
assert_count "T8: Bash commands that write or remove are not reads" "0" \
  '[.[] | select(.session == "hook-bash-write")] | length'

payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"ls /tmp"}}')
before=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
run_payload "hook-bash-none" "$payload"
after=$(jq -s 'length' "$FIXTURE/workspace/stats/kb-usage.jsonl" 2>/dev/null || echo 0)
if [ "$before" = "$after" ]; then
  pass_msg "T9: a Bash command that never names the KB records nothing"
else
  fail_msg "T9: unrelated Bash command changed the ledger (before $before, after $after)"
fi

payload=$(jq -nc '{tool_name:"Grep",tool_input:{pattern:"foo",path:"workspace/kb"},tool_response:"workspace/kb/general/read.md\nworkspace/kb/projects/other.md"}')
run_payload "hook-grep" "$payload"
assert_count "T10: a Grep aimed at the KB records every KB file in its result" "2" \
  '[.[] | select(.session == "hook-grep" and .access == "search-result" and .source == "grep-hook")] | length'

payload=$(jq -nc '{tool_name:"Grep",tool_input:{pattern:"foo",path:".claude/docs"},tool_response:"a line that mentions workspace/kb/projects/other.md"}')
run_payload "hook-grep-docs" "$payload"
assert_count "T11: a Grep over the docs does not count the KB paths it prints" "0" \
  '[.[] | select(.session == "hook-grep-docs")] | length'

# A write stage is skipped on its own, so the read stages around it still count.
payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"cat workspace/kb/projects/other.md | tee /tmp/copy"}}')
run_payload "hook-stage-pipe" "$payload"
assert_count "T12: a read piped into tee is still a read" "1" \
  '[.[] | select(.session == "hook-stage-pipe" and .file == "workspace/kb/projects/other.md")] | length'

payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"cat workspace/kb/projects/other.md; cp /tmp/a /tmp/b"}}')
run_payload "hook-stage-chain" "$payload"
assert_count "T12b: a read chained before an unrelated cp is still a read" "1" \
  '[.[] | select(.session == "hook-stage-chain" and .file == "workspace/kb/projects/other.md")] | length'

payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"cat workspace/kb/projects/other.md && rm workspace/kb/general/read.md"}}')
run_payload "hook-stage-rm" "$payload"
assert_count "T12c: only the stage that removes a file is skipped" "1" \
  '[.[] | select(.session == "hook-stage-rm")] | length'
assert_count "T12d: the removed file is not recorded" "0" \
  '[.[] | select(.session == "hook-stage-rm" and .file == "workspace/kb/general/read.md")] | length'

for verb in "install -m 644 /tmp/a workspace/kb/projects/other.md" "rsync /tmp/a workspace/kb/projects/other.md" "truncate -s 0 workspace/kb/projects/other.md" "git restore workspace/kb/projects/other.md"; do
  payload=$(jq -nc --arg c "$verb" '{tool_name:"Bash",tool_input:{command:$c}}')
  run_payload "hook-more-writers" "$payload"
done
assert_count "T13: install, rsync, truncate and git restore are not reads" "0" \
  '[.[] | select(.session == "hook-more-writers")] | length'

# The response of a content-mode Grep is JSON. A newline inside it must not glue two
# paths into one ledger row, and a path that is only mentioned in matched text is not
# counted.
payload=$(jq -nc '{tool_name:"Grep",tool_input:{pattern:"foo",path:"workspace/kb",output_mode:"content"},tool_response:{mode:"content",content:"workspace/kb/general/read.md:5:Related: workspace/kb/projects/zzz.md\nworkspace/kb/projects/other.md:9:text"}}')
run_payload "hook-grep-content" "$payload"
assert_count "T14: a content-mode Grep records the files that matched" "2" \
  '[.[] | select(.session == "hook-grep-content")] | length'
assert_count "T14b: a path only named in matched text is not recorded" "0" \
  '[.[] | select(.session == "hook-grep-content" and (.file | test("zzz")))] | length'
assert_count "T14c: no recorded path holds a backslash" "0" \
  '[.[] | select(.session == "hook-grep-content" and (.file | contains("\\")))] | length'

payload=$(jq -nc '{tool_name:"Grep",tool_input:{pattern:"foo",path:"workspace/kb"},tool_response:{mode:"files_with_matches",filenames:["workspace/kb/general/read.md","workspace/kb/projects/other.md"],numFiles:2}}')
run_payload "hook-grep-files" "$payload"
assert_count "T15: a files_with_matches Grep records every listed file" "2" \
  '[.[] | select(.session == "hook-grep-files" and .source == "grep-hook")] | length'

payload=$(jq -nc '{tool_name:"Glob",tool_input:{pattern:"workspace/kb/projects/*.md"},tool_response:{filenames:["workspace/kb/projects/other.md"],numFiles:1}}')
run_payload "hook-glob" "$payload"
assert_jq "T16: a Glob over the KB records the matched file" \
  'select(.session == "hook-glob" and .file == "workspace/kb/projects/other.md" and .source == "grep-hook")'

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
