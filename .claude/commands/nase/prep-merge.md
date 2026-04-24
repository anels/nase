---
name: nase:prep-merge
description: Prepare a PR for merge — verify all comments resolved, squash commits, force-push, and update PR title/description. Use when given a PR URL and asked to prepare, clean up, squash, finalize, or get a PR merge-ready. Also triggers on "prep merge", "squash and push", "clean up PR", "ready to merge", "finalize PR", or any request to tidy a PR's commit history before merging.
---

**Input:** $ARGUMENTS — a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`)

---

## Phase 0: Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md`.

## Phase 1: Fetch PR Metadata

Fetch PR metadata using the **full** variant from `.claude/docs/github-queries.md` (PR Metadata section).

Capture: `headRefName` (PR branch), `baseRefName` (target branch), commit list, changed files, current title/body, state, review decision.

If `state` is not `OPEN`: report "PR is already {state}" and stop.

## Phase 2: Verify All Comments Resolved

Use the **minimal variant** GraphQL query from `.claude/docs/github-queries.md` (Unresolved Review Threads section) to check for unresolved review threads.

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

Follow `.claude/docs/repo-resolution.md` Part 1 (Repo Resolution) to resolve the local path from the PR's `owner/repo`. If not found, ask the user.

## Phase 4: Fetch & Verify Branch State

```bash
git -C {repo_path} fetch origin
```

Check that the remote HEAD matches the PR metadata — this guards against someone else having pushed to the branch after the metadata was fetched:

```bash
# Get remote HEAD for the PR branch
REMOTE_SHA=$(git -C {repo_path} rev-parse origin/{pr_branch})
```

Compare `REMOTE_SHA` against `headRefOid` from the PR metadata fetched in Phase 1. If they differ, warn: "Branch has new commits since PR metadata was fetched — re-fetch metadata before continuing." and stop.

## Phase 5: Create Worktree

Follow the worktree pattern in `.claude/docs/worktree-pattern.md`. Suffix: `prep-merge`. Ref: `origin/{pr_branch}`. After creation, checkout the PR branch:

```bash
git -C {worktree_path} checkout -B {pr_branch} origin/{pr_branch}
```

## Phase 5.5: Fetch & Rebase

Fetch all remotes and rebase the PR branch on top of the target branch before squashing. This ensures the branch is up-to-date and the squashed commit lands cleanly on the latest base:

```bash
git -C {worktree_path} fetch --all
git -C {worktree_path} rebase origin/{base_branch}
```

If the rebase fails due to conflicts, stop immediately — do not proceed with squash or force-push. Run `git -C {worktree_path} rebase --abort` to restore the branch to its pre-rebase state, then report the conflicting files to the user and suggest resolving them locally before re-running prep-merge. Alternatively, the user can delete the worktree (`git -C {repo_path} worktree remove {worktree_path} --force`) and start fresh.

After a successful rebase, check if any files were auto-merged: `git -C {worktree_path} diff origin/{pr_branch}..HEAD`. If non-empty (code changed during rebase), run the build & test loop (`.claude/docs/build-test-loop.md`) before proceeding to ensure the rebased code still works.

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
*(Note: `origin/{pr_branch}` still points to the pre-rebase remote commits here — intentional. You want to summarize the original commit intent, not the rebase mechanics. The rebase result is already staged; Phase 8 commits it.)*

Also read the changed files to understand the diff:

```bash
git -C {worktree_path} diff --cached --stat
```

Write a single conventional commit message that captures the full intent of the PR — not a list of the original commits, but a coherent summary.

## Phase 7: Update PR Title & Description

The PR title should match the commit subject line (the first line of the squash commit message). This keeps the merge commit clean when the PR is merged with "Squash and merge" or "Rebase and merge" on GitHub.

### 7a–7b: PR Template & Description

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–4) to discover the PR template, draft the description, align the title with the commit subject, and preserve co-authors.

Follow `.claude/docs/pr-creation-pattern.md` for PR description formatting.

Present the new title and description to the user for confirmation:

```
New PR title:
  {title}

New PR description:
  {description}

Squash commit message:
  {commit_message}
```

Use the `AskUserQuestion` tool:

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

**If "Go":** proceed immediately to Phase 8 — do not pause or emit any intermediate message.
**If "Edit":** ask the user what to change, apply edits, then ask again.
**If "Abort":** clean up worktree and stop.

## Phase 8: Commit & Force Push

Create the squash commit (skip this step for single-commit PRs — Phase 6 was skipped and the commit already exists):

```bash
git -C {worktree_path} commit -m "{squash_commit_message}"
```

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md` (which handles `/nase:improve-commit-message` automatically).
Deviation: use `--force-with-lease` instead of normal push. If force-push fails, report the error and stop — someone pushed new commits and the user needs to reconcile.

## Phase 9: Update PR on GitHub

```bash
gh pr edit {pr_number} --repo {owner}/{repo} \
  --title "{new_title}" \
  --body "$(cat <<'NASE_PR_BODY'
{new_description}
NASE_PR_BODY
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

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `prep-merge`) **before** prompting (ensures the log is written regardless of the user's next choice).
Log: `{repo_name}#{pr_number} — squashed → 1 commit, force-pushed`

Then use the `AskUserQuestion` tool:

```
question: "Request a review now?"
header: "Request Review"
options:
  - label: "Yes — mark ready + ping reviewers"
    description: "Un-draft the PR, then DM code owners via /nase:request-review"
  - label: "No — I'll handle it"
    description: "Leave as draft; you decide when to promote"
```

**If "Yes":** first un-draft the PR, then run `/nase:request-review {pr_url}`:
```bash
gh pr ready {pr_number} --repo {owner}/{repo}
```
**If "No":** print `PR is ready — un-draft and request review when you're ready.` and stop.

---

## Error Handling

- **Always use `--force-with-lease`** — never bare `--force`. This protects against overwriting someone else's push. If it fails, stop and tell the user rather than retrying with `--force`.
- **Unresolved comments block everything** — the whole point of this skill is to prepare a *clean* merge. If comments are unresolved, the PR isn't ready. Point the user to `/nase:address-comments`.
- **Single-commit PRs** — skip the squash, still update title/description if needed.
- **Confirm before destructive action** — squash + force-push rewrites history. Always show the user what will happen and get explicit confirmation.
- **Preserve co-authors** — when squashing, if the original commits have multiple authors, add `Co-Authored-By` trailers for the non-primary authors so their contribution is preserved in git history (but not for Claude/AI).
