# PR Creation Pattern — Shared Reference

Shared sequence for skills that create or update pull requests on GitHub (`fsd`, `prep-merge`).

Before drafting any PR title or body, follow `.claude/docs/voice-profile-routing.md` with `surface=github-pr-body`.

This doc covers template discovery, body drafting, title=subject, and co-authors. For the repo's *merge-blocking* constraints on the title, body, and size (ticket-key placement, required sections + minimum lengths, size buckets that mandate `## How to Review`), the caller applies `.claude/docs/pr-gates-consumption.md` §3 with the `gate_profile` it loaded — the two compose: this doc shapes the template, the gate profile makes it clear CI.

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

### 2a. No local-only path references

PR descriptions are read by people who do not have your filesystem. Never reference paths that exist only in the local nase workspace — e.g. `workspace/efforts/*.md`, `workspace/tasks/*`, `workspace/logs/*`, `workspace/kb/*`, `~/...`, `/tmp/...`, or any other path that is not committed to the PR's target repo.

This applies to every section of the PR body (Summary, Changes, Test Plan, Verification, footnotes, etc.) and to both initial creation and later edits.

**Allowed substitutes:**
- Reference the Jira ticket, GitHub issue, or design-doc URL instead of the local effort doc.
- Inline the relevant context (1-3 sentences) directly in the PR body.
- Link to a committed in-repo doc (e.g. `docs/...` that exists on the branch).

**Example — wrong:**
> Implements Phase 2.3 from effort doc: `workspace/efforts/insights-increase-code-coverage.md`.

**Example — right:**
> Implements Phase 2.3 of the coverage initiative ([PROJ-1234](https://your-org.atlassian.net/browse/PROJ-1234)): raise `BuildHandler` unit-test coverage from 42% → 70%.

Before finalizing the PR body, grep it: `grep -nE '(^|[^[:alnum:]_])(workspace/|~/|/tmp/)' /tmp/pr-body.md` — if anything matches, rewrite that line.

## 3. PR Title = Commit Subject

The PR title must match the commit subject line (the first line of the commit message). This keeps the merge commit clean when the PR is merged with "Squash and merge" or "Rebase and merge" on GitHub.

## 4. Co-Author Preservation

When squashing or creating commits from multi-author work (e.g., team mode with multiple contributors), add `Co-Authored-By` trailers for non-primary authors so their contribution is preserved in git history.

**AI attribution** — per-repo config; see `.claude/docs/ai-attribution.md`. Before drafting the PR description, resolve `{RepoName}-ai-attribution` from `.local-paths` (prompt once if missing). If `on`, append the `🤖 Generated with [Claude Code](https://claude.com/claude-code)` footer; if `off`, omit. Inline review comments stay AI-clean regardless.
