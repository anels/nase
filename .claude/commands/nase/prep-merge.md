---
name: nase:prep-merge
description: "Prepare a PR for merge by checking threads, history, verification, and metadata. Use with a PR URL only for explicit prep merge, squash and push, clean up, ready-to-merge, or finalize intent."
argument-hint: "<pr-url-or-number>"
pattern: pipeline
category: Git workflow
---

Prepare one PR without merging it. Run `.claude/docs/language-config.md` first. Follow `.claude/docs/pr-input-guard.md`, `.claude/docs/repo-task-flow.md`, `.claude/docs/external-mutation-policy.md`, and `.claude/docs/effort-lifecycle.md`.

## Gates

1. Parse the PR and repository, verify `gh` identity/access, load the repo KB/CLAUDE.md, and fetch current PR/base/head state.
2. Stop on a closed/merged PR, missing head, inaccessible repo, dirty target worktree, or unexpected branch ownership.
3. Fetch unresolved review threads and current-head CI. Auto-resolve only explicitly obsolete bot-declined threads after showing the exact set and receiving immediate approval. The `uipathepixa` severity bot re-fires declined findings after a push; surface a repeated finding and stop instead of silently resolving it again. Any remaining actionable thread blocks history rewriting.
4. Run the repo's required verification before rebase/squash. Apply `.claude/docs/build-test-loop.md` and `.claude/docs/anti-rationalization.md`; environment-only gaps remain explicit.
5. Create an isolated worktree through `.claude/docs/worktree-pattern.md`. Rebase on the fetched base and re-run focused verification when conflict resolution changes code.
6. Inspect `origin/{base}..HEAD`. If multiple commits remain, derive one truthful conventional message and squash from the verified merge base. Never use a stale base or destructive reset outside the isolated worktree.
7. Rebuild the PR title/body from the actual squashed diff and repo template. Run `surface=github-pr-body` voice routing and read `.claude/docs/ai-attribution.md`; prompt once if missing per-repo attribution config.
8. Keep the private body file protected:

```bash
PR_BODY_FILE=$(mktemp)
trap 'rm -f "$PR_BODY_FILE"' EXIT
```

9. Show the exact commit, target branch, force-push ref, PR title, and body. Require explicit confirmation immediately before history rewrite/push and GitHub edits.
10. Route every GitHub mutation through `.claude/scripts/external-write-action.py`. Use `--force-with-lease` only, bind the expected remote head, then prove the pushed commit is the PR head.
11. Update PR metadata only after the push is verified. Re-read title/body/head/checks and follow `.claude/docs/pr-gates-consumption.md`.
12. Update the linked effort through its guarded lifecycle transition, clean the worktree with the verified remote ref, and report blockers or merge readiness. Offer mark-ready and review-request actions only as separate, explicit, payload-bound approvals. Do not merge.

Any mismatch after approval invalidates the payload and requires a new preview. Never bypass hooks, reuse stale tokens, or force-push an unverified commit.
