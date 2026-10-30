#!/usr/bin/env bash
# Regression tests for the payload-bound external write action helper.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/external-write-action.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/bin" "$TMPDIR_TEST/workspace/tmp"
export GH_CONFIG_DIR="$TMPDIR_TEST/gh-config"
git -C "$TMPDIR_TEST" init -q
git -C "$TMPDIR_TEST" remote add origin https://github.com/owner/example.git
cat > "$TMPDIR_TEST/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "auth token" ]]; then
  [[ -z "${NASE_FAKE_TOKEN_FAIL:-}" ]] || exit 7
  account=""
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "--user" && "$#" -gt 1 ]]; then
      account="$2"
      break
    fi
    shift
  done
  [[ -n "$account" ]] || exit 2
  printf 'test-token-for-%s\n' "$account"
  exit 0
fi
if [[ "${1:-} ${2:-}" == "auth switch" ]]; then
  exit 99
fi
if [[ "${1:-} ${2:-}" == "api user" ]]; then
  actor="${NASE_FAKE_TOKEN_ACTOR:-${GH_TOKEN#test-token-for-}}"
  [[ -n "$actor" && "$actor" != "$GH_TOKEN" ]] || exit 2
  printf '%s\n' "$actor"
  exit 0
fi
if [[ -n "${NASE_FAKE_CAPTURE_ENV:-}" ]]; then
  printf '%s|%s|%s|%s\n' \
    "${GH_HOST:-}" "${GH_REPO-unset}" "${GH_TOKEN+set}" "${GH_TOKEN#test-token-for-}" \
    > "$NASE_FAKE_CAPTURE_ENV"
fi
printf '%s\n' "$*" > "$NASE_FAKE_OUTPUT"
if [[ -n "${NASE_FAKE_WAIT:-}" ]]; then
  sleep "$NASE_FAKE_WAIT"
fi
exit "${NASE_FAKE_EXIT:-0}"
SH
chmod +x "$TMPDIR_TEST/bin/gh"

pass=0
fail=0

report() {
  local ok="$1" name="$2" detail="${3:-}"
  if [[ "$ok" -eq 0 ]]; then
    printf 'PASS  %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s%s\n' "$name" "${detail:+: $detail}" >&2
    fail=$((fail + 1))
  fi
}

expect_rc() {
  local name="$1" expected="$2"
  shift 2
  set +e
  "$@" > "$TMPDIR_TEST/out" 2> "$TMPDIR_TEST/err"
  local rc=$?
  set -e
  if [[ "$rc" -eq "$expected" ]]; then
    report 0 "$name"
  else
    report 1 "$name" "expected $expected, got $rc: $(cat "$TMPDIR_TEST/err")"
  fi
}

expect_jq() {
  local name="$1" expression="$2" file="$3"
  if jq -e "$expression" "$file" >/dev/null; then
    report 0 "$name"
  else
    report 1 "$name"
  fi
}

expect_guard_rc() {
  local name="$1" expected="$2" command="$3"
  expect_rc "$name" "$expected" \
    python3 "$SCRIPT" --root "$TMPDIR_TEST" guard --command "$command"
}

prepare_action() {
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "create draft PR" -- \
    gh pr create --draft --title "Example" --body "payload" -R owner/example > "$TMPDIR_TEST/prepared.json"
  jq -r '.manifest' "$TMPDIR_TEST/prepared.json"
}

expect_rc "GitHub prepare requires an expected account" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "create draft PR" -- \
    gh pr create --draft --title "Example" --body "payload" -R owner/example

cat > "$TMPDIR_TEST/workspace/config.md" <<'EOF'
github_org: owner
gh_account: expected
work_gh_account: expected
personal_gh_account: personal
EOF

expect_rc "GitHub prepare rejects an unmapped target owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "create unknown draft PR" -- \
    gh pr create --draft --title "Example" --body "payload" -R unknown/example
expect_rc "attached GitHub method mutation is blocked" 10 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" guard --command \
    "gh api repos/owner/example/issues -XPOST"
expect_rc "attached GitHub raw field mutation is blocked" 10 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" guard --command \
    "gh api repos/owner/example/issues -fbody=example"
expect_rc "equals-form GitHub field mutation is blocked" 10 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" guard --command \
    "gh api repos/owner/example/issues --field=body=example"
expect_rc "equals-form GitHub input mutation is blocked" 10 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" guard --command \
    "gh api repos/owner/example/issues --input=payload.json"
# gh accepts clustered short flags: -iXDELETE is -i -X DELETE and -if k=v is -i -f k=v.
expect_guard_rc "clustered method with separate value is blocked" 10 \
  "gh api repos/owner/example/issues/1 -iX DELETE"
expect_guard_rc "clustered method with attached value is blocked" 10 \
  "gh api repos/owner/example/issues/1 -iXPOST"
expect_guard_rc "clustered raw field is blocked" 10 \
  "gh api repos/owner/example/issues/1 -if title=x"
expect_guard_rc "clustered field is blocked" 10 \
  "gh api repos/owner/example/issues/1 -iF title=x"
expect_guard_rc "clustered field with attached value is blocked" 10 \
  "gh api repos/owner/example/issues/1 -ifbody=x"
expect_guard_rc "clustered GET method stays a read" 0 \
  "gh api repos/owner/example/issues/1 -iXGET"
expect_guard_rc "clustered GET method with separate value stays a read" 0 \
  "gh api repos/owner/example/issues/1 -iX GET"
expect_guard_rc "unknown clustered short flag fails closed" 10 \
  "gh api repos/owner/example/issues/1 -iZ"
expect_guard_rc "unknown clustered short flag after a read method fails closed" 10 \
  "gh api repos/owner/example/issues/1 -XGET -iZ"
expect_guard_rc "clustered GraphQL mutation field is blocked" 10 \
  "gh api graphql -iF 'query=mutation { x }'"
expect_guard_rc "clustered GraphQL query stays a read" 0 \
  "gh api graphql -if 'query={ viewer { login } }'"
expect_guard_rc "GraphQL query field with --input body is not a read" 10 \
  "gh api graphql -f 'query=query { a }' --input mutation.json"
expect_guard_rc "gh pr create inside git rebase -x is blocked" 10 \
  "git rebase -x 'gh pr create' HEAD~1"
expect_guard_rc "gh pr create inside unquoted git submodule foreach is blocked" 10 \
  "git submodule foreach gh pr create"
expect_guard_rc "plain gh api read stays a read" 0 "gh api repos/owner/example"
expect_guard_rc "gh api include flag stays a read" 0 "gh api -i repos/owner/example"
expect_guard_rc "gh api explicit GET stays a read" 0 "gh api -X GET repos/owner/example"
expect_guard_rc "gh api explicit GET with fields sends query parameters" 0 \
  "gh api -X GET search/code -f q=example --jq '.items[].path'"
expect_guard_rc "gh api fields without a method switch to POST" 10 \
  "gh api search/issues -f q=example"
expect_guard_rc "gh api explicit GET with a body file is blocked" 10 \
  "gh api -X GET repos/owner/example --input body.json"
expect_guard_rc "gh api paginate stays a read" 0 "gh api --paginate repos/owner/example/issues"
expect_guard_rc "gh api header value is not read as a cluster" 0 \
  "gh api -H 'Accept: application/vnd.github+json' repos/owner/example"
expect_guard_rc "gh api jq value is not read as a cluster" 0 \
  "gh api repos/owner/example -q '.name'"
printf 'reply prose\n' > "$TMPDIR_TEST/reply.md"
jq -n --rawfile body "$TMPDIR_TEST/reply.md" '{body:$body}' > "$TMPDIR_TEST/payload.json"
REPLY_ENDPOINT="/repos/owner/example/pulls/1/comments/2/replies"

expect_rc "raw-field @file body is blocked because gh sends it literally" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "reply with literal path" -- \
    gh api --method POST "$REPLY_ENDPOINT" -f "body=@$TMPDIR_TEST/reply.md"
if grep -q -- '--input' "$TMPDIR_TEST/err"; then
  report 0 "raw-field @file rejection names the --input replacement"
else
  report 1 "raw-field @file rejection names the --input replacement" "$(cat "$TMPDIR_TEST/err")"
fi

expect_rc "attached raw-field @file body is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "reply with literal path" -- \
    gh api --method POST "$REPLY_ENDPOINT" "--raw-field=body=@$TMPDIR_TEST/reply.md"
expect_rc "short attached raw-field @file body is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner owner --summary "reply with literal path" -- \
    gh api --method POST "$REPLY_ENDPOINT" "-fbody=@$TMPDIR_TEST/reply.md"
expect_rc "clustered raw-field @file body is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner owner --summary "reply with literal path" -- \
    gh api -iX POST "$REPLY_ENDPOINT" -if "body=@$TMPDIR_TEST/reply.md"

expect_rc "jq-built --input reply payload is accepted" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner owner --summary "reply to review comment 2" -- \
    gh api --method POST "$REPLY_ENDPOINT" --input "$TMPDIR_TEST/payload.json"

