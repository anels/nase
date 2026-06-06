---
name: nase:prep-merge
description: Prepare a PR for merge — verify all comments resolved, squash commits, force-push, and update PR title/description. Use when given a PR URL and asked to prepare, clean up, squash, finalize, or get a PR merge-ready. Also triggers on "prep merge", "squash and push", "clean up PR", "ready to merge", "finalize PR", or any request to tidy a PR's commit history before merging.
---

**Input:** $ARGUMENTS — a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`)

Follows `.claude/docs/external-mutation-policy.md` — review-thread resolution, force-push, `gh pr edit`, and `gh pr ready` go through `AskUserQuestion` before the call.

---

## Phase 0: Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Use `conversation:` for chat, reports, and AskUserQuestion prompts; use `output:` for PR title/body updates.

## Phase 0.5: Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md`.

## Phase 1: Fetch PR Metadata

Parse the PR reference and fetch metadata with the shared helper:

```bash
python3 .claude/scripts/pr-github-helper.py parse "$PR_URL_OR_ARGUMENTS"
python3 .claude/scripts/pr-github-helper.py metadata "$PR_URL" --variant full > "$TMPDIR/pr-metadata.json"
```

The helper's **full** variant centralizes the field set from `.claude/docs/github-queries.md`.

Capture: `headRefOid` (PR head SHA), `headRefName` (PR branch), `baseRefName` (target branch), commit list, changed files, current title/body, state, review decision.

If `state` is not `OPEN`: report "PR is already {state}" and stop.

## Phase 2: Verify All Comments Resolved

Use the shared helper for the full review-thread GraphQL query:

```bash
python3 .claude/scripts/pr-github-helper.py review-threads "$PR_URL" > "$TMPDIR/pr-review-threads.json"
```

The helper preserves `author.login` on the first AND last comment for the bot-decline check in 2a.

Filter threads where `isResolved == false`.

### 2a. Auto-resolve bot-declined threads

Auto-resolve a thread when ALL of: ≥2 comments, first author is a bot, last author is non-bot (the decline reply from a prior `/nase:address-comments` run — already HEAD-verified per `.claude/docs/pr-review-verification.md`). Bots don't re-engage; full thread history + daily log preserve the audit trail.

Bot author logins: `copilot-pull-request-reviewer[bot]`, `copilot-pull-request-reviewer`, `github-actions[bot]`, `codex-bot`, `claude`, `claude[bot]` (extend as new bots appear).

Before resolving, list the matched thread IDs, bot author, last commenter, and one-line summary, then use `AskUserQuestion` as the immediate GitHub mutation gate:

```
question: "Auto-resolve these bot-declined review threads?"
header: "Bot Threads"
options:
  - label: "Resolve bot threads"
    description: "Resolve only the listed bot-authored threads whose latest reply is a human decline"
  - label: "Skip auto-resolve"
    description: "Leave them unresolved; Phase 2b will block prep-merge"
```

If the user chooses "Skip auto-resolve", do not run the GraphQL mutation; continue to Phase 2b with those threads still unresolved.

Resolve all matches in **one batched GraphQL mutation** using aliases — see Shape B (batched aliased) in `.claude/docs/github-queries.md → Resolve Review Threads`.

Apply the shared throttle rule from the same doc (chunk by 30, `sleep 4` between batches, 60s retry on 422).

Daily-log one line per resolved thread (tag: `prep-merge`): `{repo}#{pr} — auto-resolved bot decline thread {id} ({bot_author})`.

### 2b. Block on remaining unresolved threads

After 2a, re-filter `isResolved == false`. If any remain (i.e. human-authored or non-declined bot threads):

```
Cannot prep merge — {N} unresolved review thread(s):

  1. [{path}:{line}] @{author}: {comment_summary}
  2. ...

Resolve these first (or use /nase:address-comments {pr_url}).
```

**If all resolved (including post-2a):** proceed.

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

## Phase 4.6: Prior-Abort Signature Check

Refuse a re-run when nothing has changed since a prior aborted prep-merge — `git rebase` will deterministically replay the same conflict (sanitized pattern: two attempts ~50min apart hit the identical conflict file against the same base commit).

State file path: `workspace/tmp/prep-merge-{owner}-{repo}-{pr_number}-abort.json`. Phase 5.5 writes it on conflict abort; Phase 8 deletes it on push success.

