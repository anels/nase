#!/usr/bin/env bash
# Regression tests for .claude/hooks/prose-lint-guard.sh
#
# The hook is a blocking PreToolUse guard on Slack draft bodies. What has to hold:
# a gate finding blocks (exit 2) with an actionable message, clean prose passes,
# the documented escape hatch works, and every shape that carries no reviewable
# body passes instead of blocking a draft on the guard's own parsing.
#
# Run from repo root:  bash tests/hooks/test-prose-lint-guard.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK="$ROOT/.claude/hooks/prose-lint-guard.sh"
SLOP="$ROOT/tests/fixtures/prose/slack-slop.md"
CLEAN="$ROOT/tests/fixtures/prose/slack-clean.md"

pass=0
fail=0

ok() {
  printf 'PASS  %s\n' "$1"
  pass=$((pass + 1))
}

bad() {
  printf 'FAIL  %s%s\n' "$1" "${2:+: $2}" >&2
  fail=$((fail + 1))
}

# Feeds one PreToolUse payload to the hook and reports rc plus stderr.
run_hook() {
  local payload="$1"
  shift
  RC=0
  ERR=$(printf '%s' "$payload" | env "$@" bash "$HOOK" 2>&1 >/dev/null) || RC=$?
}

payload_with() {
  local key="$1" file="$2"
  jq -Rs --arg key "$key" '{tool_input: {($key): .}}' < "$file"
}

expect_silent_pass() {
  if [[ "$RC" -eq 0 && -z "$ERR" ]]; then
    ok "$1"
  else
    bad "$1" "rc=$RC err=$ERR"
  fi
}

# --- blocking path --------------------------------------------------------
# slack-slop.md carries four gate findings (literal bullet, bold-term definition,
# emoji-led bullet, trailing bare URL), so this is the case the guard exists for.
run_hook "$(payload_with text "$SLOP")"
if [[ "$RC" -eq 2 ]] \
  && grep -q 'BLOCKED by prose-lint-guard' <<<"$ERR" \
  && grep -q 'SLK-BULLET' <<<"$ERR" \
  && grep -q 'NASE_PROSE_LINT=0' <<<"$ERR"; then
  ok "gate finding blocks with the rule and the escape hatch named"
else
  bad "gate finding blocks with the rule and the escape hatch named" "rc=$RC"
fi

# The body arrives under a different key depending on which draft tool fires, so
# every key the hook claims to read has to actually reach the linter.
for key in text message markdown_text; do
  run_hook "$(payload_with "$key" "$SLOP")"
  if [[ "$RC" -eq 2 ]]; then
    ok "body under .$key is linted"
  else
    bad "body under .$key is linted" "rc=$RC"
  fi
done

# --- passing paths --------------------------------------------------------
run_hook "$(payload_with text "$CLEAN")"
expect_silent_pass "clean prose passes silently"

run_hook "$(payload_with text "$SLOP")" NASE_PROSE_LINT=0
expect_silent_pass "NASE_PROSE_LINT=0 escapes the gate"

# A payload with nothing to review must not block a draft. These are the shapes
# the hook's own jq filter is written to fall through on.
run_hook '{"tool_input":{}}'
expect_silent_pass "absent body passes"

run_hook '{"tool_input":{"text":""}}'
expect_silent_pass "empty body passes"

# `select(type == "string")` exists for this: a structured Block Kit payload has no
# prose the linter can score, and guessing one would block on the guard's parsing.
run_hook '{"tool_input":{"text":{"blocks":[]}}}'
expect_silent_pass "non-string body passes rather than blocking on shape"

run_hook 'not json at all'
if [[ "$RC" -eq 0 ]]; then
  ok "unparseable input fails open"
else
  bad "unparseable input fails open" "rc=$RC err=$ERR"
fi

# A payload that carries fields but no body is a renamed field, not "nothing to review".
# It still has to fail open, but silently failing open means every later draft ships
# unlinted with nothing saying the guard stopped reading.
run_hook '{"tool_input":{"channel_id":"C0123","body_markdown":"hi"}}'
if [[ "$RC" -eq 0 ]] && grep -q 'found no draft body' <<<"$ERR" \
  && grep -q 'body_markdown' <<<"$ERR"; then
  ok "a payload with fields but no known body field fails open with a notice"
else
  bad "a payload with fields but no known body field fails open with a notice" "rc=$RC err=$ERR"
fi

# --- surface selection ----------------------------------------------------
# The linter scores DMs and channels as separate surfaces, and channel_id already says
# which this is. Hardcoding one applies the wrong rule set the moment a rule is scoped
# to a single Slack surface.
# The surface only reaches stderr on the blocking path, so the body needs a real gate
# finding. A literal bullet is the smallest one, and SLK-BULLET covers both Slack surfaces.
surface_for() {
  local channel="$1"
  printf '{"tool_input":{"channel_id":"%s","message":"\\u2022 item"}}' "$channel" \
    | bash "$HOOK" 2>&1 >/dev/null | sed -n 's/^Surface: \([a-z-]*\) .*/\1/p'
}

expect_surface() {
  local name="$1" channel="$2" want="$3" got
  got=$(surface_for "$channel")
  if [[ "$got" == "$want" ]]; then
    ok "$name"
  else
    bad "$name" "channel=$channel want=$want got=${got:-<none>}"
  fi
}

expect_surface "a user ID target is scored as a DM" "U024BE7LH" "slack-dm"
expect_surface "an enterprise user ID target is scored as a DM" "W024BE7LH" "slack-dm"
expect_surface "an opened DM conversation is scored as a DM" "D024BE7LH" "slack-dm"
expect_surface "a public channel is scored as a channel" "C024BE7LH" "slack-channel"
expect_surface "an ambiguous G-prefixed ID stays on the channel rules" "G024BE7LH" "slack-channel"
expect_surface "an absent channel_id falls back to the channel rules" "" "slack-channel"

# --- fail-open on missing infrastructure ----------------------------------
# The contract under test is the observable one: with the linter unreachable, a body
# that would otherwise block gets through. A quality check must never be the reason a
# draft cannot be written. (The hook reaches that outcome by more than one route -
# the `command -v` probes and the `RC -ne 1` branch - so this pins the outcome, not
# any single line.)
STUB_BIN=$(mktemp -d)
trap 'rm -rf "$STUB_BIN"' EXIT
for tool in bash git mktemp rm cat; do
  real=$(command -v "$tool") || continue
  # A builtin resolves to a bare name rather than a path; linking that would make a
  # dangling symlink and the tool would be missing for a reason the test never meant.
  [[ "$real" == /* ]] && ln -s "$real" "$STUB_BIN/$tool"
done
run_hook "$(payload_with text "$SLOP")" "PATH=$STUB_BIN"
expect_silent_pass "an unreachable linter lets a would-be-blocked body through"

printf '\n--- %s pass, %s fail ---\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
