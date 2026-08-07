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
expect_guard_rc "raw gh auth switch is blocked" 10 "gh auth switch --user personal"
expect_guard_rc "raw gh auth logout is blocked" 10 "gh auth logout --hostname github.com"
expect_guard_rc "gh auth status remains read-only" 0 "gh auth status --active"
expect_guard_rc "dynamic executable variable is blocked" 10 'GH=gh; $GH pr create --draft --title Example'
expect_guard_rc "top-level alias is blocked" 10 "alias publish=gh; publish pr create --draft --title Example"
expect_guard_rc "top-level shell function is blocked" 10 "publish() { gh pr create --draft --title Example; }; publish"
expect_guard_rc "newline-separated mutation is blocked" 10 $'gh pr view 1\ngh pr create --draft --title Example'
expect_guard_rc "Azure access-token output is blocked" 10 "az account get-access-token"
expect_guard_rc "raw Azure login is blocked" 10 "az login"
expect_guard_rc "raw Azure logout is blocked" 10 "az logout"
expect_guard_rc "Azure account show remains read-only" 0 "az account show"
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

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
