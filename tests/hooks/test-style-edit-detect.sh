#!/usr/bin/env bash
# Regression tests for .claude/hooks/style-edit-detect.sh
#
# Run from repo root:  bash tests/hooks/test-style-edit-detect.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/style-edit-detect.sh"

pass=0
fail=0

run_case() {
  local name=$1
  local prompt=$2
  local expected=$3
  local out rc

  out=$(printf '{"prompt":%s}' "$(jq -Rn --arg p "$prompt" '$p')" | bash "$HOOK")
  rc=$?

  if [[ "$rc" -ne 0 ]]; then
    printf 'FAIL  %-38s rc=%s\n' "$name" "$rc"
    fail=$((fail+1))
    return
  fi

  if [[ "$expected" == "match" ]]; then
    if jq -e '
      .hookSpecificOutput.hookEventName == "UserPromptSubmit"
      and (.hookSpecificOutput.additionalContext | contains("style-edit-detect"))
      and (.hookSpecificOutput.additionalContext | contains("[STYLE-DELTA]"))
      and (.hookSpecificOutput.additionalContext | contains("communication-style.md directly"))
    ' >/dev/null 2>&1 <<<"$out"; then
      printf 'PASS  %-38s match\n' "$name"
      pass=$((pass+1))
    else
      printf 'FAIL  %-38s expected match, got: %s\n' "$name" "$out"
      fail=$((fail+1))
    fi
  else
    if [[ -z "$out" ]]; then
      printf 'PASS  %-38s no-match\n' "$name"
      pass=$((pass+1))
    else
      printf 'FAIL  %-38s expected no output, got: %s\n' "$name" "$out"
      fail=$((fail+1))
    fi
  fi
}

run_case "slack draft edit" 'change "hello" to "hey" in the Slack draft' match
run_case "Chinese slack draft edit" "下次这个 Slack 草稿不要说 certainly，改成 sure" match
run_case "PR shorthand edit" "PR: next time make it shorter" match
run_case "PR mid-sentence edit" "next time make the PR shorter" match
run_case "DM shorthand edit" "DM: next time use sure instead of certainly" match
run_case "inline comment edit" "inline comment: next time drop the intro" match
run_case "external doc edit" "external doc: next time make it shorter" match
run_case "announcement edit" "announcement: next time make it shorter" match
run_case "internal doc negative" "next time make the doc shorter" no-match
run_case "code edit negative" "change the parser to handle quotes in src/main.py" no-match
run_case "document fragment negative" "next time fix the documentId output" no-match
run_case "word fragment negative" "next time fix the program output" no-match

run_case "context says ignore otherwise" 'make that Slack message shorter and less formal' match
out=$(printf '{"prompt":%s}' "$(jq -Rn --arg p 'make that Slack message shorter and less formal' '$p')" | bash "$HOOK")
if jq -e '.hookSpecificOutput.additionalContext | contains("only if the user is correcting a draft you wrote") and contains("style-delta-capture.md")' >/dev/null 2>&1 <<<"$out"; then
  printf 'PASS  %-38s\n' "context scoped to own drafts"
  pass=$((pass+1))
else
  printf 'FAIL  %-38s got: %s\n' "context scoped to own drafts" "$out"
  fail=$((fail+1))
fi

# Real corrections of a draft the assistant wrote must fire.
run_case "tone cue on Slack message" "make that Slack message shorter and less formal" match
run_case "tone cue and PR description" "too wordy, rewrite the PR description" match
run_case "next time with bare PR" "next time make the PR shorter" match
run_case "Chinese PR description" "这个 PR 描述太 AI 了，精简一下" match
run_case "bare PR title tightening" "the PR title is too long, shorten it" match
run_case "Slack reply rephrase" "reply in the thread sounds robotic, rephrase the Slack reply" match
run_case "Chinese Slack message" "别这样写 Slack 消息，太啰嗦，精简" match
run_case "don't say in my DMs" "don't say \"just wanted to flag\" in my DMs, from now on" match
run_case "review comment too harsh" "rephrase the review comment, it is too harsh" match
run_case "PR body trim" "that PR body is too verbose, trim it" match
run_case "drop greeting from message" "drop the greeting from the Slack message" match
run_case "bare DM with tone cue" "rewrite it as two sentences, the DM is too long" match
run_case "too formal for a DM" "too formal for a DM, make it casual" match

# Code and tooling work that merely mentions a PR, message, or draft must stay quiet.
run_case "message in log formatter" "make the message shorter in the log formatter" no-match
run_case "retry in PR build script" "next time use a retry in the PR build script" no-match
run_case "drop import then open PR" "drop the unused import, then open the pr" no-match
run_case "remove flag and update PR" "remove the deprecated flag from the CLI and update the PR" no-match
run_case "error message in validator" "make the error message shorter in the validator" no-match
run_case "commit message check in CI" "the commit message check is too verbose in CI logs, drop the extra line" no-match
run_case "rename draft folder" "rename the draft folder and remove the old one" no-match
run_case "review comment parser bug" "the review comment parser drops the last line, fix it" no-match
run_case "DM handler less verbose" "make the DM handler less verbose" no-match
run_case "PR too big" "this PR is too big, split it" no-match
run_case "open PR make build shorter" "open a PR and make the build shorter" no-match
run_case "Chinese drop param then PR" "去掉这个函数里没用的参数然后提 PR" no-match
run_case "summarize this PR" "please summarize this PR" no-match
run_case "empty prompt" "" no-match

# Bare "the message" and Chinese bare artifacts count when a tone cue backs them up.
run_case "bare message with tone cue" "the message is too formal, rewrite it" match
run_case "Chinese bare message, AI flavour" "这条消息太 AI 味了，改成更口语的" match
run_case "Chinese bare reply, too wordy" "那个回复太啰嗦，精简一下" match
run_case "PR build and verbose test" "fix the PR build, the test is too verbose" no-match
run_case "Chinese message queue code" "把这个消息队列的重试逻辑精简一下" no-match
run_case "Chinese comment parser code" "这个评论解析器太啰嗦，精简一下" no-match

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
