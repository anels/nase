---
name: nase:address-comments
description: Address unresolved PR review comments — fetch, analyze, fix code or reply, then push and resolve. Use when given a PR URL and asked to handle, address, fix, or respond to review comments. Also triggers on "address comments", "fix review comments", "handle PR feedback", "resolve comments", or when the user pastes a PR URL and mentions comments, feedback, or review.
---

**Input:** $ARGUMENTS — a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`)

---

## Phase 0: Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md`.

## Phase 1: Locate Repo & Fetch Context

Follow `.claude/docs/repo-resolution.md`:
- **Part 1** (Repo Resolution): resolve the repo from the PR URL's `owner/repo` — extract the repo name and look it up in `.local-paths`. If not found, ask the user for the local path and append it to `.local-paths`.
- **Part 2** (KB File Loading): derive the domain key from the repo name, find the KB file in `workspace/kb/.domain-map.md`, and read it — focusing on **Build & Run Commands** and **Architecture** sections.

## Phase 2: Fetch Latest & Unresolved Review Threads

First, pull the latest from remote so local file contents match the PR head when reading referenced lines:

```bash
git -C {repo_path} fetch origin
```

Then use the **full variant** GraphQL query from `.claude/docs/github-queries.md` (Unresolved Review Threads section) to get all unresolved review threads in one call.

Filter to only threads where `isResolved == false`. Also capture `headRefName` (the PR branch).

If there are zero unresolved threads: report "No unresolved comments found" and stop.

## Phase 3: Critically Evaluate & Present Plan

**Step 3a — Load context before evaluating:**

For each unresolved thread, read the full comment chain AND the surrounding code (not just the referenced line — enough to understand the design intent). Cross-reference the KB (loaded in Phase 1) for architectural constraints that could invalidate a suggestion. If the KB references a Confluence doc or past decision relevant to the changed area, read it before classifying.

**Step 3b — Resolve unclear threads first:**

Before classifying all threads, identify any where intent is ambiguous or the right action requires design discussion. For each one, use AskUserQuestion to present the full comment chain and ask what to do. Collect all answers before proceeding — this way the final plan is complete in one pass.

**Step 3c — Evaluate and classify remaining threads:**

Ask these questions for each suggestion:

1. **Correctness**: Does the reviewer's suggestion fix an actual bug or prevent a real failure mode? Or is the current code already correct?
2. **Context**: Does the reviewer have full context? Sometimes a suggestion makes sense locally but conflicts with constraints elsewhere (e.g., API contracts, performance requirements, framework limitations).
3. **Substance vs. style**: Is this a meaningful improvement to correctness, readability, or maintainability? Or is it a cosmetic/stylistic preference that doesn't materially improve the code?
4. **Risk**: Could accepting this change introduce a regression, break an invariant, or conflict with the broader design?

**Classify each thread:**

| Category | When to use | Action |
|----------|-------------|--------|
| **accept** | Suggestion fixes a real issue, improves correctness, or meaningfully improves clarity/maintainability | Modify the code |
| **decline** | Current code is correct and the suggestion is stylistic, based on incomplete context, or would introduce risk | Reply explaining why the current approach is intentional |
| **reply-only** | Question, discussion point, or acknowledgment needed — no code involved | Write a reply |

The bar for `accept` is: "this change makes the code measurably better." If a suggestion is reasonable but the current code is equally valid, that's a `decline`. When declining, reference the KB or a specific architectural constraint if one applies — it makes the reasoning concrete for the reviewer.

**Step 3d — Present the complete plan:**

```
Found {N} unresolved review threads:

  1. ✅ [{path}:{line}] {first_comment_summary} → accept: {what_you_plan_to_do}
  2. ↩️ [{path}:{line}] {first_comment_summary} → decline: {why current code is correct/better}
  3. 💬 [{path}:{line}] {first_comment_summary} → reply-only: {draft_reply_summary}
  ...
```

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

If the accepted change alters a logic branch or adds a new code path, check whether an existing test covers it. If not, add or update a test — the reviewer's fix should be verified, not just applied.

### For decline threads:

Draft a direct, constructive reply that explains why the current approach is intentional. Structure: state the reason clearly, provide technical context if needed. No hedging or apologies — but acknowledge the reviewer's perspective where it adds value.

Example tone: "The current approach handles X because [reason]. Changing to Y would [specific downside]." — not "Great suggestion, but..."

### For reply-only threads:

Draft the reply text. Replies should be concise and explain the reasoning clearly. Do not be defensive — acknowledge good points, explain technical decisions.

Hold all replies until Phase 9 (post-push) so the reviewer sees both the code fix and the reply together.

## Phase 7: Build & Test (max 5 iterations)

Get build and test commands from the KB file or repo's `CLAUDE.md`.
Follow the build & test iteration loop in `.claude/docs/build-test-loop.md` (max 5 iterations).
On success: proceed to Phase 8.

## Phase 8: Commit & Push

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md`.
Deviation: in "Confirm before push" mode, show the staged diff (`git diff --cached --stat` + key hunks) and the commit message before pushing, then ask:

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

Append to `workspace/logs/{YYYY-MM-DD}.md`:
```
- Address comments: {repo_name}#{pr_number} — {N} resolved ({M} accepted, {K} declined, {J} replies)
```

---

## Error Handling

- **Never force-push** — this skill pushes normal commits on top of the existing PR branch.
- **Never modify tests** to make them pass — fix the production code.
- **Reply before resolve** — always post the reply so the reviewer sees the response, then resolve the thread.
- **Partial failure** — if some threads fail to resolve via API, report which ones failed and their thread IDs so the user can resolve manually.
- **Respect reviewer intent** — when in doubt about what a reviewer means, ask the user rather than guessing. A wrong "fix" is worse than asking a question.
