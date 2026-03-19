---
name: nase:prep-merge
description: Prepare a PR for merge — verify all comments resolved, squash commits, force-push, and update PR title/description. Use when given a PR URL and asked to prepare, clean up, squash, finalize, or get a PR merge-ready. Also triggers on "prep merge", "squash and push", "clean up PR", "ready to merge", "finalize PR", or any request to tidy a PR's commit history before merging.
---

**Input:** $ARGUMENTS — a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`)

---

## Phase 0: Input Guard

If $ARGUMENTS is empty or does not contain a PR URL: output `Usage: /nase:prep-merge <PR-URL>` and stop.

Extract `owner`, `repo`, and `pr_number` from the URL.

## Phase 1: Fetch PR Metadata

```bash
gh pr view {pr_number} --repo {owner}/{repo} \
  --json number,title,url,body,headRefName,baseRefName,commits,additions,deletions,changedFiles,files,state,reviewDecision
```

Capture: `headRefName` (PR branch), `baseRefName` (target branch), commit list, changed files, current title/body, state, review decision.

If `state` is not `OPEN`: report "PR is already {state}" and stop.

## Phase 2: Verify All Comments Resolved

Use GraphQL to check for unresolved review threads:

```bash
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr_number}) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(first: 1) {
            nodes {
              body
              path
              author { login }
            }
          }
        }
      }
    }
  }
}'
```

Filter threads where `isResolved == false`.

**If unresolved threads exist:** list them and stop:

```
Cannot prep merge — {N} unresolved review thread(s):

  1. [{path}:{line}] @{author}: {comment_summary}
  2. ...

Resolve these first (or use /nase:address-comments {pr_url}).
```

**If all resolved:** proceed.

## Phase 3: Locate Repo

Read `work/context.md` to find the local path for this repo. If not found, ask the user.

## Phase 4: Fetch & Verify Branch State

```bash
git -C {repo_path} fetch origin
```

Check that the local tracking ref matches the remote — this guards against someone else having pushed to the branch after your last fetch:

```bash
# Get remote HEAD for the PR branch
git -C {repo_path} rev-parse origin/{pr_branch}
```

## Phase 5: Create Worktree

Create worktree on the PR branch for the squash operation:

```bash
git -C {repo_path} worktree add {worktree_path} origin/{pr_branch}
git -C {worktree_path} checkout -B {pr_branch} origin/{pr_branch}
```

Worktree path: `{repo_parent}/{repo_name}-prep-merge` (append `-1`, `-2` etc. if exists).

All subsequent operations use absolute paths to `{worktree_path}`. Do NOT use `EnterWorktree` — it creates its own worktree and won't adopt this one.

## Phase 6: Squash Commits

Count commits on the PR branch that are ahead of the target branch:

```bash
git -C {worktree_path} rev-list --count origin/{base_branch}..HEAD
```

If only 1 commit: skip squash — the history is already clean. Jump to Phase 7.

Perform a soft reset to squash all commits into one:

```bash
# Find the merge base
MERGE_BASE=$(git -C {worktree_path} merge-base origin/{base_branch} HEAD)

