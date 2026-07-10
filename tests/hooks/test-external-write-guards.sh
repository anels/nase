#!/usr/bin/env bash
# Regression tests for external-write PreToolUse guards.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

TMP_ROOT=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/workspace/logs"

pass=0
fail=0

report() {
  local ok="$1" label="$2" detail="${3:-}"
  if [ "$ok" -eq 1 ]; then
    printf 'PASS  %-45s %s\n' "$label" "$detail"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-45s %s\n' "$label" "$detail"
    fail=$((fail + 1))
  fi
}

run_hook() {
  local script="$1" input="$2"
  set +e
  OUTPUT=$(printf '%s' "$input" | NASE_ROOT="$TMP_ROOT" bash "$script" 2>&1)
  RC=$?
  set -e
}

expect_rc() {
  local label="$1" script="$2" input="$3" want="$4" pattern="${5:-}"
  run_hook "$script" "$input"
  if [ "$RC" -ne "$want" ]; then
    report 0 "$label" "rc=$RC want=$want output=$OUTPUT"
    return
  fi
  if [ -n "$pattern" ] && [[ "$OUTPUT" != *"$pattern"* ]]; then
    report 0 "$label" "missing pattern: $pattern output=$OUTPUT"
    return
  fi
  report 1 "$label" "rc=$RC"
}

expect_missing_jq() {
  local label="$1" script="$2" input="$3"
  set +e
  # Use an absolute bash and a PATH that contains no jq on either macOS or Ubuntu
  # (Ubuntu's /bin is a symlink to /usr/bin which contains jq, so PATH=/bin is unsafe).
  BASH_BIN=$(command -v bash)
  OUTPUT=$(printf '%s' "$input" | env -i PATH=/nonexistent-nase-jq-test NASE_ROOT="$TMP_ROOT" "$BASH_BIN" "$script" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq 2 ] && [[ "$OUTPUT" == *"jq is required"* ]]; then
    report 1 "$label"
  else
    report 0 "$label" "rc=$RC output=$OUTPUT"
  fi
}