```bash
STATE_FILE="workspace/tmp/prep-merge-{owner}-{repo}-{pr_number}-abort.json"
if [ -f "$STATE_FILE" ]; then
  PRIOR_BRANCH_SHA=$(jq -r .branch_sha "$STATE_FILE")
  PRIOR_BASE_SHA=$(jq -r .base_sha "$STATE_FILE")
  CUR_BRANCH_SHA=$(git -C {repo_path} rev-parse origin/{pr_branch})
  CUR_BASE_SHA=$(git -C {repo_path} rev-parse origin/{base_branch})
  if [ "$PRIOR_BRANCH_SHA" = "$CUR_BRANCH_SHA" ] && [ "$PRIOR_BASE_SHA" = "$CUR_BASE_SHA" ]; then
    PRIOR_TS=$(jq -r .timestamp "$STATE_FILE")
    PRIOR_FILES=$(jq -r '.conflict_files | join(", ")' "$STATE_FILE")
    echo "Refusing retry — same branch + base SHAs as aborted prep-merge at $PRIOR_TS."
    echo "Same conflict will recur on: $PRIOR_FILES"
    echo "Resolve in your main checkout first, or delete $STATE_FILE to force retry."
    exit 1
  fi
fi
```

If state file is absent, missing fields, or SHAs differ: continue to Phase 4.7.

## Phase 4.7: Adjacent Same-File PR Scan

Reason: long-lived PRs (open >24h) often share high-traffic security/hardening files with sibling PRs that landed during the same sprint. Detecting overlap before Phase 5.5 avoids a predictable rebase abort and lets the user choose whether to resolve locally first.

Enumerate files in this PR's diff against the base branch, then check whether any of them were touched on the base branch since the PR opened:

```bash
# Files in this PR
PR_FILES=$(git -C {repo_path} diff origin/{base_branch}..origin/{pr_branch} --name-only)

# Commits on base branch since PR opened that touched any of those files
PR_OPENED_AT=$(jq -r .createdAt "$TMPDIR/pr-metadata.json" 2>/dev/null || echo "")
overlap_found=0
scan_ran=0
if [ -n "$PR_OPENED_AT" ] && [ "$PR_OPENED_AT" != "null" ]; then
  scan_ran=1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    overlap=$(git -C {repo_path} log origin/{base_branch} --since="$PR_OPENED_AT" --oneline -- "$f")
    if [ -n "$overlap" ]; then
      if [ "$overlap_found" -eq 0 ]; then
        echo "Base-branch commits since PR opened that touched PR files:"
      fi
      overlap_found=1
      echo "── $f"
      printf '%s\n' "$overlap" | sed 's/^/    /'
    fi
  done <<EOF
$PR_FILES
EOF
else
  echo "PR opened time unavailable; skip adjacent same-file scan."
fi
if [ "$scan_ran" -eq 1 ] && [ "$overlap_found" -eq 0 ]; then
  echo "No base-branch commits touched PR files since the PR opened."
fi
```

If the output says `No base-branch commits touched PR files since the PR opened.`: proceed to Phase 5.

If the output says `PR opened time unavailable; skip adjacent same-file scan.`: proceed to Phase 5 and note that this optional preflight could not run.

If the output lists one or more `── {file}` sections, present the list of (file, base-branch commits, linked PRs if discoverable via commit-message PR refs) and ask via `AskUserQuestion`:

```
question: "Base branch advanced on {N} file(s) in this PR since it opened. Proceeding into rebase risks a conflict abort mid-flow."
header: "Adjacent PR Scan"
options:
  - label: "Resolve locally first"
    description: "Stop now; rebase + resolve in main checkout, then re-run prep-merge"
  - label: "Continue rebase"
    description: "Proceed into Phase 5.5; accept abort risk"
  - label: "Abort"
    description: "Stop without proceeding"
```

Default reflex: recommend "Resolve locally first" — mid-flow rebase abort costs more context switching than an upfront local resolve. If the user picks "Continue rebase", continue to Phase 5; the Phase 5.5 conflict-handling path is unchanged. If "Abort", clean up and stop.

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

If the rebase fails due to conflicts, stop immediately — do not proceed with squash or force-push. Capture the conflict file list (`git -C {worktree_path} diff --name-only --diff-filter=U`), run `git -C {worktree_path} rebase --abort` to restore the branch to its pre-rebase state, then write the abort state file for Phase 4.6 of the next run:

```bash
mkdir -p workspace/tmp
cat > "workspace/tmp/prep-merge-{owner}-{repo}-{pr_number}-abort.json" <<EOF
{
  "branch_sha": "$(git -C {repo_path} rev-parse origin/{pr_branch})",
  "base_sha":   "$(git -C {repo_path} rev-parse origin/{base_branch})",
  "conflict_files": [$(echo "$CONFLICT_FILES" | awk 'NF{printf "\"%s\",", $0}' | sed 's/,$//')],
  "timestamp": "$(date -u +%FT%TZ)"
}
EOF
```