expect_rc "duplicate GitHub target selectors are blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "conflicting target" -- \
    gh pr create --draft -R owner/example --repo personal/example
expect_rc "host-qualified enterprise target is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "enterprise target" -- \
    gh pr create --draft -R ghe.example/owner/example
expect_rc "GH_HOST cannot redirect a GitHub mutation" 2 \
  env GH_HOST=ghe.example python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "environment host target" -- \
    gh pr create --draft -R owner/example
git -C "$TMPDIR_TEST" remote set-url origin https://evilgithub.com/owner/example.git
expect_rc "lookalike GitHub origin is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "lookalike origin target" -- gh pr create --draft
git -C "$TMPDIR_TEST" remote set-url origin https://github.com/owner/example.git
expect_rc "enterprise PR URL is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner owner --summary "enterprise PR target" -- \
    gh pr review --approve https://ghe.example/owner/example/pull/1

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --summary "create linked draft PR" -- \
  gh pr create --draft --title "Example" \
  --body "Related https://github.com/personal/example" -R owner/example > "$TMPDIR_TEST/linked-prepared.json"
expect_jq "explicit repo outranks links in GitHub payload text" \
  '.action.github_owner == "owner" and .action.github_account == "expected"' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/linked-prepared.json")"

GRAPHQL_FILE="$TMPDIR_TEST/graphql.json"
printf '%s\n' '{"query":"mutation { example }"}' > "$GRAPHQL_FILE"
expect_rc "opaque GraphQL mutation requires an explicit owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "resolve review thread" -- \
    gh api graphql --input "$GRAPHQL_FILE"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --github-owner owner --summary "resolve review thread" -- \
  gh api graphql --input "$GRAPHQL_FILE" > "$TMPDIR_TEST/graphql-prepared.json"
expect_jq "explicit owner binds an opaque GraphQL mutation" \
  '.action.github_owner == "owner" and .action.github_account == "expected"' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/graphql-prepared.json")"

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --summary "update organization setting" -- \
  gh api orgs/owner/example --method PUT > "$TMPDIR_TEST/org-prepared.json"
expect_jq "organization API path selects its owner" \
  '.action.github_owner == "owner"' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/org-prepared.json")"

expect_rc "positional repository requires an explicit owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "edit repository" -- \
    gh repo edit owner/example --description "Example"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --github-owner owner --summary "edit repository" -- \
  gh repo edit owner/example --description "Example" > "$TMPDIR_TEST/repo-edit-prepared.json"
expect_jq "explicit owner binds a positional repository" \
  '.action.github_owner == "owner" and .action.github_owner_override == true' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/repo-edit-prepared.json")"

for repo_verb in create delete; do
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner personal --summary "$repo_verb personal repository" -- \
    gh repo "$repo_verb" personal/example --yes > "$TMPDIR_TEST/repo-$repo_verb-prepared.json"
  expect_jq "explicit owner binds repo $repo_verb" \
    '.action.github_owner == "personal" and .action.github_account == "personal"' \
    "$(jq -r '.manifest' "$TMPDIR_TEST/repo-$repo_verb-prepared.json")"
done

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --github-owner personal --summary "approve personal PR" -- \
  gh pr review --approve https://github.com/personal/example/pull/1 > "$TMPDIR_TEST/pr-review-prepared.json"
expect_jq "explicit owner binds a PR URL after flags" \
  '.action.github_owner == "personal" and .action.github_account == "personal"' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/pr-review-prepared.json")"

expect_rc "PR review URL without an explicit owner is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "comment on PR" -- \
    gh pr review --comment https://github.com/personal/example/pull/1
expect_rc "explicit owner must match the PR URL" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner owner --summary "approve personal PR" -- \
    gh pr review --approve https://github.com/personal/example/pull/1
expect_rc "repository selector must match the PR URL" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "approve conflicting PR" -- \
    gh pr review --approve -R owner/example https://github.com/personal/example/pull/1
expect_rc "PR merge URL after a value flag is blocked without an explicit owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "merge PR" -- \
    gh pr merge --subject release/x https://github.com/personal/example/pull/1
expect_rc "issue URL after a value flag is blocked without an explicit owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "close issue" -- \
    gh issue close --reason completed https://github.com/personal/example/issues/1
expect_rc "repo template cannot be mistaken for the target owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "create repository" -- \
    gh repo create --template owner/template personal/example
expect_rc "repo description cannot be mistaken for the target owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "edit repository" -- \
    gh repo edit --description owner/example personal/example
expect_rc "explicit owner must match a repository target" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner owner --summary "edit personal repository" -- \
    gh repo edit personal/example --description "Example"
expect_rc "explicit owner cannot override the current repository" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner personal --summary "create current repository PR" -- \
    gh pr create --draft --title "Example" --body "payload"
expect_rc "explicit owner cannot override a current-repository edit" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner personal --summary "edit current repository" -- \
    gh repo edit --enable-issues

expect_rc "gist mutation requires an explicit owner" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --summary "create gist" -- gh gist create note.md
printf 'approved gist content\n' > "$TMPDIR_TEST/note.md"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --github-owner personal --summary "create gist" -- \
  gh gist create note.md > "$TMPDIR_TEST/gist-prepared.json"
expect_jq "explicit owner and file bind a gist mutation" \
  '.action.github_owner == "personal" and .action.github_account == "personal" and (.action.payload_files | length) == 1' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/gist-prepared.json")"
expect_rc "stdin gist payload is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
    --system github --github-owner personal --summary "create stdin gist" -- gh gist create -

expect_guard_rc "raw gh auth token is blocked" 10 "gh auth token"
expect_guard_rc "gh auth status token output is blocked" 10 "gh auth status --show-token"
expect_guard_rc "gh auth status short token flag is blocked" 10 "gh auth status -at"
expect_guard_rc "gh auth switch only changes the local active account" 0 "gh auth switch --user personal"
expect_guard_rc "raw gh auth logout is blocked" 10 "gh auth logout --hostname github.com"
expect_guard_rc "gh auth status remains read-only" 0 "gh auth status --active"
expect_guard_rc "dynamic executable variable is blocked" 10 'GH=gh; $GH pr create --draft --title Example'
expect_guard_rc "top-level alias is blocked" 10 "alias publish=gh; publish pr create --draft --title Example"
expect_guard_rc "top-level shell function is blocked" 10 "publish() { gh pr create --draft --title Example; }; publish"
expect_guard_rc "newline-separated mutation is blocked" 10 $'gh pr view 1\ngh pr create --draft --title Example'
# A single-quoted span is one shlex argument and can never become an executable, so a literal
# backtick or $( in prose must not read as a substitution. Markdown identifiers in a log or KB
# append are the common case.
expect_guard_rc "single-quoted backtick is literal" 0 \
  "printf 'see \`AppRequests\` rows\n' >> workspace/logs/example.md"
expect_guard_rc "single-quoted dollar-paren is literal" 0 "grep -n 'cost \$(one)' workspace/tmp/example.md"
expect_guard_rc "single-quoted backtick in a sed replacement is literal" 0 \
  "sed -i '' 's|old|new \`Foo.cs:12\`|' workspace/tmp/example.md"
# A construct the shell really expands makes the command unparseable, and unparseable alone
# is not a reason to block: this guard exists for external CLI mutations, and a substitution
# that cannot reach one of the four guarded executables has nothing to protect. Pair each
# allowed case with the same shape naming a guarded CLI, so the fail-closed half stays pinned.
expect_guard_rc "unquoted backtick substitution reaching no guarded CLI is allowed" 0 'echo `whoami`'
expect_guard_rc "double-quoted backtick reaching no guarded CLI is allowed" 0 'echo "user: `whoami`"'
expect_guard_rc "read-only git pipeline with a substitution is allowed" 0 \
  'git status -sb && echo "staged=$(git diff --cached --name-only | wc -l)"'
expect_guard_rc "substitution naming a guarded CLI stays blocked" 10 'echo "count: $(gh pr list)"'
expect_guard_rc "guarded CLI taking a dynamic argument stays blocked" 10 'gh api $(cat endpoint.txt)'
expect_guard_rc "guarded CLI taking a quoted dynamic argument stays blocked" 10 \
  'kubectl get pods -n "$(cat ns.txt)"'
expect_guard_rc "backtick inside a nested bash -c script is blocked" 10 'bash -c '"'"'echo `whoami`'"'"''
expect_guard_rc "unterminated single quote naming no guarded CLI is allowed" 0 "printf 'unterminated"
expect_guard_rc "unterminated single quote naming a guarded CLI stays fail-closed" 10 \
  "gh pr create --title 'unterminated"
# An unlexable command must still reach the later checks: the unrecognized-CLI check's
# shell-pipe arm reads the raw command text and does not need the lexer at all.
expect_guard_rc "an unlexable command piped into a shell stays blocked" 10 \
  "printf 'unterminated | bash"

