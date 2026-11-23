#!/usr/bin/env bash
# Routing test for the matchers in .claude/settings.json.
#
# The hook tests feed payloads straight to each script, so they prove what a guard does and
# say nothing about whether Claude Code will ever call it. A matcher that misses a tool name
# disables the guard with every test still green. This test resolves real tool names against
# the live matchers (tests/lib/hook_matcher.py) and compares the exact set of scripts.
#
# Expected sets name every script, not "at least": a guard that starts firing on a tool it
# should not see fails here too.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

HELPER="$ROOT/tests/lib/hook_matcher.py"
SETTINGS="$ROOT/.claude/settings.json"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

SLACK=mcp__plugin_slack_slack__
ATL=mcp__plugin_atlassian_atlassian__
GIT_GUARDS=block-dangerous-git.sh,external-cli-write-guard.sh
EDIT_PRE=daily-log-format-guard.sh,pre-edit-write-fact-force.sh
EDIT_POST=post-edit-ruff.sh,post-edit-shellcheck.sh

# event | tool name | expected scripts, sorted and comma-joined (empty = no hook)
ROUTES="
PreToolUse|Bash|$GIT_GUARDS
PreToolUse|Monitor|$GIT_GUARDS
PreToolUse|PowerShell|$GIT_GUARDS
PreToolUse|Edit|$EDIT_PRE
PreToolUse|Write|$EDIT_PRE
PreToolUse|MultiEdit|$EDIT_PRE
PreToolUse|${SLACK}slack_send_message|slack-send-guard.sh
PreToolUse|${SLACK}slack_schedule_message|slack-send-guard.sh
PreToolUse|${SLACK}slack_create_canvas|slack-send-guard.sh
PreToolUse|${SLACK}slack_update_canvas|slack-send-guard.sh
PreToolUse|${SLACK}slack_add_reaction|slack-send-guard.sh
PreToolUse|${SLACK}slack_create_conversation|slack-send-guard.sh
PreToolUse|${SLACK}slack_add_list_record|slack-send-guard.sh
PreToolUse|${SLACK}slack_update_list_record|slack-send-guard.sh
PreToolUse|${SLACK}slack_create_list|slack-send-guard.sh
PreToolUse|${SLACK}slack_update_list|slack-send-guard.sh
PreToolUse|${SLACK}slack_complete_file_upload|slack-send-guard.sh
PreToolUse|${SLACK}slack_send_message_draft|prose-lint-guard.sh
PreToolUse|${SLACK}slack_read_channel|
PreToolUse|${SLACK}slack_search_public|
PreToolUse|${ATL}addOrEditJiraIssueComment|jira-write-guard.sh
PreToolUse|${ATL}transitionJiraIssue|jira-write-guard.sh
PreToolUse|${ATL}createJiraIssue|jira-write-guard.sh
PreToolUse|${ATL}editJiraIssue|jira-write-guard.sh
PreToolUse|${ATL}addGraphContext|jira-write-guard.sh
PreToolUse|${ATL}createConfluenceContent|confluence-size-guard.sh
PreToolUse|${ATL}updateConfluenceContent|confluence-size-guard.sh
PreToolUse|${ATL}executeWrite|atlassian-generic-write-guard.sh
PreToolUse|${ATL}executeDestructive|atlassian-generic-write-guard.sh
PreToolUse|${ATL}executeRead|
PreToolUse|${ATL}getJiraIssue|
PreToolUse|${ATL}searchConfluence|
PreToolUse|Read|
PreToolUse|Grep|
PreToolUse|Skill|
PostToolUse|Read|track-kb-read.sh
PostToolUse|Grep|track-kb-read.sh
PostToolUse|Glob|track-kb-read.sh
PostToolUse|Bash|track-kb-read.sh
PostToolUse|Skill|track-skill.sh
PostToolUse|Edit|$EDIT_POST
PostToolUse|Write|$EDIT_POST
PostToolUse|MultiEdit|$EDIT_POST
PostToolUse|${SLACK}slack_send_message_draft|
"

# Prints one line per mismatch; the caller counts lines.
check_table() {
  local settings="$1" event tool want got
  while IFS='|' read -r event tool want; do
    [[ -z "$event" ]] && continue
    got=$(python3 "$HELPER" route "$settings" "$event" "$tool")
    if [[ "$got" != "$want" ]]; then
      printf '%s %s: expected [%s], got [%s]\n' "$event" "$tool" "$want" "$got"
    fi
  done <<<"$ROUTES"
}

rows=$(grep -c '|' <<<"$ROUTES")
mismatches=$(check_table "$SETTINGS")
if [[ -z "$mismatches" ]]; then
  pass "all $rows tool-name routes resolve to exactly the expected hook scripts"
else
  while IFS= read -r line; do fail "route $line"; done <<<"$mismatches"
fi

# Reverse check: a guard registered under an event but absent from every row has no routing
# coverage, so its matcher could be broken without this test noticing.
row_expects() {
  local want_event="$1" script="$2" event tool want
  while IFS='|' read -r event tool want; do
    [[ "$event" == "$want_event" && ",$want," == *",$script,"* ]] && return 0
  done <<<"$ROUTES"
  return 1
}

for event in PreToolUse PostToolUse; do
  while IFS= read -r script; do
    if row_expects "$event" "$script"; then
      pass "$event $script appears in at least one route row"
    else
      fail "$event $script is registered in settings.json but no route row expects it"
    fi
  done < <(python3 "$HELPER" scripts "$SETTINGS" "$event" | tr -d '\r')
done

# Mutation probes: break a matcher in a scratch copy and require the table to notice.
mutate_probe() {
  local name="$1" filter="$2" needle="$3" copy
  copy="$SCRATCH/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_').json"
  jq "$filter" "$SETTINGS" >"$copy"
  if cmp -s "$SETTINGS" "$copy"; then
    fail "mutation probe '$name' did not change settings.json"
    return
  fi
  if check_table "$copy" | grep -qF "$needle"; then
    pass "mutation probe: $name is detected"
  else
    fail "mutation probe: $name was not detected"
  fi
}

mutate_probe "Monitor dropped from the Bash guards" \
  '(.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor|PowerShell")).matcher = "Bash|PowerShell"' \
  "PreToolUse Monitor"
mutate_probe "PowerShell dropped from the Bash guards" \
  '(.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor|PowerShell")).matcher = "Bash|Monitor"' \
  "PreToolUse PowerShell"
mutate_probe "slack_add_reaction dropped from the Slack write regex" \
  '(.hooks.PreToolUse[] | select(.matcher | test("slack_add_reaction"))).matcher |= sub("\\|slack_add_reaction"; "")' \
  "slack_add_reaction"
mutate_probe "Jira transition dropped from the Jira write regex" \
  '(.hooks.PreToolUse[] | select(.matcher | test("transitionJiraIssue"))).matcher |= sub("transitionJiraIssue\\|"; "")' \
  "transitionJiraIssue"
mutate_probe "MultiEdit dropped from the edit guards" \
  '(.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")).matcher = "Edit|Write"' \
  "PreToolUse MultiEdit"

# The matcher dialect itself: an exact list must not match as a substring, a regex must.
dialect=$(python3 "$HELPER" selftest)
while IFS= read -r line; do
  case "$line" in
    "PASS "*) pass "matcher dialect: ${line#PASS }" ;;
    *) fail "matcher dialect: ${line#FAIL }" ;;
  esac
done <<<"$dialect"

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nAll hook matcher routing tests passed.\n'
