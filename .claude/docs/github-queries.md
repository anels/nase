# GitHub Queries — Shared Reference

Shared query definitions referenced by nase skills.

Prefer `.claude/scripts/pr-github-helper.py` for standard PR parsing, metadata
field sets, review-thread retrieval, and diff-size gates. Keep raw query shapes
here so humans can audit or update the helper without hunting through every
skill.

```bash
python3 .claude/scripts/pr-github-helper.py commands "https://github.com/owner/repo/pull/123" --variant light
```

---

## PR Metadata

Standard field sets for `gh pr view`. Skills reference these instead of inlining their own field lists.

### Full variant (fsd, prep-merge)

Use when you need commit history, review state, and branch info — typically for skills that modify the PR or create new ones.

```bash
gh pr view {pr_number} --repo {owner}/{repo} \
  --json number,title,url,body,headRefOid,headRefName,baseRefName,commits,additions,deletions,changedFiles,files,state,reviewDecision,isDraft
```

### Light variant (discuss-pr, request-review)

Use for read-only analysis — reviewing, ownership lookup, or discussion.

```bash
gh pr view {pr_number} --repo {owner}/{repo} \
  --json number,title,url,body,state,isDraft,headRefOid,additions,deletions,changedFiles,files,baseRefName
```

---

## Unresolved Review Threads

Two variants exist depending on how much detail is needed.

### Full variant (address-comments)

Use when you need to act on each thread: read file context, reply, resolve. Captures all fields needed to locate the code, understand the comment chain, and call the resolve mutation.

```bash
python3 .claude/scripts/pr-github-helper.py review-threads "$PR_URL" > "$TMPDIR/pr-review-threads.json"
```

The helper paginates `reviewThreads(first: 100, after: ...)` and each thread's
`comments(first: 100, after: ...)`, so workflows do not silently miss later
review threads or the true last comment in a long thread.

Filter to threads where `isResolved == false`. Also capture `headRefName` (the PR branch) and `headRepository` (same-repo guard for mutation workflows).

### Minimal variant (prep-merge)

Use when you only need to check whether unresolved threads exist and list them for the user. No mutation follows.

```bash
python3 .claude/scripts/pr-github-helper.py review-threads "$PR_URL" --unresolved-only > "$TMPDIR/pr-review-threads.json"
```

Filter threads where `isResolved == false`.

---

## Resolve Review Threads

Two mutation shapes share one throttle rule. Pick the shape by call pattern; both go through the same `resolveReviewThread` GraphQL mutation. Both are GitHub writes: create a payload file, prepare the exact action manifest, show it with the thread IDs, obtain the immediate `AskUserQuestion` approval, then authorize and execute. Do not run raw `gh api graphql` mutations.

### Shape A — Single-thread (address-comments Phase 9)

Use when each `resolveReviewThread` follows a per-thread reply, so calls must be sequenced one at a time per thread.

```bash
QUERY_FILE=$(mktemp "${TMPDIR:-/tmp}/resolve-review-thread.XXXXXXXX.json")
chmod 600 "$QUERY_FILE"
jq -n --arg thread "{thread_graphql_id}" '{query:"mutation($thread:ID!) { resolveReviewThread(input:{threadId:$thread}) { thread { isResolved } } }", variables:{thread:$thread}}' > "$QUERY_FILE"
MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
  --system github --summary "resolve review thread {thread_graphql_id}" -- \
  gh api graphql --input "$QUERY_FILE" | jq -r .manifest)
jq . "$MANIFEST"
# AskUserQuestion approved this exact manifest. Then:
python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
```

Notes:
- `threadId` is the GraphQL opaque string `id` from `reviewThreads.nodes[].id` — **not** the integer `databaseId`.
- For `decline` threads: reply only, **do NOT resolve** — the reviewer may want to respond.

### Shape B — Batched aliased (prep-merge Phase 2a)

Use when you have N threads to resolve with no per-thread reply (e.g. auto-resolving bot-declined threads). One round-trip resolves all of them via GraphQL aliases.

```bash
BATCH_FILE=$(mktemp "${TMPDIR:-/tmp}/resolve-review-batch.XXXXXXXX.json")
chmod 600 "$BATCH_FILE"
# Build the aliases and IDs from the reviewed batch, then write one JSON request.
printf '%s\n' '{"query":"mutation { r0: resolveReviewThread(input:{threadId:\"<id0>\"}){thread{id}} ... }"}' > "$BATCH_FILE"
MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
  --system github --summary "resolve reviewed bot-declined threads" -- \
  gh api graphql --input "$BATCH_FILE" | jq -r .manifest)
jq . "$MANIFEST"
# AskUserQuestion approved this exact manifest. Then:
python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
```

### Shared throttle rule (applies to both shapes)

GitHub's abuse detector treats high-rate review-thread mutations as suspicious. Throttle whenever the total number of mutations in this run exceeds 30:

1. **Chunk by 30** — split the call list into batches of ≤30. Shape B can batch all 30 into one round-trip via aliases; Shape A must still call sequentially.
2. **Sleep 4 seconds between calls (Shape A) or between batches (Shape B).**
3. **On HTTP 422** with body `{"resource":"PullRequestReview","code":"abuse"}`: pause 60 seconds, retry the same call once, then treat as a hard failure.

Reference incident (do not re-anchor in skills): sanitized pattern with 50+ review-thread mutations where GitHub returned HTTP 422 around call 30 — this is what motivated the 30-call threshold.

For Shape B specifically: if the alias batch itself contains > 30 sub-mutations, chunk the batch — GitHub treats each aliased sub-mutation as a separate call against the abuse counter.