# `< bash` reads stdin from a file named `bash`; no shell syntax makes it invoke one, so
# the pipe test has no `<` arm. The shape it looks like it should cover, `bash < script.sh`,
# puts the name first and is allowed for the same reason `bash script.sh` is: the guard
# cannot read either file.
expect_guard_rc "reading a file named bash is not a shell invocation" 0 "cat < bash"
expect_guard_rc "a shell reading a script from stdin is allowed, like passing it" 0 \
  "bash < script.sh"

# The pipe test masks quoted spans first. `|` is literal inside either quote kind, so
# scanning raw text refused ordinary read-only work, including a grep for the guard's own
# pattern.
expect_guard_rc "a single-quoted pipe is not a pipe into a shell" 0 "grep -n 'a|sh' file.py"
expect_guard_rc "a grep for the shell-name pattern is not a pipe into a shell" 0 \
  "grep -nE 'bash|dash|ksh|sh|zsh' file.py"
expect_guard_rc "a double-quoted pipe is not a pipe into a shell" 0 \
  'echo "x | bash" > note.md'
expect_guard_rc "a real pipe into a non-shell is allowed" 0 \
  "printf '%s' \"\$x\" | tr '|sh' 'x'"
expect_guard_rc "a pipe with no space before the shell name is blocked" 10 "echo hi |bash"

# A construct whose target cannot be bound is blocked by the unrecognized-CLI check
# regardless of any guarded name, because `command_argvs` cannot say what it will run.
# Only the constructs that stay lexable and keep a static executable - a substitution or
# backtick in an argument, a function body - depend on the guarded-name scan.
expect_guard_rc "eval is blocked with no guarded CLI named" 10 'eval "ls -la"'
expect_guard_rc "source is blocked with no guarded CLI named" 10 "source ./setup.sh"
expect_guard_rc "alias is blocked with no guarded CLI named" 10 "alias ll=ls; ll"
expect_guard_rc "a pipe into a shell is blocked with no guarded CLI named" 10 "echo hi | bash"
expect_guard_rc "a herestring into a shell is blocked with no guarded CLI named" 10 \
  "bash <<< 'ls -la'"
expect_guard_rc "a function definition naming no guarded CLI is allowed" 0 "f() { ls; }; f"

# The shape the policy doc names as outside this guard's reach: whatever a script or task
# runner executes for itself. Pinned so the doc and the guard cannot drift apart, and so a
# later narrowing that closes it fails here and gets the doc updated with it.
#
# A name assembled into a variable used to be the second such shape, because the old lexer
# folded the closing parenthesis into the next word and never saw `$X` as an executable.
# The shared parser keeps `$X` as a dynamic executable, which check 3 blocks.
expect_guard_rc "a guarded name assembled into a variable is blocked as a dynamic executable" 10 \
  "X=\$(printf 'g''h'); \$X pr create"
expect_guard_rc "a script the guard cannot read is allowed to run" 0 "bash deploy.sh"
expect_guard_rc "a task runner is allowed to run" 0 "make deploy"
# But a substitution in the executable position is not a way through: an executable the
# guard cannot read is what the unrecognized-CLI check exists for.
expect_guard_rc "a substitution in the executable position is blocked" 10 \
  "\$(printf 'g''h') pr create"
# `github` and `terraform-docs` merely start with a guarded name; a path prefix does not.
expect_guard_rc "a longer word starting with a guarded name is not a mention" 0 \
  'echo "see github.com and terraform-docs: $(date)"'
expect_guard_rc "a path-qualified guarded CLI is still a mention" 10 \
  'echo "$(date)" && /usr/local/bin/gh pr create --title Example'

# A heredoc body is data written to a file, not commands. Lexing it as commands blocked a
# local file write for a backtick or a guarded verb sitting in prose.
expect_guard_rc "heredoc body carrying a backtick in prose is allowed" 0 \
  "$(printf 'cat > workspace/tmp/example.md <<%sEOF%s\nsee `Foo` rows\nEOF\n' "'" "'")"
expect_guard_rc "heredoc body naming a guarded CLI in prose is allowed" 0 \
  "$(printf 'cat > workspace/tmp/example.md <<%sEOF%s\nrun gh pr create by hand\nEOF\n' "'" "'")"
# A heredoc feeding a shell really is executed, so its body keeps being read as commands.
expect_guard_rc "heredoc feeding bash a mutation is blocked" 10 \
  "$(printf 'bash <<%sEOF%s\ngh pr create --title Example\nEOF\n' "'" "'")"
expect_guard_rc "heredoc feeding bash through a pipeline is blocked" 10 \
  "$(printf 'printf x | bash <<%sEOF%s\ngh pr create --title Example\nEOF\n' "'" "'")"
expect_guard_rc "herestring feeding bash a mutation is blocked" 10 \
  "bash <<< 'gh pr create --title Example'"
expect_guard_rc "herestring with no space before the script is blocked" 10 \
  "bash <<<'terraform apply -auto-approve'"
# A shell named anywhere in the command stops the stripping, not only on the line the
# redirect sits on: a backslash continuation puts the shell and the `<<` on separate
# lines, and a line-local test would strip a body that really is executed.
expect_guard_rc "shell continued onto the heredoc line is blocked" 10 \
  "$(printf 'bash \\\n  <<%sEOF%s\ngh pr create --title Example\nEOF\n' "'" "'")"
expect_guard_rc "shell after another command is blocked" 10 \
  "$(printf 'true && bash <<%sEOF%s\ngh pr create --title Example\nEOF\n' "'" "'")"
expect_guard_rc "env-prefixed shell heredoc is blocked" 10 \
  "$(printf 'FOO=1 bash <<%sEOF%s\ngh pr create --title Example\nEOF\n' "'" "'")"
expect_guard_rc "path-qualified shell heredoc is blocked" 10 \
  "$(printf '/bin/bash <<%sEOF%s\ngh pr create --title Example\nEOF\n' "'" "'")"
expect_guard_rc "sudo-wrapped shell heredoc is blocked" 10 \
  "$(printf 'sudo bash <<%sEOF%s\ngh pr create --title Example\nEOF\n' "'" "'")"
# Two delimiters on one line consume two bodies in order, and `<<-` allows an indented
# delimiter. Both are separate paths through the delimiter queue.
expect_guard_rc "two heredoc bodies on one line are both dropped" 0 \
  "$(printf 'cmd <<A <<B\nbody a\nA\ngh pr create\nB\necho done\n')"
expect_guard_rc "an indented <<- delimiter closes its body" 0 \
  "$(printf 'cat <<-EOF\n  gh pr create\n  EOF\necho done\n')"
# The shell test is scoped to the redirect's own line plus any preceding line joined by a
# backslash. Spanning the whole command refused a heredoc that feeds python because a
# later segment happened to run `bash`.
expect_guard_rc "a heredoc feeding python is stripped even when a later segment runs bash" 0 \
  "$(printf 'python3 - <<%sPY%s\nprint(1)\nPY\nbash -n file.sh\n' "'" "'")"
expect_guard_rc "a prose heredoc is stripped even when a later segment runs bash" 0 \
  "$(printf 'cat > f.md <<%sEOF%s\nsee `Foo` rows\nEOF\nbash -n f.sh\n' "'" "'")"
expect_guard_rc "quoted executable mutation is blocked" 10 "'gh' pr create --draft --title Example"
expect_guard_rc "mutation carrying a literal backtick argument is blocked" 10 \
  "gh pr create --draft --title 'uses \`Foo\` here'"
expect_guard_rc "Azure access-token output is blocked" 10 "az account get-access-token"
expect_guard_rc "raw Azure login is blocked" 10 "az login"
expect_guard_rc "raw Azure logout is blocked" 10 "az logout"
expect_guard_rc "Azure account show remains read-only" 0 "az account show"
expect_guard_rc "az account set only retargets the local CLI" 0 "az account set --subscription example"
expect_guard_rc "az cloud set only retargets the local CLI" 0 "az cloud set --name AzureCloud"
expect_guard_rc "az monitor query text that mentions a token is not a secret read" 0 \
  "az monitor app-insights query --app example -g rg --analytics-query \"traces | where message has 'token'\""
expect_guard_rc "az monitor query flag naming a secret is still blocked" 10 \
  "az monitor app-insights query --app example -g rg --analytics-query requests --secret x"
expect_guard_rc "az keyvault secret show stays blocked" 10 "az keyvault secret show --vault-name v -n s"
expect_guard_rc "az cdn endpoint show is a read" 0 "az cdn endpoint show -g rg --profile-name p -n e"
expect_guard_rc "az cdn endpoint purge is still a mutation" 10 \
  "az cdn endpoint purge -g rg --profile-name p -n e --content-paths /"
expect_guard_rc "az costmanagement query is a read" 0 \
  "az costmanagement query --type ActualCost --scope /subscriptions/example --timeframe MonthToDate"