Then report the conflicting files to the user and suggest resolving them locally before re-running prep-merge. Alternatively, the user can delete the worktree (`git -C {repo_path} worktree remove {worktree_path} --force`) and start fresh.

After a successful rebase, check if any files were auto-merged: `git -C {worktree_path} diff origin/{pr_branch}..HEAD`. If non-empty (code changed during rebase), run the build & test loop (`.claude/docs/build-test-loop.md`) before proceeding to ensure the rebased code still works.

**Base-advance log:** show how the branch moved relative to base so Phase 7 PR body refresh accounts for upstream commits that landed since the branch diverged (sanitized pattern: base advanced shortly after a prior prep-merge; PR body referenced a state that no longer matched HEAD-after-rebase).

```bash
echo "Commits on branch ahead of {base_branch}:"
git -C {worktree_path} log origin/{base_branch}..HEAD --oneline
echo
echo "Commits on {base_branch} since branch diverged (top 20):"
git -C {worktree_path} log HEAD..origin/{base_branch} --oneline | head -20
```

If the second list is non-empty, note in Phase 7 that the PR body must reflect the post-rebase scope (not the pre-rebase scope).

## Phase 6: Squash Commits

Count commits on the PR branch that are ahead of the target branch:

```bash
git -C {worktree_path} rev-list --count origin/{base_branch}..HEAD
```

If only 1 commit: skip squash — the history is already clean. Jump to Phase 7.

**Compatibility-fallback guard:** Before squashing, scan commit messages for load-bearing keywords — squashing can silently drop these and trigger runtime failures (sanitized pattern: runtime fallback dropped, causing multiple tickets):

```bash
MERGE_BASE_SCAN=$(git -C {worktree_path} merge-base origin/{base_branch} HEAD)
git -C {worktree_path} log --format="%h %s%n%b" $MERGE_BASE_SCAN..HEAD \
  | grep -iE "fix.?runtime|compat|fallback|\bpin[._-]?to[._-]?n-?1\b|revert.?tfm"
```

If any commits match, list them and use `AskUserQuestion` to require explicit confirmation before proceeding:

```
question: "{N} commit(s) contain compatibility/fallback keywords — squashing may silently drop load-bearing changes. Review listed commits, then proceed or abort."
header: "Squash Guard"
options:
  - label: "I've reviewed — squash"
    description: "These are safe to squash (diff is re-applied in squash body)"
  - label: "Abort"
    description: "Stop — I need to inspect before squashing"
```

If "Abort": clean up worktree and stop.

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
question: "Ready to squash and force-push this PR branch?"
header: "Confirm Prep Merge"
options:
  - label: "Go"
    description: "Squash → force-push; PR title/body update is confirmed separately before gh pr edit"
  - label: "Edit"
    description: "Let me adjust the title or description first"
  - label: "Abort"
    description: "Cancel — don't touch anything"
```

**If "Go":** proceed immediately to Phase 8 — do not pause or emit any intermediate message.
**If "Edit":** ask the user what to change, apply edits, then ask again.
**If "Abort":** clean up worktree and stop.

Before the force-push and any `gh` mutation that follows, run the GitHub auth account guard snippet from `.claude/docs/external-mutation-policy.md → GitHub auth account guard`.

## Phase 8: Commit & Force Push

Create the squash commit (skip this step for single-commit PRs — Phase 6 was skipped and the commit already exists):

```bash
git -C {worktree_path} commit -m "{squash_commit_message}"
```

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md` (which handles `/nase:improve-commit-message` automatically).
Deviation: use `--force-with-lease` instead of normal push. If force-push fails, report the error and stop — someone pushed new commits and the user needs to reconcile.

On push success, clear the Phase 4.6 abort signature:
```bash
rm -f "workspace/tmp/prep-merge-{owner}-{repo}-{pr_number}-abort.json"
```

## Phase 9: Update PR on GitHub

Show the final title and body again, then use `AskUserQuestion` immediately before the GitHub mutation:

```
question: "Update the PR title and description with this final payload?"
header: "PR Update"
options:
  - label: "Update PR"
    description: "Run gh pr edit with the title/body shown above"
  - label: "Skip PR edit"
    description: "Leave the pushed branch as-is; update the PR manually later"
```

If the user chooses "Skip PR edit", skip the command below and continue to cleanup/report with `Title updated: skipped`.

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
question: "Mark this PR ready and request review now? {pr_url}"
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
- **Preserve co-authors** — when squashing, add `Co-Authored-By` trailers for all non-AI authors so their contribution is preserved in git history. For the Claude/AI co-author trailer, follow `.claude/docs/ai-attribution.md` (per-repo `{RepoName}-ai-attribution=on|off` in `.local-paths`; prompt once if missing).