# Soft reset to merge base — keeps all changes staged
git -C {worktree_path} reset --soft $MERGE_BASE
```

Now craft the squash commit message. Read all the original commit messages to understand the full scope of changes:

```bash
git -C {worktree_path} log --format="%s%n%b" $MERGE_BASE..origin/{pr_branch}
```

Also read the changed files to understand the diff:

```bash
git -C {worktree_path} diff --cached --stat
```

Write a single conventional commit message that captures the full intent of the PR — not a list of the original commits, but a coherent summary. Then run `/nase:improve-commit-message --auto-accept` to polish it.

## Phase 7: Update PR Title & Description

The PR title should match the commit subject line (the first line of the squash commit message). This keeps the merge commit clean when the PR is merged with "Squash and merge" or "Rebase and merge" on GitHub.

### 7a: Look for a PR template

Check for a PR template in the repo (in order of precedence):

```bash
# Check common template locations
ls {repo_path}/.github/pull_request_template.md 2>/dev/null
ls {repo_path}/.github/PULL_REQUEST_TEMPLATE.md 2>/dev/null
ls {repo_path}/docs/pull_request_template.md 2>/dev/null
ls {repo_path}/.github/PULL_REQUEST_TEMPLATE/*.md 2>/dev/null | head -1
```

If a template is found, read it. Strip HTML comments (`<!-- ... -->`) — these are instructions to the author, not content to preserve.

### 7b: Draft the PR description

**If a template was found:** use it as the skeleton. For each section the template defines, fill it with content derived from:
- The full diff and changed files
- The original PR body (preserve any context the author already wrote)
- The commit history

Do not invent content for sections that cannot be determined from the code changes (e.g., leave Jira ticket placeholders as-is if no ticket is known, or ask the user). Preserve any checklist items from the template — do not pre-check boxes; leave those for the author to check.

**If no template exists:** use this default structure:

```
## Summary
{2-4 bullet points describing what changed and why}

## Changes
{brief list of key files/areas modified}
```

Do not include AI attribution.

Present the new title and description to the user for confirmation:

```
New PR title:
  {title}

New PR description:
  {description}

Squash commit message:
  {commit_message}
```

Ask:

```
question: "Ready to squash, force-push, and update the PR?"
header: "Confirm Prep Merge"
options:
  - label: "Go"
    description: "Squash → force-push → update PR title/description"
  - label: "Edit"
    description: "Let me adjust the title or description first"
  - label: "Abort"
    description: "Cancel — don't touch anything"
```

**If "Edit":** ask the user what to change, apply edits, then ask again.
**If "Abort":** clean up worktree and stop.

## Phase 8: Commit & Force Push

Create the squash commit (if not already done in Phase 6 for single-commit PRs):

```bash
git -C {worktree_path} commit -m "{squash_commit_message}"
```

Force push with lease — this is safer than `--force` because it fails if someone else pushed to the branch between our fetch and now:

```bash
git -C {worktree_path} push --force-with-lease origin {pr_branch}
```

If force-with-lease fails: report the error and stop. Someone pushed new commits — the user needs to reconcile.

## Phase 9: Update PR on GitHub

```bash
gh pr edit {pr_number} --repo {owner}/{repo} \
  --title "{new_title}" \
  --body "$(cat <<'EOF'
{new_description}
EOF
)"
```

## Phase 10: Cleanup & Report

Remove the worktree:
```bash
git -C {repo_path} worktree remove {worktree_path} --force
```

Print summary:

```
PR ready for merge ✓

  PR:           {pr_url}
  Branch:       {pr_branch} → {base_branch}
  Commits:      {original_count} → 1 (squashed)
  Title:        {new_title}
  Force-pushed: ✓ (--force-with-lease)
```

Then ask:

```
question: "Request a review now?"
header: "Request Review"
options:
  - label: "Yes — ping reviewers"
  - label: "No — I'll handle it"
```

Append to `work/logs/{YYYY-MM-DD}.md`:
```
- Prep merge: {repo_name}#{pr_number} — squashed {N} commits, updated title/description
```

**If "Yes":** run `/nase:request-review {pr_url}` immediately.
**If "No":** print `PR is ready — merge once approved.` and stop.

---

## Error Handling

- **Always use `--force-with-lease`** — never bare `--force`. This protects against overwriting someone else's push. If it fails, stop and tell the user rather than retrying with `--force`.
- **Unresolved comments block everything** — the whole point of this skill is to prepare a *clean* merge. If comments are unresolved, the PR isn't ready. Point the user to `/nase:address-comments`.
- **Single-commit PRs** — skip the squash, still update title/description if needed.
- **No AI attribution** — no "Co-Authored-By: Claude" in the commit or "Generated with Claude Code" in the PR description.
- **Confirm before destructive action** — squash + force-push rewrites history. Always show the user what will happen and get explicit confirmation.
- **Preserve co-authors** — when squashing, if the original commits have multiple authors, add `Co-Authored-By` trailers for the non-primary authors so their contribution is preserved in git history (but not for Claude/AI).