payload_sha() {
  printf '%s' "$1" | jq -cS '.tool_input // {}' | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

slack_send='{"tool_name":"mcp__plugin_slack_slack__slack_send_message","tool_input":{"channel_id":"C1","text":"hi"}}'
slack_send_alt='{"tool_name":"mcp__slack_workspace__slack_send_message","tool_input":{"channel_id":"C1","text":"hi"}}'
slack_draft='{"tool_name":"mcp__plugin_slack_slack__slack_send_message_draft","tool_input":{"channel_id":"C1","text":"hi"}}'
expect_rc "slack direct send blocked" .claude/hooks/slack-send-guard.sh "$slack_send" 2 "slack_send_message is forbidden"
expect_rc "slack alternate namespace blocked" .claude/hooks/slack-send-guard.sh "$slack_send_alt" 2 "slack_send_message is forbidden"
expect_rc "slack draft allowed" .claude/hooks/slack-send-guard.sh "$slack_draft" 0
expect_rc "slack malformed JSON blocked" .claude/hooks/slack-send-guard.sh "{" 2 "could not parse"

small_confluence=$(jq -cn '{tool_name:"mcp__plugin_atlassian_atlassian__updateConfluencePage",tool_input:{body:"short",contentFormat:"adf"}}')
large_body=$(printf '%*s' 60001 '' | tr ' ' x)
large_confluence=$(jq -cn --arg body "$large_body" '{tool_name:"mcp__plugin_atlassian_atlassian__updateConfluencePage",tool_input:{body:$body,contentFormat:"adf"}}')
large_confluence_alt=$(jq -cn --arg body "$large_body" '{tool_name:"mcp__atlassian_rovo_mcp__updateConfluencePage",tool_input:{body:$body,contentFormat:"adf"}}')
wide_body=$(printf '中%.0s' {1..20001})
wide_confluence=$(jq -cn --arg body "$wide_body" '{tool_name:"mcp__plugin_atlassian_atlassian__updateConfluencePage",tool_input:{body:$body,contentFormat:"adf"}}')
markdown_confluence=$(jq -cn '{tool_name:"mcp__plugin_atlassian_atlassian__updateConfluencePage",tool_input:{body:"short",contentFormat:"markdown"}}')
unset_confluence=$(jq -cn '{tool_name:"mcp__plugin_atlassian_atlassian__createConfluencePage",tool_input:{body:"short"}}')
confluence_read='{"tool_name":"mcp__plugin_atlassian_atlassian__getConfluencePage","tool_input":{"pageId":"1","contentFormat":"markdown"}}'
expect_rc "confluence small adf body allowed" .claude/hooks/confluence-size-guard.sh "$small_confluence" 0
expect_rc "confluence large body blocked" .claude/hooks/confluence-size-guard.sh "$large_confluence" 2 "confluence-size-guard"
expect_rc "confluence alternate namespace blocked" .claude/hooks/confluence-size-guard.sh "$large_confluence_alt" 2 "confluence-size-guard"
expect_rc "confluence UTF-8 byte limit blocked" .claude/hooks/confluence-size-guard.sh "$wide_confluence" 2 "bytes"
expect_rc "confluence markdown write blocked" .claude/hooks/confluence-size-guard.sh "$markdown_confluence" 2 'expected "adf"'
expect_rc "confluence unset format write blocked" .claude/hooks/confluence-size-guard.sh "$unset_confluence" 2 'expected "adf"'
expect_rc "confluence read (markdown) allowed" .claude/hooks/confluence-size-guard.sh "$confluence_read" 0
expect_rc "confluence malformed JSON blocked" .claude/hooks/confluence-size-guard.sh "{" 2 "could not parse"

github_write='{"tool_name":"Bash","tool_input":{"command":"gh pr create --draft --title test"}}'
github_read='{"tool_name":"Bash","tool_input":{"command":"gh pr view 7"}}'
ado_write='{"tool_name":"Bash","tool_input":{"command":"az rest --method post --uri https://example.invalid"}}'
azure_group_write='{"tool_name":"Bash","tool_input":{"command":"az group create --name example --location westus"}}'
azure_role_write='{"tool_name":"Bash","tool_input":{"command":"az role assignment create --assignee example --role Reader"}}'
azure_keyvault_write='{"tool_name":"Bash","tool_input":{"command":"az keyvault secret set --vault-name example --name sample --value value"}}'
terraform_write='{"tool_name":"Bash","tool_input":{"command":"terraform apply -auto-approve"}}'
github_workflow_write='{"tool_name":"Bash","tool_input":{"command":"gh workflow run deploy.yml --ref feature/test"}}'
github_comment_write='{"tool_name":"Bash","tool_input":{"command":"gh pr comment 7 --body approved"}}'
github_write_via_shell='{"tool_name":"Bash","tool_input":{"command":"bash -lc '\''gh pr create --draft --title test'\''"}}'
github_write_via_eval=$(jq -cn --arg command "bash -c 'eval \"gh pr create --draft --title test\"'" '{tool_name:"Bash",tool_input:{command:$command}}')
github_write_via_function=$(jq -cn --arg command "bash -c 'function deploy { gh pr create --draft --title test; }; deploy'" '{tool_name:"Bash",tool_input:{command:$command}}')
github_graphql_read='{"tool_name":"Bash","tool_input":{"command":"gh api graphql -f query={viewer{login}} -f owner=example"}}'
azure_unknown='{"tool_name":"Bash","tool_input":{"command":"az provider register --namespace Example.Provider"}}'
azure_read='{"tool_name":"Bash","tool_input":{"command":"az monitor app-insights query --app example --analytics-query requests"}}'
wrapped_action='{"tool_name":"Bash","tool_input":{"command":"python3 .claude/scripts/external-write-action.py execute --manifest workspace/tmp/external-actions/x.json"}}'
expect_rc "raw GitHub mutation blocked" .claude/hooks/external-cli-write-guard.sh "$github_write" 2 "raw external mutation"
expect_rc "GitHub read allowed" .claude/hooks/external-cli-write-guard.sh "$github_read" 0
expect_rc "raw ADO mutation blocked" .claude/hooks/external-cli-write-guard.sh "$ado_write" 2 "raw external mutation"
expect_rc "raw Azure group mutation blocked" .claude/hooks/external-cli-write-guard.sh "$azure_group_write" 2 "raw external mutation"
expect_rc "raw Azure role mutation blocked" .claude/hooks/external-cli-write-guard.sh "$azure_role_write" 2 "raw external mutation"
expect_rc "raw Azure Key Vault mutation blocked" .claude/hooks/external-cli-write-guard.sh "$azure_keyvault_write" 2 "raw external mutation"
expect_rc "raw Terraform mutation blocked" .claude/hooks/external-cli-write-guard.sh "$terraform_write" 2 "raw external mutation"
expect_rc "raw GitHub workflow mutation blocked" .claude/hooks/external-cli-write-guard.sh "$github_workflow_write" 2 "raw external mutation"
expect_rc "raw GitHub comment mutation blocked" .claude/hooks/external-cli-write-guard.sh "$github_comment_write" 2 "raw external mutation"
expect_rc "raw GitHub mutation through shell wrapper blocked" .claude/hooks/external-cli-write-guard.sh "$github_write_via_shell" 2 "raw external mutation"
expect_rc "dynamic shell eval fails closed" .claude/hooks/external-cli-write-guard.sh "$github_write_via_eval" 2 "unrecognized external CLI"
expect_rc "dynamic shell function fails closed" .claude/hooks/external-cli-write-guard.sh "$github_write_via_function" 2 "unrecognized external CLI"
expect_rc "GitHub GraphQL query remains allowed" .claude/hooks/external-cli-write-guard.sh "$github_graphql_read" 0
expect_rc "unrecognized Azure command fails closed" .claude/hooks/external-cli-write-guard.sh "$azure_unknown" 2 "unrecognized external CLI"
expect_rc "known Azure read remains allowed" .claude/hooks/external-cli-write-guard.sh "$azure_read" 0
expect_rc "authorized helper invocation allowed" .claude/hooks/external-cli-write-guard.sh "$wrapped_action" 0

jira_transition_tool="mcp__plugin_atlassian_atlassian__transitionJiraIssue"
jira_transition=$(jq -cn --arg tool "$jira_transition_tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-1"}}')
jira_transition_sha=$(payload_sha "$jira_transition")
jira_read='{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{"issueIdOrKey":"SRE-1"}}'
expect_rc "jira read allowed without token" .claude/hooks/jira-write-guard.sh "$jira_read" 0
expect_rc "jira mutation without token blocked" .claude/hooks/jira-write-guard.sh "$jira_transition" 2 "no jira-write-token"
expect_rc "jira malformed JSON blocked" .claude/hooks/jira-write-guard.sh "{" 2 "could not parse"