expect_guard_rc "az devops invoke defaults to GET and stays read-only" 0 "az devops invoke --area build --resource timeline --route-parameters project=Analytics buildId=1 --org https://dev.azure.com/example --api-version 7.1"
expect_guard_rc "az devops invoke explicit GET stays read-only" 0 "az devops invoke --area build --resource logs --http-method get --org https://dev.azure.com/example"
expect_guard_rc "az devops invoke POST is blocked" 10 "az devops invoke --area build --resource builds --http-method POST --in-file body.json --org https://dev.azure.com/example"
expect_guard_rc "az devops invoke with a body file is blocked" 10 "az devops invoke --area build --resource builds --in-file body.json --org https://dev.azure.com/example"
expect_guard_rc "az rest without --method defaults to GET" 0 "az rest --resource 499b84ac-1321-427f-aa17-267ca6975798 --url https://dev.azure.com/example/_apis/build/builds/1"
expect_guard_rc "az rest short -m PATCH is blocked" 10 "az rest -m patch --url https://example.invalid"
expect_guard_rc "az rest with a body and no method is blocked" 10 "az rest --url https://example.invalid --body {}"
expect_guard_rc "az rest global --output json stays read-only" 0 "az rest --url https://example.invalid --output json"
expect_guard_rc "az rest with a trailing --method and no value is blocked" 10 "az rest --url https://example.invalid --method"
expect_guard_rc "az rest attached -mPOST is blocked" 10 "az rest --url https://example.invalid -mPOST"
expect_guard_rc "az rest --method=POST is blocked" 10 "az rest --url https://example.invalid --method=POST"
expect_guard_rc "az rest short -b body is blocked" 10 "az rest --url https://example.invalid -b {}"
expect_guard_rc "az rest OPTIONS is blocked" 10 "az rest --url https://example.invalid --method options"
expect_guard_rc "az rest method-override header is blocked" 10 "az rest --url https://example.invalid --headers X-HTTP-Method-Override=POST"
expect_guard_rc "az rest any --headers is blocked" 10 "az rest --url https://example.invalid --headers X-HTTP-Method=PUT"
expect_guard_rc "az devops invoke --http-method=POST is blocked" 10 "az devops invoke --area build --resource builds --http-method=POST"
expect_guard_rc "az rest --output-file is blocked" 10 "az rest --url https://example.invalid --output-file out.json"
expect_guard_rc "az devops invoke --out-file is blocked" 10 "az devops invoke --area build --resource builds --out-file out.json"
expect_guard_rc "az rest abbreviated --metho is blocked" 10 "az rest --url https://example.invalid --metho post --bod {}"
expect_guard_rc "az rest abbreviated --metho GET is blocked" 10 "az rest --url https://example.invalid --metho get"
expect_guard_rc "az devops invoke abbreviated flags are blocked" 10 "az devops invoke --area build --resource builds --http-meth post --in-fi body.json"
expect_guard_rc "Azure Key Vault secret listing (names only) stays read-only" 0 "az keyvault secret list --vault-name example -o table"
expect_guard_rc "Azure Key Vault secret value download is blocked" 10 "az keyvault secret download --vault-name example --name sample --file out.txt"
expect_guard_rc "Azure Key Vault secret delete is blocked" 10 "az keyvault secret delete --vault-name example --name sample"
expect_guard_rc "Azure Data Factory pipeline-run show stays read-only" 0 "az datafactory pipeline-run show --factory-name example -g rg --run-id 1"
expect_guard_rc "Azure Data Factory pipeline-run query-by-factory stays read-only" 0 "az datafactory pipeline-run query-by-factory --factory-name example -g rg --last-updated-after 2026-01-01 --last-updated-before 2026-01-02"
expect_guard_rc "Azure Data Factory activity-run output is blocked (can hold fetched secrets)" 10 "az datafactory activity-run query-by-pipeline-run --factory-name example -g rg --run-id 1 --last-updated-after 2026-01-01 --last-updated-before 2026-01-02"
expect_guard_rc "Azure Data Factory factory list is blocked" 10 "az datafactory list -g rg"
expect_guard_rc "Azure Data Factory trigger-run rerun is blocked" 10 "az datafactory trigger-run rerun --factory-name example -g rg --trigger-name t --run-id 1"
expect_guard_rc "Azure Data Factory pipeline definition show is blocked (can hold inline credentials)" 10 "az datafactory pipeline show --factory-name example -g rg -n sample"
expect_guard_rc "Azure Data Factory linked-service show is blocked (can print connection strings)" 10 "az datafactory linked-service show --factory-name example -g rg -n BlobStore"
expect_guard_rc "Azure Data Factory pipeline run is blocked" 10 "az datafactory pipeline create-run --factory-name example -g rg -n sample"
expect_guard_rc "Azure Data Factory pipeline delete is blocked" 10 "az datafactory pipeline delete --factory-name example -g rg -n sample"
expect_guard_rc "Azure Key Vault secret listing allows a vault named like a secret" 0 "az keyvault secret list --vault-name prod-secrets"
expect_guard_rc "Azure Key Vault secret listing blocks a sensitive value even when the vault shares its name" 10 "az keyvault secret list --vault-name secrets --query secrets"
expect_guard_rc "Azure Key Vault secret listing with a sensitive flag is blocked" 10 "az keyvault secret list --vault-name example --query secrets"
expect_guard_rc "Azure Key Vault secret output is blocked" 10 "az keyvault secret show --vault-name example --name sample"
expect_guard_rc "Azure storage key output is blocked" 10 "az storage account keys list --account-name example"
expect_guard_rc "Azure registry credential output is blocked" 10 "az acr credential show --name example"
expect_guard_rc "Azure app setting output is blocked" 10 "az webapp config appsettings list --name example --resource-group rg"
expect_guard_rc "Azure connection string output is blocked" 10 "az webapp config connection-string list --name example --resource-group rg"
expect_guard_rc "Kubernetes Secret output is blocked" 10 "kubectl get secret sample -o yaml"
expect_guard_rc "qualified Kubernetes Secret output is blocked" 10 "kubectl get secrets.v1/sample -o yaml"
expect_guard_rc "comma-grouped Kubernetes Secret output is blocked" 10 "kubectl get pods,secrets.v1 -o yaml"
expect_guard_rc "trailing-dot Kubernetes Secret output is blocked" 10 "kubectl get secrets.v1. -o yaml"
expect_guard_rc "Kubernetes raw API output is blocked" 10 "kubectl get --raw /api/v1/namespaces/default/secrets/sample"
expect_guard_rc "Kubernetes equals-form raw API output is blocked" 10 "kubectl get --raw=/api/v1/namespaces/default/secrets/sample"
expect_guard_rc "Kubernetes filename resource output is blocked" 10 "kubectl get -f /tmp/secret-manifest.yaml -o yaml"
expect_guard_rc "Kubernetes equals-form filename output is blocked" 10 "kubectl get --filename=/tmp/secret-manifest.yaml -o json"
expect_guard_rc "Kubernetes kustomize resource output is blocked" 10 "kubectl get -k /tmp/secret-kustomization -o yaml"
expect_guard_rc "Kubernetes equals-form kustomize output is blocked" 10 "kubectl get --kustomize=/tmp/secret-kustomization -o json"
expect_guard_rc "Kubernetes diff output is blocked" 10 "kubectl diff -f /tmp/secret-manifest.yaml"
expect_guard_rc "raw Kubernetes config output is blocked" 10 "kubectl config view --raw"
expect_guard_rc "Terraform output is blocked" 10 "terraform output -raw db_password"
expect_guard_rc "Terraform state show is blocked" 10 "terraform show -json terraform.tfstate"

printf 'apiVersion: v1\nkind: ConfigMap\n' > "$TMPDIR_TEST/kubernetes.yaml"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system kubernetes --summary "apply reviewed manifest" -- \
  kubectl apply -f kubernetes.yaml > "$TMPDIR_TEST/kubernetes-prepared.json"
expect_jq "Kubernetes manifest content is bound" \
  '.action.payload_files | length == 1' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/kubernetes-prepared.json")"

printf 'reviewed plan\n' > "$TMPDIR_TEST/reviewed.tfplan"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system terraform --summary "apply reviewed plan" -- \
  terraform apply reviewed.tfplan > "$TMPDIR_TEST/terraform-prepared.json"
expect_jq "Terraform plan content is bound" \
  '.action.payload_files | length == 1' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/terraform-prepared.json")"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system terraform --summary "apply current configuration" -- \
  terraform -chdir=. apply -auto-approve > "$TMPDIR_TEST/terraform-chdir-prepared.json"
expect_jq "Terraform global option does not become a payload file" \
  '.action.payload_files | length == 0' \
  "$(jq -r '.manifest' "$TMPDIR_TEST/terraform-chdir-prepared.json")"

