---
name: nase:address-comments
description: Address unresolved PR review comments — fetch, analyze, fix code or reply, then push and resolve. Use when given a PR URL and asked to handle, address, fix, or respond to review comments. Also triggers on "address comments", "fix review comments", "handle PR feedback", "resolve comments", or when the user pastes a PR URL and mentions comments, feedback, or review.
---

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

Then use the **full variant** GraphQL query from `.claude/docs/github-queries.md` (Unresolved Review Threads section) to get all unresolved review threads in one call.

Filter to only threads where `isResolved == false`. Also capture `headRefName` (the PR branch).

If there are zero unresolved threads: report "No unresolved comments found" and stop.

## Phase 3: Critically Evaluate & Present Plan

For each unresolved thread, read the full comment chain AND the surrounding code context (not just the referenced line — read enough to understand the design intent). Then evaluate whether the suggestion genuinely improves the code.

**Evaluation criteria — ask these questions for each suggestion:**

1. **Correctness**: Does the reviewer's suggestion fix an actual bug or prevent a real failure mode? Or is the current code already correct?
2. **Context**: Does the reviewer have full context? Sometimes a suggestion makes sense locally but conflicts with constraints elsewhere (e.g., API contracts, performance requirements, framework limitations).
3. **Substance vs. style**: Is this a meaningful improvement to correctness, readability, or maintainability? Or is it a cosmetic/stylistic preference that doesn't materially improve the code?
4. **Risk**: Could accepting this change introduce a regression, break an invariant, or conflict with the broader design?

**Classify each thread based on the evaluation:**

| Category | When to use | Action |
|----------|-------------|--------|
| **accept** | Suggestion fixes a real issue, improves correctness, or meaningfully improves clarity/maintainability | Modify the code |
| **decline** | Current code is correct and the suggestion is stylistic, based on incomplete context, or would introduce risk | Reply explaining why the current approach is intentional |
| **reply-only** | Question, discussion point, or acknowledgment needed — no code involved | Write a reply |
| **unclear** | Cannot determine intent or requires design discussion | Ask the user |

The bar for `accept` is: "this change makes the code measurably better." If a suggestion is reasonable but the current code is equally valid, that's a `decline`.

**Present the plan to the user:**

```
Found {N} unresolved review threads:

  1. ✅ [{path}:{line}] {first_comment_summary} → accept: {what_you_plan_to_do}
  2. ↩️ [{path}:{line}] {first_comment_summary} → decline: {why current code is correct/better}
  3. 💬 [{path}:{line}] {first_comment_summary} → reply-only: {draft_reply_summary}
  4. ❓ [{path}:{line}] {first_comment_summary} → unclear: {why}
  ...
```

For **unclear** threads, use AskUserQuestion to get guidance — present the full comment chain and ask what to do.

## Phase 4: User Override & Confirm Execution

After presenting the plan, ask the user to review the classifications. They may want to reclassify items (e.g., flip a `decline` to `accept` or vice versa):

```
question: "Review the plan above. Want to change any classifications before I proceed?"
header: "Plan Review"
options:
  - label: "Looks good"
    description: "Proceed as planned"
  - label: "I have changes"
    description: "Let me adjust some items"
```

If the user wants changes, accept reclassifications and update the plan. Then ask for execution mode:

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

Follow the worktree pattern in `.claude/docs/worktree-pattern.md`. Suffix: `address-comments`. Ref: `origin/{pr_branch}`. After creation, checkout the PR branch:

```bash
git -C {worktree_path} checkout -B {pr_branch} origin/{pr_branch}
```

## Phase 6: Execute Changes

### For accept threads:

Read the file at the referenced path and line range. Apply the planned change — keep the diff minimal and focused on what the reviewer asked. Follow the repo's coding standards from KB / `CLAUDE.md`.

### For decline threads:

Draft a direct, constructive reply that explains why the current approach is intentional. Structure: state the reason clearly, provide technical context if needed. No hedging or apologies — but acknowledge the reviewer's perspective where it adds value.

Example tone: "The current approach handles X because [reason]. Changing to Y would [specific downside]." — not "Great suggestion, but..."

### For reply-only threads:

Draft the reply text. Replies should be concise and explain the reasoning clearly. Do not be defensive — acknowledge good points, explain technical decisions.

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

After push succeeds, handle each thread using the same two-step pattern: **reply first, then resolve**.

For each thread, compose the reply body based on its category:
- **accept**: `"Fixed — {brief description of what was changed}."`
- **decline**: the explanation drafted in Phase 6
- **reply-only**: the reply drafted in Phase 6

Then execute both API calls in sequence:

```bash
# Step 1: Reply
# Note: `in_reply_to` must be an integer comment ID for review comments. Verify the comment ID from the thread data before using it.
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  -f body="{reply_body}" \
  -f in_reply_to={comment_id} \
  --method POST

# Step 2: Resolve the thread
gh api graphql -f query='
mutation {
  resolveReviewThread(input: { threadId: "{thread_graphql_id}" }) {
    thread { isResolved }
  }
}'
```

Process all threads — accept, decline, and reply-only — using this same pattern.

## Phase 10: Cleanup & Report

Remove the worktree:
```bash
git -C {repo_path} worktree remove {worktree_path} --force
```

Print summary:

```
PR comments addressed ✓

  PR:              {pr_url}
  Accepted:        {N} threads (code changed)
  Declined:        {N} threads (replied with reasoning)
  Replies:         {N} threads
  Resolved:        {total_resolved} / {total_threads}
  Build/test:      passed (iteration {N})

  Commit: {short_sha} — {commit_subject}
```

Append to `work/logs/{YYYY-MM-DD}.md`:
```
- Address comments: {repo_name}#{pr_number} — {N} resolved ({M} accepted, {K} declined, {J} replies)
```

---

## Error Handling

- **Never force-push** — this skill pushes normal commits on top of the existing PR branch.
- **Never modify tests** to make them pass — fix the production code.
- **Reply before resolve** — always post the reply so the reviewer sees the response, then resolve the thread.
- **Partial failure** — if some threads fail to resolve via API, report which ones failed and their thread IDs so the user can resolve manually.
- **No AI attribution** — no "Co-Authored-By: Claude" or "Generated with Claude Code" in commits or replies.
- **Respect reviewer intent** — when in doubt about what a reviewer means, ask the user rather than guessing. A wrong "fix" is worse than asking a question.
