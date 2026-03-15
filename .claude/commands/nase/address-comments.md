---
name: nase:address-comments
description: Address unresolved PR review comments — fetch, analyze, fix code or reply, then push and resolve. Use when given a PR URL and asked to handle, address, fix, or respond to review comments. Also triggers on "address comments", "fix review comments", "handle PR feedback", "resolve comments", or when the user pastes a PR URL and mentions comments, feedback, or review.
---

Address unresolved PR review comments — fetch, analyze, fix code or reply, then push and resolve.

**Input:** $ARGUMENTS — a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`)

---

## Phase 0: Input Guard

If $ARGUMENTS is empty or does not contain a PR URL: output `Usage: /nase:address-comments <PR-URL>` and stop.

Extract `owner`, `repo`, and `pr_number` from the URL.

## Phase 1: Locate Repo & Fetch Context

<parallel>
- Read `work/context.md` — find the local path for this repo
- Read `work/kb/.domain-map.md` — find the KB file for this repo
</parallel>

If the repo is not in `work/context.md`, ask the user for the local path.

Read the KB file — focus on **Build & Run Commands** and **Architecture** sections.

## Phase 2: Fetch Latest & Unresolved Review Threads

First, pull the latest from remote so local file contents match the PR head when reading referenced lines:

```bash
git -C {repo_path} fetch origin
```

Then use GraphQL to get all unresolved review threads in one call:

```bash
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr_number}) {
      headRefName
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          path
          line
          comments(first: 20) {
            nodes {
              id
              databaseId
              body
              author { login }
              createdAt
            }
          }
          diffSide
          startLine
          originalLine
          originalStartLine
          subjectType
        }
      }
    }
  }
}'
```

Filter to only threads where `isResolved == false`. Also capture `headRefName` (the PR branch).

If there are zero unresolved threads: report "No unresolved comments found" and stop.

## Phase 3: Analyze Comments & Present Plan

For each unresolved thread, read the comment chain and the referenced file + line range. Classify each thread into one of:

| Category | Meaning | Action |
|----------|---------|--------|
| **code-change** | Reviewer pointed out a real issue or requested a concrete change | Modify the code |
| **reply-only** | Question, discussion point, or the existing code is already correct | Write a reply explaining the reasoning |
| **unclear** | Cannot determine intent or requires design discussion | Ask the user |

Present the analysis to the user:

```
Found {N} unresolved review threads:

  1. [{path}:{line}] {first_comment_summary} → code-change: {what_you_plan_to_do}
  2. [{path}:{line}] {first_comment_summary} → reply-only: {draft_reply_summary}
  3. [{path}:{line}] {first_comment_summary} → unclear: {why}
  ...
```

For **unclear** threads, use AskUserQuestion to get guidance — present the full comment chain and ask what to do.

## Phase 4: Confirm Execution Mode

After the plan is presented and all unclear items are resolved, ask:

```
question: "How should I proceed?"
header: "Execution Mode"
options:
  - label: "Full auto"
    description: "Make all changes, build, test, push, and resolve — no more stops"
  - label: "Confirm before push"
    description: "Make changes and run build/tests, but pause for your review before pushing"
```

## Phase 5: Setup Worktree

Determine the PR branch name from `headRefName` (captured in Phase 2). Remote was already fetched in Phase 2.

```bash
# Create worktree on the PR branch
git -C {repo_path} worktree add {worktree_path} origin/{pr_branch}
```

Worktree path: `{repo_parent}/{repo_name}-address-comments` (append `-1`, `-2` etc. if exists).

All subsequent operations use absolute paths to `{worktree_path}`. Do NOT use `EnterWorktree` — it creates its own worktree and won't adopt this one.

```bash
# Make sure we're on the PR branch (not detached HEAD)
git -C {worktree_path} checkout -B {pr_branch} origin/{pr_branch}
```

## Phase 6: Execute Changes

### For code-change threads:

Read the file at the referenced path and line range. Apply the planned change — keep the diff minimal and focused on what the reviewer asked. Follow the repo's coding standards from KB / `CLAUDE.md`.

### For reply-only threads:

Draft the reply text. Replies should be concise, professional, and explain the reasoning clearly. Do not be defensive — acknowledge good points, explain technical decisions.

Hold all replies until Phase 9 (post-push) so the reviewer sees both the code fix and the reply together.

## Phase 7: Build & Test (max 5 iterations)

Get build and test commands from the KB file or repo's `CLAUDE.md`.

For each iteration:
1. Run the build command. On failure: read error, fix, retry.
2. Run the test command. On failure: fix production code (never modify tests to pass).
3. Both pass → proceed.

After 5 failures: stop, show the error, ask the user for guidance.

## Phase 8: Commit & Push

Stage only the changed files explicitly (never `git add -A`):

```bash
git -C {worktree_path} add {each_changed_file}
```

Quick secrets scan on staged files. If suspicious, stop and ask.

Create commit with a message like:
```
fix: address PR review comments

- {summary of change 1}
- {summary of change 2}
```

Then run `/nase:improve-commit-message --auto-accept`.

**If execution mode = "Confirm before push":**

Show the user the staged diff (`git diff --cached --stat` + key hunks) and the commit message. Ask:

```
question: "Ready to push these changes?"
header: "Push Confirmation"
options:
  - label: "Push"
    description: "Push and proceed to resolve comments"
  - label: "Abort"
    description: "Stop here — I'll handle it manually"
```

If aborted: print the worktree path so the user can continue manually, and stop.

**Push:**

```bash
git -C {worktree_path} push origin {pr_branch}
```

## Phase 9: Reply & Resolve Comments

After push succeeds, handle each thread:

### For code-change threads:

Reply acknowledging the fix, then resolve:

```bash
# Reply
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  -f body="Fixed — {brief description of what was changed}." \
  -f in_reply_to={comment_id} \
  --method POST

# Resolve the thread
gh api graphql -f query='
mutation {
  resolveReviewThread(input: { threadId: "{thread_graphql_id}" }) {
    thread { isResolved }
  }
}'
```

### For reply-only threads:

Post the reply, then resolve:

```bash
# Reply
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  -f body="{reply_text}" \
  -f in_reply_to={comment_id} \
  --method POST

# Resolve
gh api graphql -f query='
mutation {
  resolveReviewThread(input: { threadId: "{thread_graphql_id}" }) {
    thread { isResolved }
  }
}'
```

## Phase 10: Cleanup & Report

Remove the worktree:
```bash
git -C {repo_path} worktree remove {worktree_path} --force
```

Print summary:

```
PR comments addressed ✓

  PR:              {pr_url}
  Code changes:    {N} threads
  Replies:         {N} threads
  Resolved:        {total_resolved} / {total_threads}
  Build/test:      passed (iteration {N})

  Commit: {short_sha} — {commit_subject}
```

Append to `work/logs/{YYYY-MM-DD}.md`:
```
- Address comments: {repo_name}#{pr_number} — {N} resolved ({M} code changes, {K} replies)
```

---

## Error Handling

- **Never force-push** — this skill pushes normal commits on top of the existing PR branch.
- **Never modify tests** to make them pass — fix the production code.
- **Reply before resolve** — always post the reply so the reviewer sees the response, then resolve the thread.
- **Partial failure** — if some threads fail to resolve via API, report which ones failed and their thread IDs so the user can resolve manually.
- **No AI attribution** — no "Co-Authored-By: Claude" or "Generated with Claude Code" in commits or replies.
- **Respect reviewer intent** — when in doubt about what a reviewer means, ask the user rather than guessing. A wrong "fix" is worse than asking a question.