manifest=$(prepare_action)
if [[ -f "$manifest" ]] && jq -e '.action.argv[0] == "gh" and .action.github_host == "github.com" and .action.github_owner == "owner" and .action.github_account == "expected" and .action.payload_sha256' "$manifest" >/dev/null; then
  report 0 "prepare writes a payload-bound manifest"
else
  report 1 "prepare writes a payload-bound manifest"
fi

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-token-args" NASE_FAKE_CAPTURE_ENV="$TMPDIR_TEST/gh-token-env" \
  PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ "$(<"$TMPDIR_TEST/gh-token-env")" == "github.com|unset|set|expected" ]] \
  && grep -q -- 'pr create --draft' "$TMPDIR_TEST/gh-token-args"; then
  report 0 "execute uses the manifest-bound GitHub token without switching accounts"
else
  report 1 "execute uses the manifest-bound GitHub token without switching accounts"
fi

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
expect_rc "GitHub token actor mismatch is blocked" 2 \
  env NASE_FAKE_TOKEN_ACTOR=other NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-actor-mismatch-args" \
  PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
expect_rc "GitHub token lookup failure is blocked" 2 \
  env NASE_FAKE_TOKEN_FAIL=1 NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-token-failure-args" \
  PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
sed -i.bak 's/work_gh_account: expected/work_gh_account: changed/' "$TMPDIR_TEST/workspace/config.md"
expect_rc "GitHub account drift after approval is blocked" 2 \
  env NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-drift-args" PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
mv "$TMPDIR_TEST/workspace/config.md.bak" "$TMPDIR_TEST/workspace/config.md"

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --summary "create personal draft PR" -- \
  gh pr create --draft --title "Example" --body "payload" -R personal/example > "$TMPDIR_TEST/personal-prepared.json"
manifest=$(jq -r '.manifest' "$TMPDIR_TEST/personal-prepared.json")
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/personal-gh-args" NASE_FAKE_CAPTURE_ENV="$TMPDIR_TEST/personal-gh-env" \
  PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ "$(<"$TMPDIR_TEST/personal-gh-env")" == "github.com|unset|set|personal" ]] \
  && grep -q -- 'pr create --draft' "$TMPDIR_TEST/personal-gh-args"; then
  report 0 "personal target selects the personal GitHub token"
else
  report 1 "personal target selects the personal GitHub token"
fi

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
GH_REPO=personal/example GH_TOKEN=test-only-placeholder \
  NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-env-args" NASE_FAKE_CAPTURE_ENV="$TMPDIR_TEST/gh-env" \
  PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ "$(<"$TMPDIR_TEST/gh-env")" == "github.com|unset|set|expected" ]]; then
  report 0 "GitHub execution replaces repository and token environment overrides"
else
  report 1 "GitHub execution replaces repository and token environment overrides"
fi

GH_REPO=personal/example python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --summary "create current-origin draft PR" -- \
  gh pr create --draft --title "Example" --body "payload" > "$TMPDIR_TEST/gh-repo-prepared.json"
gh_repo_manifest=$(jq -r '.manifest' "$TMPDIR_TEST/gh-repo-prepared.json")
expect_jq "GH_REPO does not redirect owner selection" \
  '.action.github_owner == "owner"' "$gh_repo_manifest"

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --summary "create current-repo draft PR" -- \
  gh pr create --draft --title "Example" --body "payload" > "$TMPDIR_TEST/origin-prepared.json"
origin_manifest=$(jq -r '.manifest' "$TMPDIR_TEST/origin-prepared.json")
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$origin_manifest" >/dev/null
git -C "$TMPDIR_TEST" remote set-url origin https://github.com/personal/example.git
expect_rc "origin target drift after approval is blocked" 2 \
  env NASE_FAKE_OUTPUT="$TMPDIR_TEST/origin-drift-args" PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$origin_manifest"
git -C "$TMPDIR_TEST" remote set-url origin https://github.com/owner/example.git

manifest=$(prepare_action)

expect_rc "authorization rejects an invalid TTL" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" --ttl-seconds 301