created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg tool "$jira_transition_tool" --arg created "$created" --arg payload_sha "$jira_transition_sha" \
  '{tool_name:$tool,issue_key:"SRE-1",created_at:$created,payload_summary:"SRE-1 -> Done",payload_sha256:$payload_sha}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira matching token allowed" .claude/hooks/jira-write-guard.sh "$jira_transition" 0
if [ -f "$TMP_ROOT/workspace/.jira-write-token" ]; then
  report 0 "jira token consumed" "token still exists"
else
  report 1 "jira token consumed"
fi

jq -n --arg tool "$jira_transition_tool" --arg created "$created" --arg payload_sha "$jira_transition_sha" \
  '{tool_name:$tool,issue_key:"SRE-2",created_at:$created,payload_summary:"SRE-2 -> Done",payload_sha256:$payload_sha}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira issue mismatch blocked" .claude/hooks/jira-write-guard.sh "$jira_transition" 2 "token issue mismatch"

jq -n --arg tool "$jira_transition_tool" --arg created "$created" \
  '{tool_name:$tool,issue_key:"SRE-1",created_at:$created,payload_summary:"SRE-1 -> Done"}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira token missing payload hash blocked" .claude/hooks/jira-write-guard.sh "$jira_transition" 2 "missing payload_sha256"

