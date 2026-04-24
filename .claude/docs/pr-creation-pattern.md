# PR Creation Pattern — Shared Reference

Shared sequence for skills that create or update pull requests on GitHub (`fsd`, `prep-merge`).

---

## 1. Discover PR Template

Check for a PR template in the repo (in order of precedence):

```bash
ls {repo_path}/.github/pull_request_template.md 2>/dev/null
ls {repo_path}/.github/PULL_REQUEST_TEMPLATE.md 2>/dev/null
ls {repo_path}/docs/pull_request_template.md 2>/dev/null
ls {repo_path}/.github/PULL_REQUEST_TEMPLATE/*.md 2>/dev/null | head -1
```

If found, read it. Strip HTML comments (`<!-- ... -->`) — these are instructions to the author, not content to preserve.

## 2. Draft PR Description

**If a template was found:** use it as the skeleton. Apply all of the following rules:

- Use the template's exact section headings — do not rename, reorder, or merge them.
- Fill each section with content derived from the full diff, changed files, commit history, and task context.
- Preserve checklist items unchecked — do not pre-check boxes.
- Leave sections empty (with their heading) rather than omitting them if content cannot be determined.
- Do not invent content for sections that cannot be determined from the code changes (e.g., leave Jira ticket placeholders as-is if no ticket is known).
- If updating an existing PR: preserve author-written content and migrate it into the correct sections; only update sections that changed.

**If no template exists:** use this default structure:

```
## Summary
{2-4 bullet points describing what changed and why}

## Changes
{brief list of key files/areas modified}
```

## 3. PR Title = Commit Subject

The PR title must match the commit subject line (the first line of the commit message). This keeps the merge commit clean when the PR is merged with "Squash and merge" or "Rebase and merge" on GitHub.

## 4. Co-Author Preservation

When squashing or creating commits from multi-author work (e.g., team mode with multiple contributors), add `Co-Authored-By` trailers for non-primary authors so their contribution is preserved in git history.

No AI attribution — see CLAUDE.md.
