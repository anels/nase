# PR Creation Pattern — Shared Reference

## Contents

- [1. Discover PR Template](#1-discover-pr-template)
- [2. Draft PR Description](#2-draft-pr-description)
  - [2a. No local-only path references](#2a-no-local-only-path-references)
  - [2b. No unexplained plan-internal labels](#2b-no-unexplained-plan-internal-labels)
- [3. PR Title = Commit Subject](#3-pr-title--commit-subject)
- [4. Co-Author Preservation](#4-co-author-preservation)

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
> Implements Phase 2.3 from effort doc: `workspace/efforts/platform-increase-code-coverage.md`.

**Example — right:**
> Implements Phase 2.3 of the coverage initiative ([PROJ-1234](https://your-org.atlassian.net/browse/PROJ-1234)): raise `BuildHandler` unit-test coverage from 42% → 70%.

Before finalizing the PR body, grep it: `grep -nE '(^|[^[:alnum:]_])(workspace/|~/|/tmp/)' /tmp/pr-body.md` — if anything matches, rewrite that line.

### 2b. No unexplained plan-internal labels

The same reviewer who lacks your filesystem also lacks your plan. Labels the plan invented — `Phase 0`, `case C`, `Option 2`, `step 4.1`, workstream codes, requirement ids like `REQ-003`, review ids like `P1-2` — identify things precisely for you and denote nothing for the reviewer. A body written in that vocabulary reads as an internal memo: the reviewer cannot tell what is in scope, why these items and not others, or whether an omission is deliberate. Worse, it looks self-consistent, so nobody asks.

Rewrite each label as the thing it names. Where the grouping itself carries information the reviewer needs (a series of PRs, a staged rollout, a deliberate subset), state that information in concrete terms instead of by label — "the first of three PRs; this one only adds tests" beats "Phase 0".

**Example — wrong** (real PR body, before rewrite):
> Adds a test-only Phase 0 generated-query corpus for cases C, D, F, G, and I.
> Existing tests covered A, B, E, and H, while C, D, F, G, and I had only partial or static evidence.
> C uses the real JobsExplore model, validator, `QueryScope`, and `QueryBuilder`.

**Example — right** (same PR, after rewrite):
> Adds a test-only safety net for future SQL query optimizations. This PR does not change production query generation.
> - Exercises real `QueryBuilder` paths for JobsExplore fan-out joins, AO deviation metrics, scalar aggregates, and window-function filters.
> - Filter-only child predicates preserve results when a join plus distinct count is replaced with `EXISTS`.

The letters only indexed the work, so the reviewer had to take completeness on trust. The behaviors state the claim, so each one can be checked against the diff.

§2a's "right" example keeps a phase number, and that is fine — it works because the number is immediately followed by what the phase concretely is, plus a link the reviewer can open. That is the bar: a label may appear only when the same sentence says what it means, or when it resolves through a linked artifact the reviewer can actually reach (Jira ticket, committed in-repo doc, prior PR). A label whose only definition lives in `workspace/` fails both §2a and this rule.

Check before finalizing: reread the body as someone holding only the target repo and the diff. Every identifier you cannot resolve from those two things is a rewrite. Two advisory greps catch the usual offenders — a hit is a question, not a failure, since some labels are legitimately defined in place:

```bash
# keyword + ordinal: "Phase 0", "step 4.1", "cases C, D", "Option 2", "REQ-003"
grep -nEi '(^|[^[:alnum:]_])(phase|step|option|stage|case[s]?|part|milestone|req)[ -]?[0-9A-Z]([^[:alnum:]]|$)' /tmp/pr-body.md
# bare letter labels: "covered A, B, E, and H", "C uses the real model"
grep -nE '(^|[^[:alnum:]_`])[B-HJ-Z]([^[:alnum:]_`]|$)' /tmp/pr-body.md
```

The second grep skips `A` and `I` because they are ordinary English words, so a body that labels its cases `A` or `I` needs the reread, not the grep, to catch them.

This applies to the PR title too. Because the title must equal the commit subject (§3), a label in the title means the *subject* needs rewriting — fix it there via `/nase:improve-commit-message` rather than letting title and subject diverge.

## 3. PR Title = Commit Subject

The PR title must match the commit subject line (the first line of the commit message). This keeps the merge commit clean when the PR is merged with "Squash and merge" or "Rebase and merge" on GitHub.

## 4. Co-Author Preservation

When squashing or creating commits from multi-author work (e.g., team mode with multiple contributors), add `Co-Authored-By` trailers for non-primary authors so their contribution is preserved in git history.

**AI attribution** — per-repo config; see `.claude/docs/ai-attribution.md`. Before drafting the PR description, resolve `{RepoName}-ai-attribution` from `.local-paths` (prompt once if missing). If `on`, append the `🤖 Generated with [Claude Code](https://claude.com/claude-code)` footer; if `off`, omit. Inline review comments stay AI-clean regardless.
