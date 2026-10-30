---
name: nase:prep-merge
description: "Prepare a PR for merge: threads, history, verification, metadata. Use with a PR URL only for explicit prep merge, ready-to-merge, or squash and push."
argument-hint: "<pr-url-or-number>"
category: Git workflow
model: sonnet
effort: high
---

Prepare one PR without merging it. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/pr-input-guard.md`, `.claude/docs/repo-task-flow.md`, `.claude/docs/external-mutation-policy.md`, and `.claude/docs/effort-transitions.md → Prep-Merge Update`.

## Gates

1. Parse the PR and repository, verify `gh` identity/access, load the repo KB/CLAUDE.md, and fetch current PR/base/head state.
2. Stop on a closed/merged PR, missing head, inaccessible repo, dirty target worktree, or unexpected branch ownership.
3. Fetch all three feedback surfaces and current-head CI in one call; the helper already centralizes that field set, so do not hand-roll the `gh` queries:

```bash
python3 .claude/scripts/pr-github-helper.py prep-state "$PR_URL" --local-repo "{repo-path}"
```

   It returns unresolved review threads, review submission bodies (`reviewSubmissions`), and issue comments (`issueComments`). A thread-only read returns an honest zero while a bot verdict sits on another surface. Auto-resolve a bot-declined thread only when it is **explicitly obsolete**, meaning that bot's newest comment on any of the three surfaces withdraws the finding or names the commit that fixed it; a thread that is merely old is not obsolete. Try jev first for each candidate via `.claude/scripts/jev-judge.py` (`--point prep-merge.thread-obsolete --type Noul --instructions "Does this bot comment explicitly withdraw the declined finding, or name the commit that fixed it?" --criteria '{"true": "withdraws the finding or names the fixing commit", "false": "merely old, unanswered, or restates the original finding"}'`, state = one line holding the bot's newest comment excerpt and the commit it names, if any); `usable: true` with answer ≥ 0.5 only nominates a thread, and any fallback means decide it yourself. Show the exact set and take immediate approval before resolving any of them. A severity bot (any login in `BOT_LOGINS` or `NASE_BOT_LOGINS`) re-fires declined findings after a push; surface a repeated finding and stop instead of silently resolving it again. Neither non-thread surface has a resolved flag, so read a bot's newest comment as its current verdict. Any remaining actionable item on any of the three surfaces blocks history rewriting.
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

9. Show the exact commit, target branch, force-push ref, PR title, and body. Then gate with one `AskUserQuestion` immediately before any history rewrite, push, or GitHub edit (per `external-mutation-policy.md` → the gate must be the last step before the side-effect, not a generic earlier "should we proceed?"):

```
question: "Ready to squash, force-push, and update PR metadata for {repo}#{number}?"
header: "Confirm push"
options:
  - label: "Squash and push" (Recommended), description: "Runs Gate 10-11 with the exact commit/body shown above"
  - label: "Squash only, no push", description: "Rewrite local history but stop before force-push; push later"
  - label: "Cancel", description: "Leave the PR and worktree untouched"
```

Only "Squash and push" proceeds to Gate 10; "Squash only" runs Gate 10's local rewrite and stops; "Cancel" stops here. Any mismatch after approval invalidates the payload and requires a new preview.
10. Route every GitHub mutation through `.claude/scripts/external-write-action.py`. Use `--force-with-lease` only, bind the expected remote head, then prove the pushed commit is the PR head.
11. Update PR metadata only after the push is verified. Re-read title/body/head/checks and follow `.claude/docs/pr-gates-consumption.md`.
12. Update the linked effort through its guarded lifecycle transition, clean the worktree with the verified remote ref, delete `workspace/tmp/prep-merge/pr-{number}-body.md`, and report blockers or merge readiness. Append the daily-log entry per `.claude/docs/daily-log-format.md`, whose self-logging rule makes that bullet the durable completion record:

```
- {HH:MM} | prep-merge: {repo}#{number} squashed and pushed, {ready|blocked: reason}
```

   Offer mark-ready and review-request actions only as separate, explicit, payload-bound approvals - with one exception: when `python3 .claude/scripts/autonomy-policy.py --class pr-mark-ready` reports `decision: auto`, that level pre-authorizes the mark-ready action, so show the manifest, execute it, and append the audit entry with `python3 .claude/scripts/daily-log-append.py autonomy "pr-mark-ready {repo}#{number} {manifest}"`. Review-request stays a separate class and its own gate. Do not merge.

Any mismatch after approval invalidates the payload and requires a new preview. Never bypass hooks, reuse stale tokens, or force-push an unverified commit.
