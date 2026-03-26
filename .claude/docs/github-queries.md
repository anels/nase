# GitHub Queries — Shared Reference

Shared query definitions referenced by nase skills.

---

## PR Metadata

Standard field sets for `gh pr view`. Skills reference these instead of inlining their own field lists.

### Full variant (fsd, prep-merge)

Use when you need commit history, review state, and branch info — typically for skills that modify the PR or create new ones.

```bash
gh pr view {pr_number} --repo {owner}/{repo} \
  --json number,title,url,body,headRefName,baseRefName,commits,additions,deletions,changedFiles,files,state,reviewDecision
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

Filter to threads where `isResolved == false`. Also capture `headRefName` (the PR branch).

### Minimal variant (prep-merge)

Use when you only need to check whether unresolved threads exist and list them for the user. No mutation follows.

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
