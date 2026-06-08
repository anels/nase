# PR Gate Remediation

Shared algorithm for `/nase:address-comments` after it has pushed or edited the
PR body. This doc owns the mechanical PR-gate sweep; callers only orchestrate.

## Scope

- Read PR checks once; do not poll.
- Fix only checks that are already failed and have a documented mechanical
  recipe.
- Pending, queued, canceled, skipped unexpectedly, or unknown checks are
  reported as current state, not treated as green.
- Any mutation still goes through the owning gate:
  - PR title/body edits: caller's PR metadata gate
  - Code commits/pushes: commit-push pattern
  - GitHub API calls: external mutation policy auth guard
- Hard-cap at two fix iterations.

## Classifier Helper

Use the helper before applying fallback recipes:

```bash
python3 .claude/scripts/pr-gate-remediation.py classify --name "$check_name"
```

The helper returns JSON with `recipe`, `action`, `mutation_owner`, and
`requires_user`. The doc below is still the source of truth for the detailed
recipe.

## Read Checks

```bash
checks_read_failed=false
checks_err=$(mktemp)
status_json=$(gh pr checks {pr_number} --repo {owner}/{repo} --json bucket,state,name,workflow,link 2>"$checks_err")
checks_rc=$?
if [ "$checks_rc" -ne 0 ] && [ "$checks_rc" -ne 8 ]; then
  echo "Unable to read PR checks; skipping PR gate check rather than treating checks as green." >&2
  cat "$checks_err" >&2
  checks_read_failed=true
fi
rm -f "$checks_err"
if [ "${checks_read_failed:-false}" != true ] && [ -z "$status_json" ]; then
  echo "Unable to read PR checks: gh returned no JSON. Skipping PR gate check." >&2
  checks_read_failed=true
fi
```

If `checks_read_failed=true`, report unknown gate status, log
`PR gates: unknown (check read failed)`, and stop the gate sweep.

## Identify Failures

```bash
failed=$(printf '%s' "$status_json" | jq -r '.[] | select(.bucket == "fail") | [.name, (.workflow // ""), (.link // "")] | @tsv')
non_green=$(printf '%s' "$status_json" | jq -r '.[] | select(.bucket != "pass" and .bucket != "skipping") | [.name, .bucket, (.workflow // ""), (.link // "")] | @tsv')
```

Zero failures and zero `non_green` rows means `PR gates: all green`. If failures
exist alongside pending rows, fix only currently failed rows with known recipes
and report pending rows without waiting.

## Mechanical Recipes

| Gate name pattern | Fix recipe |
|-------------------|------------|
| `Commit Lint` / `commitlint` | Pull failed-run log to identify the offending commit subject. If the bad commit has already been pushed, do not add a follow-up commit because commitlint will still fail on the original subject. Report the subject and ask whether to hand off to `/nase:prep-merge` or `/nase:improve-commit-message` with explicit force-push confirmation. Only run `/nase:improve-commit-message` directly when the offending commit is still local/unpushed. |
| `PR Description Check` / `pr-description-check` | Re-fetch body. If `## What` is shorter than 20 chars, extend it with the implementation summary from this session's commits. If `## Testing` is shorter than 15 chars, fill it with the build/test commands already run. Reuse the caller's PR body edit mutation gate. |
| `PR Size Check` / `pr-size-check` | Workflow only fails when `## How to Review` is empty. Fill it with a short walkthrough from `gh pr diff --name-only` plus per-file one-line intent. Reuse the caller's PR body edit mutation gate. |
| `Check for JIRA issue key` / `checkjiraissuekey` | Inspect PR title. If no `[A-Z]+-[0-9]+` token exists, ask the user for the Jira key. Show the exact new title, then reuse the caller's PR title edit mutation gate. |
| `EF Migration Checker` / migration drift | Read the bot drift comment to learn the missing `<Context>` name. Run `dotnet ef migrations add <Name> --context <Ctx>` in the worktree, rerun verification, then re-enter commit/push. Do not commit or push directly from this recipe. |
| `Lint Code Base` / `super-linter` | If the workflow has `continue-on-error: true`, log and skip. Otherwise the bot may auto-commit fixes back to the PR branch; run `git -C {worktree_path} pull --ff-only` so local matches remote, then continue. |
| Anything else | Derive `run_id` from the check link when it is a GitHub Actions URL, fetch the failed-run log, summarize in 3 lines, then ask `Fix manually now` / `Skip — leave failing` / `Show full log`. |

## KB Backfill

If the repo KB has no `## PR Gates` section, the caller may offer a backfill
after the sweep settles. Backfill is a local workspace write, not an external
mutation, but it still uses `.claude/docs/workspace-write-guard.md` and the
final drift check.