expect_rc "execute without token is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-args" PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if grep -q -- 'pr create --draft' "$TMPDIR_TEST/gh-args" && [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "authorized action runs once and consumes token"
else
  report 1 "authorized action runs once and consumes token"
fi

# A non-GitHub write must not inherit ambient GitHub credentials, while keeping the
# target selector that belongs to its own system.
cat > "$TMPDIR_TEST/bin/az" <<'SH'
#!/usr/bin/env bash
{
  printf 'GH_TOKEN=%s\n' "${GH_TOKEN-unset}"
  printf 'GITHUB_TOKEN=%s\n' "${GITHUB_TOKEN-unset}"
  printf 'GH_REPO=%s\n' "${GH_REPO-unset}"
  printf 'KUBECONFIG=%s\n' "${KUBECONFIG-unset}"
  printf 'AZURE_CONFIG_DIR=%s\n' "${AZURE_CONFIG_DIR-unset}"
} > "$NASE_FAKE_ENV_OUTPUT"
exit 0
SH
chmod +x "$TMPDIR_TEST/bin/az"

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system azure --summary "patch pipeline" -- \
  az rest --method patch --uri https://example.invalid --body '{}' > "$TMPDIR_TEST/az-prepared.json"
manifest=$(jq -r '.manifest' "$TMPDIR_TEST/az-prepared.json")
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
GH_TOKEN=ambient-gh GITHUB_TOKEN=ambient-github GH_REPO=owner/example \
  KUBECONFIG="$TMPDIR_TEST/kubeconfig" AZURE_CONFIG_DIR="$TMPDIR_TEST/azure-config" \
  NASE_FAKE_ENV_OUTPUT="$TMPDIR_TEST/az-env" PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest" \
  2> "$TMPDIR_TEST/az-stderr"
if grep -qx 'GH_TOKEN=unset' "$TMPDIR_TEST/az-env" \
  && grep -qx 'GITHUB_TOKEN=unset' "$TMPDIR_TEST/az-env" \
  && grep -qx 'GH_REPO=unset' "$TMPDIR_TEST/az-env"; then
  report 0 "non-GitHub write strips ambient GitHub credentials"
else
  report 1 "non-GitHub write strips ambient GitHub credentials" "$(tr '\n' ' ' < "$TMPDIR_TEST/az-env")"
fi
if grep -qxF "AZURE_CONFIG_DIR=$TMPDIR_TEST/azure-config" "$TMPDIR_TEST/az-env" \
  && grep -qxF "KUBECONFIG=$TMPDIR_TEST/kubeconfig" "$TMPDIR_TEST/az-env"; then
  report 0 "non-GitHub write keeps its target selectors"
else
  report 1 "non-GitHub write keeps its target selectors" "$(tr '\n' ' ' < "$TMPDIR_TEST/az-env")"
fi
if grep -q 'AZURE_CONFIG_DIR is set' "$TMPDIR_TEST/az-stderr" \
  && ! grep -q 'KUBECONFIG is set' "$TMPDIR_TEST/az-stderr"; then
  report 0 "selector note names only the variables its system reads"
else
  report 1 "selector note names only the variables its system reads" "$(tr '\n' ' ' < "$TMPDIR_TEST/az-stderr")"
fi

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
python3 - "$manifest" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["action"]["summary"] = "tampered"
path.write_text(json.dumps(data))
PY
expect_rc "tampered manifest is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "tamper failure consumes token"
else
  report 1 "tamper failure consumes token"
fi

expect_rc "read-only command cannot become an external write action" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "read" -- gh pr view 7

manifest=$(prepare_action)
printf '{not valid json\n' > "$TMPDIR_TEST/workspace/.external-write-token"
expect_rc "malformed token is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "malformed-token failure consumes token"
else
  report 1 "malformed-token failure consumes token"
fi

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" --ttl 1 >/dev/null
python3 - "$TMPDIR_TEST/workspace/.external-write-token" <<'PY'
import json
import pathlib

path = pathlib.Path(__import__('sys').argv[1])
token = json.loads(path.read_text())
token['created_at'] = '2000-01-01T00:00:00Z'
path.write_text(json.dumps(token))
PY
expect_rc "expired token is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "expired-token failure consumes token"
else
  report 1 "expired-token failure consumes token"
fi

PAYLOAD_FILE="$TMPDIR_TEST/pr-body.md"
printf 'approved body\n' > "$PAYLOAD_FILE"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system github --summary "edit PR body" -- \
  gh pr edit 7 --body-file "$PAYLOAD_FILE" -R owner/example > "$TMPDIR_TEST/payload-prepared.json"
manifest=$(jq -r '.manifest' "$TMPDIR_TEST/payload-prepared.json")
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
printf 'changed after approval\n' > "$PAYLOAD_FILE"
expect_rc "payload drift is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "payload-drift failure consumes token"
else
  report 1 "payload-drift failure consumes token"
fi

EQUALS_PAYLOAD="$TMPDIR_TEST/equals-body.json"
printf '{"approved":true}\n' > "$EQUALS_PAYLOAD"
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system azure --summary "patch pipeline payload" -- \
  az rest --method patch --uri https://example.invalid --body="@$EQUALS_PAYLOAD" > "$TMPDIR_TEST/equals-prepared.json"
manifest=$(jq -r '.manifest' "$TMPDIR_TEST/equals-prepared.json")
if jq -e '.action.payload_files | any(.arg_index == 6 and (.sha256 | type == "string"))' "$manifest" >/dev/null; then
  report 0 "equals-form payload is hash-bound"
else
  report 1 "equals-form payload is hash-bound"
fi
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
printf '{"changed":true}\n' > "$EQUALS_PAYLOAD"
expect_rc "equals-form payload drift is blocked" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

# `az acr build` builds + pushes an image — a mutation that must route through the gate.
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system azure --summary "acr build" -- \
  az acr build --registry example --image app:tag . > "$TMPDIR_TEST/acr-build-prepared.json"
if jq -e '.action.system == "azure"' "$(jq -r '.manifest' "$TMPDIR_TEST/acr-build-prepared.json")" >/dev/null; then
  report 0 "az acr build is gated as an azure mutation"
else
  report 1 "az acr build is gated as an azure mutation"
fi

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system azure --summary "acr import" -- \
  az acr import --name example --source source/image:tag > "$TMPDIR_TEST/acr-import-prepared.json"
if jq -e '.action.system == "azure"' "$(jq -r '.manifest' "$TMPDIR_TEST/acr-import-prepared.json")" >/dev/null; then
  report 0 "az acr import is gated as an azure mutation"
else
  report 1 "az acr import is gated as an azure mutation"
fi

python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare \
  --system terraform --summary "terraform import" -- \
  terraform -chdir=/tmp import aws_instance.example i-123 > "$TMPDIR_TEST/terraform-import-prepared.json"
if jq -e '.action.system == "terraform"' "$(jq -r '.manifest' "$TMPDIR_TEST/terraform-import-prepared.json")" >/dev/null; then
  report 0 "terraform import after a global option is gated"
else
  report 1 "terraform import after a global option is gated"
fi

expect_rc "azure read operand named import stays read-only" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "read" -- \
  az storage blob show --container-name example --name import

expect_rc "terraform output named import stays read-only" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system terraform --summary "read" -- \
  terraform -chdir=/tmp output import

expect_rc "az acr show stays read-only (not a mutation)" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "read" -- az acr show --name example

expect_rc "az rest short -m PATCH is classified as a mutation" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "write" -- az rest -m patch --url https://example.invalid
expect_rc "az devops invoke --http-method POST is classified as a mutation" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "write" -- az devops invoke --area build --resource builds --http-method POST
expect_rc "az rest with a body and no method is classified as a mutation" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "write" -- az rest --url https://example.invalid --body {}
expect_rc "az rest abbreviated method is classified as a mutation" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "write" -- az rest --url https://example.invalid --metho post
expect_rc "az rest GET is not a mutation" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "read" -- az rest --url https://example.invalid

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
python3 - "$manifest" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data['action']['argv'][data['action']['argv'].index('owner/example')] = 'owner/other-target'
data['action']['payload_sha256'] = hashlib.sha256(json.dumps(
    {'argv': data['action']['argv'], 'payload_files': data['action']['payload_files']},
    sort_keys=True, separators=(',', ':')).encode()).hexdigest()
data['action_sha256'] = hashlib.sha256(json.dumps(
    data['action'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
path.write_text(json.dumps(data))
PY
expect_rc "changed action target is blocked by token binding" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-failure-args" NASE_FAKE_EXIT=7 PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest" || failure_rc=$?
if [[ "${failure_rc:-0}" -eq 7 ]] && [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "command failure consumes token"
else
  report 1 "command failure consumes token"
fi

expect_rc "successful action cannot be repeated" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"

manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-concurrent-args" NASE_FAKE_WAIT=2 PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest" > "$TMPDIR_TEST/concurrent.out" 2> "$TMPDIR_TEST/concurrent.err" &
execute_pid=$!
for _ in $(seq 1 20); do
  compgen -G "$TMPDIR_TEST/workspace/.external-write-token.executing-*" >/dev/null && break
  sleep 0.1
done
expect_rc "claimed token blocks concurrent execute" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest"
expect_rc "claimed token blocks new authorization" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest"
wait "$execute_pid"
if [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]] \
  && ! compgen -G "$TMPDIR_TEST/workspace/.external-write-token.executing-*" >/dev/null; then
  report 0 "claimed token is consumed after execution"
else
  report 1 "claimed token is consumed after execution"
fi

# A rejected timeout must be caught before the token is claimed, otherwise bad input
# burns an approval the user has to give again. Asserting rc=2 alone would not show
# that: a spent token returns 2 as well. The surviving token file is the discriminator.
manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
expect_rc "non-positive execute timeout is rejected" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest" --timeout-seconds 0
if [[ -e "$TMPDIR_TEST/workspace/.external-write-token" ]]; then
  report 0 "a rejected timeout leaves the approval token unspent"
else
  report 1 "a rejected timeout leaves the approval token unspent"
fi

# Exit 11, not the generic failure code: a killed write may already have landed, so
# the caller must not read it as "nothing happened". Reuses the token still standing
# from the rejected call above.
timeout_rc=0
NASE_FAKE_OUTPUT="$TMPDIR_TEST/gh-timeout-args" NASE_FAKE_WAIT=5 PATH="$TMPDIR_TEST/bin:$PATH" \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$manifest" \
  --timeout-seconds 1 > "$TMPDIR_TEST/timeout.out" 2> "$TMPDIR_TEST/timeout.err" || timeout_rc=$?
if [[ "$timeout_rc" -eq 11 ]] \
  && grep -q 'TIMEOUT' "$TMPDIR_TEST/timeout.err" \
  && grep -q 'MAY already have been applied' "$TMPDIR_TEST/timeout.err" \
  && [[ ! -e "$TMPDIR_TEST/workspace/.external-write-token" ]] \
  && ! compgen -G "$TMPDIR_TEST/workspace/.external-write-token.executing-*" >/dev/null; then
  report 0 "hung write is killed, reported as unknown-outcome, and consumes the token"
else
  report 1 "hung write is killed, reported as unknown-outcome, and consumes the token" \
    "rc=$timeout_rc err=$(tr '\n' ' ' < "$TMPDIR_TEST/timeout.err")"
fi

# The token and actor lookups run before the mutation, so bounding only the mutation
# would move the hang here instead of removing it. A preflight stall is a clean exit 2:
# nothing ran, and the manifest's own fake gh never gets reached.
mkdir -p "$TMPDIR_TEST/hangbin"
cat > "$TMPDIR_TEST/hangbin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "auth token" ]]; then
  sleep 30
fi
exit 0
SH
chmod +x "$TMPDIR_TEST/hangbin/gh"
manifest=$(prepare_action)
python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$manifest" >/dev/null
preflight_rc=0
PATH="$TMPDIR_TEST/hangbin:$PATH" \
  python3 - "$SCRIPT" "$TMPDIR_TEST" "$manifest" > "$TMPDIR_TEST/preflight.out" \
  2> "$TMPDIR_TEST/preflight.err" <<'PY' || preflight_rc=$?
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("external_write_action", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.GITHUB_PREFLIGHT_TIMEOUT_SECONDS = 1
sys.argv = ["external-write-action.py", "--root", sys.argv[2], "execute", "--manifest", sys.argv[3]]
raise SystemExit(module.main())
PY
if [[ "$preflight_rc" -eq 2 ]] && grep -q 'timed out' "$TMPDIR_TEST/preflight.err" \
  && grep -q 'nothing was mutated' "$TMPDIR_TEST/preflight.err"; then
  report 0 "a hung preflight gh call is bounded and reported as nothing-mutated"
else
  report 1 "a hung preflight gh call is bounded and reported as nothing-mutated" \
    "rc=$preflight_rc err=$(tr '\n' ' ' < "$TMPDIR_TEST/preflight.err")"
fi

# --- every file a CLI reads is bound into the approved action ---------------
# The flag tables miss short forms and flags added later, so a file could change
# after approval while the hash still matched. Bound files come from the tables
# and from any other word that names an existing regular file.
printf 'bound body\n' > "$TMPDIR_TEST/bind-body.md"
printf '{"spec":{}}\n' > "$TMPDIR_TEST/bind-body.json"
printf 'kind: Patch\n' > "$TMPDIR_TEST/bind-patch.yaml"
printf 'kind: Pod\n' > "$TMPDIR_TEST/bind-pod.yaml"

expect_bound() {
  local name="$1" system="$2" suffix="$3"
  shift 3
  if python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system "$system" --summary "$name" -- "$@" \
    > "$TMPDIR_TEST/bound.json" 2> "$TMPDIR_TEST/err" \
    && jq -e --arg suffix "$suffix" \
      '.action.payload_files | length >= 1 and all(.[]; .arg and .sha256) and any(.[]; .path | endswith($suffix))' \
      "$TMPDIR_TEST/bound.json" > /dev/null; then
    report 0 "$name"
  else
    report 1 "$name" "$(cat "$TMPDIR_TEST/err") $(cat "$TMPDIR_TEST/bound.json")"
  fi
}

expect_bound "gh pr comment -F body file is bound" github bind-body.md \
  gh pr comment 1 -F bind-body.md -R owner/example
expect_bound "gh pr comment attached -Ffile is bound" github bind-body.md \
  gh pr comment 1 -Fbind-body.md -R owner/example
expect_bound "gh pr create -F body file is bound" github bind-body.md \
  gh pr create --draft --title Example -F bind-body.md -R owner/example
expect_bound "gh pr edit -F body file is bound" github bind-body.md \
  gh pr edit 1 -F bind-body.md -R owner/example
expect_bound "gh pr review -F body file is bound" github bind-body.md \
  gh pr review 1 --approve -F bind-body.md -R owner/example
expect_bound "gh issue comment -F body file is bound" github bind-body.md \
  gh issue comment 1 -F bind-body.md -R owner/example
expect_bound "gh release create -F notes file is bound" github bind-body.md \
  gh release create v1.0.0 -F bind-body.md -R owner/example
expect_bound "gh api -F key=@file is bound" github bind-body.md \
  gh api repos/owner/example/issues/1/comments --method POST -F body=@bind-body.md
expect_bound "gh api clustered -iF key=@file is bound" github bind-body.md \
  gh api repos/owner/example/issues/1/comments -iX POST -iF body=@bind-body.md
expect_bound "az devops invoke --in-file is bound" azure bind-body.json \
  az devops invoke --area build --resource builds --http-method POST \
    --in-file bind-body.json --org https://dev.azure.com/example
expect_bound "kubectl patch --patch-file is bound" kubernetes bind-patch.yaml \
  kubectl patch deployment web --patch-file bind-patch.yaml
expect_bound "kubectl apply attached -fFILE is bound" kubernetes bind-pod.yaml \
  kubectl apply -fbind-pod.yaml
expect_bound "kubectl apply -f=FILE is bound" kubernetes bind-pod.yaml \
  kubectl apply -f=bind-pod.yaml
expect_bound "an unlisted file-valued flag is bound by the file it names" kubernetes bind-pod.yaml \
  kubectl apply --made-up-manifest bind-pod.yaml
expect_bound "an unlisted --flag=FILE form is bound" kubernetes bind-pod.yaml \
  kubectl apply --made-up-manifest=bind-pod.yaml
expect_rc "gh api -F key=@missing file is rejected" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "missing" -- \
    gh api repos/owner/example/issues/1/comments --method POST -F body=@bind-missing.md

# The prose gate reads the bound files, so a `-F` body no longer skips it.
mkdir -p "$TMPDIR_TEST/.claude/scripts"
cp "$ROOT/.claude/scripts/prose-lint.py" "$TMPDIR_TEST/.claude/scripts/prose-lint.py"
printf 'This is fine \342\200\224 really.\n' > "$TMPDIR_TEST/bind-dash.md"
run_gh_execute() {
  python3 "$SCRIPT" --root "$TMPDIR_TEST" authorize --manifest "$1" > /dev/null
  NASE_FAKE_OUTPUT="$TMPDIR_TEST/section-gh-args" PATH="$TMPDIR_TEST/bin:$PATH" \
    python3 "$SCRIPT" --root "$TMPDIR_TEST" execute --manifest "$1"
}
manifest=$(python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "dash body" -- \
  gh pr comment 1 -F bind-dash.md -R owner/example | jq -r .manifest)
expect_rc "a -F body file is held to the prose gate" 2 run_gh_execute "$manifest"
if grep -q 'plain-writing gate' "$TMPDIR_TEST/err"; then
  report 0 "the -F prose gate failure names the gate"
else
  report 1 "the -F prose gate failure names the gate" "$(cat "$TMPDIR_TEST/err")"
fi
rm -f "$TMPDIR_TEST/.claude/scripts/prose-lint.py"

manifest=$(python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "short body" -- \
  gh pr comment 1 -F bind-body.md -R owner/example | jq -r .manifest)
printf 'edited after approval\n' > "$TMPDIR_TEST/bind-body.md"
expect_rc "a -F body edited after approval is refused" 2 run_gh_execute "$manifest"
printf 'bound body\n' > "$TMPDIR_TEST/bind-body.md"

# --- a symlink cannot be retargeted after approval ---------------------------
# The manifest hashes the resolved file, but the CLI opens the path as written.
printf 'approved text\n' > "$TMPDIR_TEST/link-a.md"
printf 'swapped text\n' > "$TMPDIR_TEST/link-b.md"
ln -sf link-a.md "$TMPDIR_TEST/link.md"
expect_rc "a symlinked body file is rejected at prepare" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "link" -- \
    gh pr comment 1 --body-file link.md -R owner/example
expect_rc "a symlinked -F body file is rejected at prepare" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "link" -- \
    gh pr comment 1 -F link.md -R owner/example
mkdir -p "$TMPDIR_TEST/real-dir"
printf 'in dir\n' > "$TMPDIR_TEST/real-dir/body.md"
ln -sfn real-dir "$TMPDIR_TEST/link-dir"
expect_rc "a body file under a symlinked directory is rejected at prepare" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "link" -- \
    gh pr comment 1 --body-file link-dir/body.md -R owner/example
expect_rc "a body file behind a dotdot hop through a symlink is rejected" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "link" -- \
    gh pr comment 1 --body-file link-dir/../real-dir/body.md -R owner/example
expect_rc "a symlinked --input payload is rejected at prepare" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --github-owner owner --summary "link" -- \
    gh api --method POST "$REPLY_ENDPOINT" --input link.md
expect_rc "a symlink named only in an unrelated field is not rejected" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --github-owner owner --summary "incidental" -- \
    gh api "$REPLY_ENDPOINT" --method POST -f path=link.md -f body=hi
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system kubernetes --summary "unknown flag" -- \
  kubectl apply --made-up link.md > "$TMPDIR_TEST/implicit.json"
expect_jq "a symlink behind an unknown flag is still hashed" \
  '.action.payload_files | length == 1 and .[0].implicit == true' "$TMPDIR_TEST/implicit.json"
expect_rc "gh workflow run -F is a field, not a body file" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "dispatch" -- \
    gh workflow run deploy.yml --ref main -F env=prod -R owner/example
expect_rc "a regular file under the system temp alias is accepted" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "abs" -- \
    gh pr comment 1 --body-file "$TMPDIR_TEST/real-dir/body.md" -R owner/example

printf 'same text\n' > "$TMPDIR_TEST/swap.md"
manifest=$(python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system github --summary "swap" -- \
  gh pr comment 1 --body-file swap.md -R owner/example | jq -r .manifest)
mv "$TMPDIR_TEST/swap.md" "$TMPDIR_TEST/swap.real"
ln -s swap.real "$TMPDIR_TEST/swap.md"
expect_rc "a file replaced by a symlink after approval is refused" 2 run_gh_execute "$manifest"
if grep -q 'resolves elsewhere' "$TMPDIR_TEST/err"; then
  report 0 "the retarget refusal names the cause"
else
  report 1 "the retarget refusal names the cause" "$(cat "$TMPDIR_TEST/err")"
fi

# --- reads and mutations with global flags ------------------------------------
expect_guard_rc "kubectl -n NS get stays a read" 0 "kubectl -n prod get pods"
expect_guard_rc "kubectl attached -nNS get stays a read" 0 "kubectl -nprod get pods"
expect_guard_rc "kubectl --context=X get stays a read" 0 "kubectl --context=prod get pods"
expect_guard_rc "kubectl --context X --namespace Y describe stays a read" 0 \
  "kubectl --context prod --namespace web describe pod x"
expect_guard_rc "kubectl global flag before a secrets read stays blocked" 10 \
  "kubectl -n prod get secrets"
expect_guard_rc "kubectl unknown global flag fails closed" 10 "kubectl --weird x get pods"
expect_guard_rc "kubectl -n NS delete is still guarded" 10 "kubectl -n prod delete pod x"
expect_guard_rc "kubectl --context=X apply is still guarded" 10 \
  "kubectl --context=prod apply -f m.yaml"
expect_guard_rc "kubectl -n NS rollout restart is still guarded" 10 \
  "kubectl -n prod rollout restart deployment/web"
expect_rc "kubectl -n NS delete can be prepared" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system kubernetes --summary "delete pod" -- \
    kubectl -n prod delete pod x
expect_rc "kubectl --context=X -nNS delete can be prepared" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system kubernetes --summary "delete pod" -- \
    kubectl --context=prod -nweb delete pod x
expect_rc "a kubectl read cannot be prepared as a mutation" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system kubernetes --summary "read" -- \
    kubectl -n prod get pods

expect_guard_rc "terraform init is a read of the working directory" 0 "terraform init"
expect_guard_rc "terraform init with -chdir stays allowed" 0 "terraform -chdir=infra init -upgrade"
expect_guard_rc "terraform output is allowed" 0 "terraform output"
expect_guard_rc "terraform output of one name stays blocked" 10 "terraform output db_host"
expect_guard_rc "terraform output -json stays blocked" 10 "terraform output -json"
expect_guard_rc "terraform state list is allowed" 0 "terraform state list"
expect_guard_rc "terraform state pull stays blocked" 10 "terraform state pull"
expect_guard_rc "terraform state rm stays blocked" 10 "terraform state rm aws_x.y"
expect_guard_rc "terraform init -migrate-state is a mutation" 10 "terraform init -migrate-state"
expect_guard_rc "terraform apply is still guarded" 10 "terraform apply"
expect_guard_rc "terraform -chdir apply is still guarded" 10 "terraform -chdir=infra apply -auto-approve"
expect_guard_rc "terraform destroy is still guarded" 10 "terraform destroy"
expect_rc "terraform apply can be prepared" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system terraform --summary "apply" -- \
    terraform apply -auto-approve
expect_rc "terraform init -migrate-state can be prepared" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system terraform --summary "migrate" -- \
    terraform init -migrate-state

expect_guard_rc "az vm list is allowed" 0 "az vm list"
expect_guard_rc "az vm show is allowed" 0 "az vm show -g rg -n web"
expect_guard_rc "az keyvault list is allowed" 0 "az keyvault list"
expect_guard_rc "az sql db list is allowed" 0 "az sql db list -g rg -s server"
expect_guard_rc "az --version is allowed" 0 "az --version"
expect_guard_rc "az keyvault secret show stays blocked" 10 \
  "az keyvault secret show --vault-name v --name n"
expect_guard_rc "az vm delete is still guarded" 10 "az vm delete -g rg -n web"
expect_guard_rc "az vm deallocate is not a known read" 10 "az vm deallocate -g rg -n web"
expect_guard_rc "az sql db delete is still guarded" 10 "az sql db delete -g rg -s server -n db"
expect_rc "az vm delete can be prepared" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system azure --summary "delete vm" -- \
    az vm delete -g rg -n web --yes

# A substitution that only fills an argument of a literal gh read is not a way
# through, but one in the program, the noun or the verb still is.
expect_guard_rc "gh pr view with a substituted argument is allowed" 0 \
  'gh pr view $(git branch --show-current)'
expect_guard_rc "gh pr list with a backtick argument is allowed" 0 \
  'gh pr list --head `git branch --show-current`'
expect_guard_rc "gh pr view with a substituted argument piped on is allowed" 0 \
  'gh pr view $(git branch --show-current) --json title | cat'
expect_guard_rc "gh with a substituted verb stays blocked" 10 'gh pr $(echo create) 1'
expect_guard_rc "gh with a substituted noun stays blocked" 10 'gh $(echo pr) view 1'
expect_guard_rc "gh pr create with a substituted argument stays blocked" 10 \
  'gh pr create --title $(git branch --show-current)'
expect_guard_rc "gh auth status with a substituted argument stays blocked" 10 \
  'gh auth status $(echo -t)'
expect_guard_rc "a gh read inside a substitution stays blocked" 10 'echo "n: $(gh pr list)"'
expect_guard_rc "a substituted GH_HOST before a gh read stays blocked" 10 'GH_HOST=$(echo evil.example) gh pr view 5'

# --- Confluence attachment upload is a payload-bound write ---------------------
# `attach` posts bytes to any page with the stored Atlassian token.
mkdir -p "$TMPDIR_TEST/stub" "$TMPDIR_TEST/cplan/assets"
cat > "$TMPDIR_TEST/stub/confluence-publish.py" <<'PY'
import sys
open(sys.argv[0] + ".ran", "w").write(" ".join(sys.argv[1:]) + "\n")
PY
printf '{"pages":[{"index":0,"body_file":"cplan/page-000.body.html","visuals":[{"png":"chart-01.png","status":"pending"}]}]}\n' \
  > "$TMPDIR_TEST/cplan/plan.json"
printf '<p>body</p>\n' > "$TMPDIR_TEST/cplan/page-000.body.html"
printf 'png-bytes\n' > "$TMPDIR_TEST/cplan/assets/chart-01.png"
ATTACH_CMD="python3 .claude/scripts/confluence-publish.py attach --plan p.json --page-id 123 --account a@b.c"
expect_guard_rc "confluence-publish attach is a raw external write" 10 "$ATTACH_CMD"
expect_guard_rc "confluence-publish attach run as a script is a raw external write" 10 \
  ".claude/scripts/confluence-publish.py attach --plan p.json --page-id 123 --account a@b.c"
expect_guard_rc "confluence-publish attach with python options is a raw external write" 10 \
  "python3 -B .claude/scripts/confluence-publish.py attach --plan p.json --page-id 123 --account a@b.c"
expect_guard_rc "preparing an attach is not itself a raw write" 0 \
  "python3 .claude/scripts/external-write-action.py prepare --system confluence --summary x -- python3 .claude/scripts/confluence-publish.py attach --plan p.json --page-id 123 --account a@b.c"
expect_guard_rc "confluence-publish plan stays local" 0 \
  "python3 .claude/scripts/confluence-publish.py plan --source a.html --out-dir out"
expect_guard_rc "confluence-publish render stays local" 0 \
  "python3 .claude/scripts/confluence-publish.py render --plan p.json"
expect_guard_rc "confluence-publish ledger-lookup stays local" 0 \
  "python3 .claude/scripts/confluence-publish.py ledger-lookup --source a.md --pages 1"
expect_rc "a local confluence-publish subcommand cannot be prepared as a write" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "plan" -- \
    python3 stub/confluence-publish.py plan --source a.html --out-dir out
python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "attach charts" -- \
  python3 stub/confluence-publish.py attach --plan cplan/plan.json --page-index 0 \
  --page-id 123 --account a@b.c > "$TMPDIR_TEST/attach-prepared.json"
expect_jq "attach binds the script, the plan, the body file and every pending PNG" \
  '.action.system == "confluence" and (.action.payload_files | map(.path | split("/") | last) | sort) == ["chart-01.png","confluence-publish.py","page-000.body.html","plan.json"]' \
  "$TMPDIR_TEST/attach-prepared.json"
manifest=$(jq -r .manifest "$TMPDIR_TEST/attach-prepared.json")
printf 'swapped-png\n' > "$TMPDIR_TEST/cplan/assets/chart-01.png"
expect_rc "an attach PNG swapped after approval is refused" 2 run_gh_execute "$manifest"
printf 'png-bytes\n' > "$TMPDIR_TEST/cplan/assets/chart-01.png"
manifest=$(python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "attach charts" -- \
  python3 stub/confluence-publish.py attach --plan cplan/plan.json --page-index 0 \
  --page-id 123 --account a@b.c | jq -r .manifest)
expect_rc "an approved attach runs through the helper" 0 run_gh_execute "$manifest"
if grep -q 'attach --plan cplan/plan.json' "$TMPDIR_TEST/stub/confluence-publish.py.ran" 2>/dev/null; then
  report 0 "the approved attach argv reaches the script"
else
  report 1 "the approved attach argv reaches the script"
fi

printf '{"pages":[{"index":0,"body_file":"cplan/page-000.body.html","visuals":[{"png":"chart-01.png","status":"pending"}]},{"index":1,"body_file":"cplan/page-001.body.html","visuals":[{"png":"missing-02.png","status":"skipped:no-renderer"}]}]}\n' \
  > "$TMPDIR_TEST/cplan/two-pages.json"
expect_rc "an unrendered visual on another page does not block prepare" 0 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "page 0" -- \
    python3 stub/confluence-publish.py attach --plan cplan/two-pages.json --page-index 0 \
    --page-id 123 --account a@b.c
expect_rc "an abbreviated --page-in is read as the page index" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "page 1" -- \
    python3 stub/confluence-publish.py attach --plan cplan/two-pages.json --page-in 1 \
    --page-id 123 --account a@b.c
expect_rc "a repeated --page-index uses the last value" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "page 1" -- \
    python3 stub/confluence-publish.py attach --plan cplan/two-pages.json --page-index 0 --page-index 1 \
    --page-id 123 --account a@b.c
expect_rc "a missing body file on the chosen page is refused at prepare" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "page 1" -- \
    python3 stub/confluence-publish.py attach --plan cplan/two-pages.json --page-index 1 \
    --page-id 123 --account a@b.c
printf '{"pages":[1]}\n' > "$TMPDIR_TEST/cplan/malformed.json"
expect_rc "an attach plan with a malformed page entry is refused at prepare" 2 \
  python3 "$SCRIPT" --root "$TMPDIR_TEST" prepare --system confluence --summary "malformed" -- \
    python3 stub/confluence-publish.py attach --plan cplan/malformed.json --page-index 0 \
    --page-id 123 --account a@b.c

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
