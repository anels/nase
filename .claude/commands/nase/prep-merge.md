---
name: nase:prep-merge
description: "Prepare a PR for merge by checking threads, history, verification, and metadata. Use with a PR URL only for explicit prep merge, squash and push, clean up, ready-to-merge, or finalize intent."
argument-hint: "<pr-url-or-number>"
category: Git workflow
---

Prepare one PR without merging it. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/pr-input-guard.md`, `.claude/docs/repo-task-flow.md`, `.claude/docs/external-mutation-policy.md`, and `.claude/docs/effort-transitions.md → Prep-Merge Update`.

## Gates

1. Parse the PR and repository, verify `gh` identity/access, load the repo KB/CLAUDE.md, and fetch current PR/base/head state.
2. Stop on a closed/merged PR, missing head, inaccessible repo, dirty target worktree, or unexpected branch ownership.
3. Fetch all three feedback surfaces and current-head CI in one call; the helper already centralizes that field set, so do not hand-roll the `gh` queries:

```bash
python3 .claude/scripts/pr-github-helper.py prep-state "$PR_URL" --local-repo "{repo-path}"
```

   It returns unresolved review threads, review submission bodies (`reviewSubmissions`), and issue comments (`issueComments`). A thread-only read returns an honest zero while a bot verdict sits on another surface. Auto-resolve a bot-declined thread only when it is **explicitly obsolete**, meaning that bot's newest comment on any of the three surfaces withdraws the finding or names the commit that fixed it; a thread that is merely old is not obsolete. Show the exact set and take immediate approval before resolving any of them. A severity bot (any login in `BOT_LOGINS` or `NASE_BOT_LOGINS`) re-fires declined findings after a push; surface a repeated finding and stop instead of silently resolving it again. Neither non-thread surface has a resolved flag, so read a bot's newest comment as its current verdict. Any remaining actionable item on any of the three surfaces blocks history rewriting.
4. Run the repo's required verification before rebase/squash. Apply `.claude/docs/build-test-loop.md` and `.claude/docs/anti-rationalization.md`; environment-only gaps remain explicit.
5. Create an isolated worktree through `.claude/docs/worktree-pattern.md` and call its absolute path `{work_root}`. Rebase on the fetched base and re-run focused verification when conflict resolution changes code.
6. Inspect `origin/{base}..HEAD`. If multiple commits remain, squash from the verified merge base and derive the message with `/nase:improve-commit-message --auto-accept --repo {work_root}`, which owns the conventional-commit shape and the repo's commitlint rules; this file does not restate them. Never use a stale base or destructive reset outside the isolated worktree.
7. Rebuild the PR title/body from the actual squashed diff and repo template. Run `surface=github-pr-body` voice routing and read `.claude/docs/ai-attribution.md`; prompt once if missing per-repo attribution config.
8. Keep the private body file protected. A shell variable does not survive to the next Bash call and a `trap ... EXIT` fires at the end of the call that set it, so do not use either. Write the body to a known path under `workspace/tmp/`, name that path in every later gate, and delete it explicitly in Gate 12.

   Write the Gate 7 body into it in the same call that creates it. Substitute the body
   literally; a shell variable holding it would not survive to Gate 9 either.

   ```bash
   umask 077
   PR_BODY_FILE="workspace/tmp/prep-merge/pr-{number}-body.md"
   mkdir -p "$(dirname "$PR_BODY_FILE")"
   printf '%s\n' "{the Gate 7 PR body, verbatim}" > "$PR_BODY_FILE"
   ```

   This path outlives the Bash call that creates it, and it has to. Gate 9 shows its
   contents and waits for the user, Gate 10 binds it into the `external-write-action.py`
   manifest as `--body-file`, and Gate 11 reads it back. Spell the literal path out in each
   of those gates rather than carrying a shell variable across calls. Never re-derive the
   body in a later gate, because different bytes break the hash the approved manifest bound.
   Gate 12 deletes it.

9. Show the exact commit, target branch, force-push ref, PR title, and body. Require explicit confirmation immediately before history rewrite/push and GitHub edits.
10. Route every GitHub mutation through `.claude/scripts/external-write-action.py`. Use `--force-with-lease` only, bind the expected remote head, then prove the pushed commit is the PR head.
11. Update PR metadata only after the push is verified. Re-read title/body/head/checks and follow `.claude/docs/pr-gates-consumption.md`.
12. Update the linked effort through its guarded lifecycle transition, clean the worktree with the verified remote ref, delete `workspace/tmp/prep-merge/pr-{number}-body.md`, and report blockers or merge readiness. Append the daily-log entry per `.claude/docs/daily-log-format.md`, whose self-logging rule makes that bullet the durable completion record:

```
- {HH:MM} | prep-merge: {repo}#{number} squashed and pushed, {ready|blocked: reason}
```

   Offer mark-ready and review-request actions only as separate, explicit, payload-bound approvals. Do not merge.

Any mismatch after approval invalidates the payload and requires a new preview. Never bypass hooks, reuse stale tokens, or force-push an unverified commit.