jira_transition_changed=$(jq -cn --arg tool "$jira_transition_tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-1",transition:{id:"999"},comment:"different payload"}}')
jq -n --arg tool "$jira_transition_tool" --arg created "$created" --arg payload_sha "$jira_transition_sha" \
  '{tool_name:$tool,issue_key:"SRE-1",created_at:$created,payload_summary:"SRE-1 -> Done",payload_sha256:$payload_sha}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira same issue changed payload blocked" .claude/hooks/jira-write-guard.sh "$jira_transition_changed" 2 "token payload mismatch"

jira_transition_alt_tool="mcp__atlassian_rovo_mcp__transitionJiraIssue"
jira_transition_alt=$(jq -cn --arg tool "$jira_transition_alt_tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-1"}}')
jira_transition_alt_sha=$(payload_sha "$jira_transition_alt")
jq -n --arg tool "$jira_transition_alt_tool" --arg created "$created" --arg payload_sha "$jira_transition_alt_sha" \
  '{tool_name:$tool,issue_key:"SRE-1",created_at:$created,payload_summary:"SRE-1 -> Done",payload_sha256:$payload_sha}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira alternate namespace allowed" .claude/hooks/jira-write-guard.sh "$jira_transition_alt" 0

jira_link_tool="mcp__plugin_atlassian_atlassian__createIssueLink"
jira_link=$(jq -cn --arg tool "$jira_link_tool" '{tool_name:$tool,tool_input:{inwardIssue:"SRE-1",outwardIssue:"SRE-2"}}')
jira_link_sha=$(payload_sha "$jira_link")
jq -n --arg tool "$jira_link_tool" --arg created "$created" --arg payload_sha "$jira_link_sha" \
  '{tool_name:$tool,issue_keys:["SRE-1","SRE-2"],created_at:$created,payload_summary:"link SRE-1 SRE-2",payload_sha256:$payload_sha}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira issue-link token allowed" .claude/hooks/jira-write-guard.sh "$jira_link" 0

jq -n --arg tool "$jira_link_tool" --arg created "$created" --arg payload_sha "$jira_link_sha" \
  '{tool_name:$tool,issue_key:"SRE-1",created_at:$created,payload_summary:"link SRE-1 only",payload_sha256:$payload_sha}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira issue-link missing endpoint blocked" .claude/hooks/jira-write-guard.sh "$jira_link" 2 "unapproved SRE-2"

jira_create_tool="mcp__plugin_atlassian_atlassian__createJiraIssue"
jira_create=$(jq -cn --arg tool "$jira_create_tool" '{tool_name:$tool,tool_input:{projectKey:"SRE",summary:"new issue",description:"body",contentFormat:"markdown"}}')
jira_create_sha=$(payload_sha "$jira_create")
jq -n --arg tool "$jira_create_tool" --arg created "$created" --arg payload_sha "$jira_create_sha" \
  '{tool_name:$tool,created_at:$created,payload_summary:"create issue",payload_sha256:$payload_sha}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira create markdown token allowed" .claude/hooks/jira-write-guard.sh "$jira_create" 0

# --- batch token mode ---
batch_created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jira_transition2=$(jq -cn --arg tool "$jira_transition_tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-2"}}')
jira_comment_tool="mcp__plugin_atlassian_atlassian__addCommentToJiraIssue"
jira_comment1=$(jq -cn --arg tool "$jira_comment_tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-1",commentBody:"x",contentFormat:"markdown"}}')
jira_transition9=$(jq -cn --arg tool "$jira_transition_tool" '{tool_name:$tool,tool_input:{issueIdOrKey:"SRE-9"}}')

write_batch() {
  jq -n --arg created "$1" --argjson ops "$2" \
    '{approved_issues:["SRE-1","SRE-2"],max_ops:$ops,created_at:$created,payload_summary:"cancel batch"}' \
    > "$TMP_ROOT/workspace/.jira-write-token"
}

write_batch "$batch_created" 3
expect_rc "jira batch op1 transition SRE-1 allowed" .claude/hooks/jira-write-guard.sh "$jira_transition" 0
expect_rc "jira batch op2 comment SRE-1 allowed" .claude/hooks/jira-write-guard.sh "$jira_comment1" 0
expect_rc "jira batch op3 transition SRE-2 allowed" .claude/hooks/jira-write-guard.sh "$jira_transition2" 0
expect_rc "jira batch exhausted blocked" .claude/hooks/jira-write-guard.sh "$jira_transition" 2 "no jira-write-token"

write_batch "$batch_created" 3
expect_rc "jira batch unapproved issue blocked" .claude/hooks/jira-write-guard.sh "$jira_transition9" 2 "not in approved set"

old_created=$(date -u -v-20M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
write_batch "$old_created" 3
expect_rc "jira batch stale blocked" .claude/hooks/jira-write-guard.sh "$jira_transition" 2 "stale or from the future"

jq -n --arg created "$batch_created" \
  '{approved_issues:["SRE-1"],max_ops:2,created_at:$created,tools:["addCommentToJiraIssue"],payload_summary:"comments only"}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira batch tool not allowed blocked" .claude/hooks/jira-write-guard.sh "$jira_transition" 2 "does not authorize tool"
jq -n --arg created "$batch_created" \
  '{approved_issues:["SRE-1"],max_ops:2,created_at:$created,tools:["addCommentToJiraIssue"],payload_summary:"comments only"}' \
  > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira batch tool suffix-match allowed" .claude/hooks/jira-write-guard.sh "$jira_comment1" 0

# --- format gate (runs after token-mode detection) ---
jira_comment_adf=$(jq -cn '{tool_name:"mcp__plugin_atlassian_atlassian__addCommentToJiraIssue",tool_input:{issueIdOrKey:"SRE-1",commentBody:"x",contentFormat:"adf"}}')
jira_comment_unset=$(jq -cn '{tool_name:"mcp__plugin_atlassian_atlassian__addCommentToJiraIssue",tool_input:{issueIdOrKey:"SRE-1",commentBody:"x"}}')
jira_create_adf=$(jq -cn --arg tool "$jira_create_tool" '{tool_name:$tool,tool_input:{projectKey:"SRE",summary:"new issue",description:{type:"doc",content:[]},contentFormat:"adf"}}')
echo '{}' > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira adf body under single-shot blocked" .claude/hooks/jira-write-guard.sh "$jira_comment_adf" 2 "under a single-shot token"
echo '{}' > "$TMP_ROOT/workspace/.jira-write-token"
expect_rc "jira unset format body blocked" .claude/hooks/jira-write-guard.sh "$jira_comment_unset" 2 "<unset>"
if [ -f "$TMP_ROOT/workspace/.jira-write-token" ]; then
  report 0 "jira format block consumes token" "token still exists"
else
  report 1 "jira format block consumes token"
fi
write_batch "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2
expect_rc "jira unset format under batch blocked" .claude/hooks/jira-write-guard.sh "$jira_comment_unset" 2 "<unset>"
if [ -f "$TMP_ROOT/workspace/.jira-write-token" ]; then
  report 0 "jira batch format block consumes token" "token still exists"
else
  report 1 "jira batch format block consumes token"
fi
write_batch "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2
expect_rc "jira create adf under batch blocked" .claude/hooks/jira-write-guard.sh "$jira_create_adf" 2 "createJiraIssue must use markdown"
write_batch "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2
expect_rc "jira adf body under batch token allowed" .claude/hooks/jira-write-guard.sh "$jira_comment_adf" 0

expect_missing_jq "slack missing jq blocked" .claude/hooks/slack-send-guard.sh "$slack_send"
expect_missing_jq "jira missing jq blocked" .claude/hooks/jira-write-guard.sh "$jira_transition"
expect_missing_jq "confluence missing jq blocked" .claude/hooks/confluence-size-guard.sh "$small_confluence"
expect_missing_jq "external CLI missing jq blocked" .claude/hooks/external-cli-write-guard.sh "$github_write"

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
