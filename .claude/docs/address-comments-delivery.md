# Address Comments Delivery

## Contents

- Phase 5: Setup Worktree
- Phase 5.5: Resolve Merge Conflicts
- Phase 6: Execute Changes
- Phase 6.5: Fix Failing Required Checks
- Phase 7: Build & Test (max 5 iterations)
- Phase 7.25: Optional Post-Edit CLI Gates
- Phase 7.5: Review-Thread Resolution Gate
- Phase 8: Commit & Push
- Phase 8b: Update PR Description to Match Template
- Phase 9: Reply & Resolve Comments
- Phase 9b: Optional Reviewer Ping (Human Reviewers Only)
- Phase 10: Learn
- Phase 11: Cleanup and Report
- Phase 12: Next-step handoff
- Error handling

Read this file only after the user confirms execution in /nase:address-comments. It owns Phases 5-12: code changes, verification, external-write gates, replies, resolution, reviewer handoff, cleanup, and reporting.

## Phase 5: Setup Worktree

Determine the PR branch name from `headRefName` (captured in Phase 2). Remote was already fetched in Phase 2.

If current checkout is clean and already on `{pr_branch}`, set `{worktree_path}` to `{repo_path}` and work in place. Otherwise follow the worktree pattern in `.claude/docs/worktree-pattern.md`: suffix `address-comments`, ref `origin/{pr_branch}`. After creation, checkout the PR branch:

```bash
git -C {worktree_path} checkout -B {pr_branch} origin/{pr_branch}
```

Finalize `module_inventory`: keep KB version or derive 5-15 lines inside `{worktree_path}` from top-level src/helper/service/util/client files. Prefer existing modules.

## Phase 5.5: Resolve Merge Conflicts

Skip when `merge_conflict` is false. Run it before Phase 6 so thread fixes land on the merged code, not on a base that is about to change under them.

Merge the base into the PR branch. Do not rebase: a rebase rewrites the pushed history and needs a force-push, which this command never does.

```bash
git -C {worktree_path} fetch origin {baseRefName}
git -C {worktree_path} merge --no-ff --no-commit origin/{baseRefName}
```

Resolve each conflicted file (`git -C {worktree_path} diff --name-only --diff-filter=U`) by reading both sides and the merge base (`git show :1:{path}`, `:2:`, `:3:`). Keep the intent of the PR and the intent of the base change. Never use `-X ours`, `-X theirs`, or `git checkout --ours/--theirs` on a whole hand-written file to make the markers go away; that silently drops one side's work.

- Lockfiles and generated files: take the base version, then regenerate with the repo's own command from KB or `CLAUDE.md`. Do not hand-merge them. This is the one whole-side case, and it is safe only because the generator rebuilds the content.
- Both sides changed the same logic and the right result is not obvious from the code, tests, or KB: stop and ask with `AskUserQuestion`. Show the two hunks and your proposed merge.
- Stage each resolved file (`git -C {worktree_path} add {path}`), then confirm no markers remain in those files: `git -C {worktree_path} diff HEAD --check -- {resolved_paths}` must be clean and `git -C {worktree_path} grep -n -E '^(<<<<<<<|>>>>>>>) ' -- {resolved_paths}` must find nothing.

Commit the merge with a subject that satisfies `gate_profile.commit_format`, such as `chore: merge {baseRefName} into {pr_branch}`:

```bash
git -C {worktree_path} commit -m "chore: merge {baseRefName} into {pr_branch}"
git -C {worktree_path} rev-parse HEAD   # record as merge_sha
```

If the merge reports `Already up to date`, there is nothing to resolve: record the current `HEAD` as `merge_sha` and continue.

Set `no_commit=false` and record `merge_sha`. The merge is pushed by Phase 8 with everything else; it gets no separate push or approval gate. Phase 7.5 gates the Phase 6 thread fixes, not this merge commit.

The merge moves line numbers. Re-locate each accepted thread's code in the merged tree before Phase 6 instead of trusting the Phase 3 excerpt. Phase 7 builds and tests the merged result, so a conflict that resolved textually but broke behavior fails there.

## Phase 6: Execute Changes

Before marking any thread resolved, check `.claude/docs/anti-rationalization.md → /nase:address-comments` - a reply is not a fix.

### For accept threads:

Read referenced file/line range. Apply the planned minimal change using repo standards from KB/`CLAUDE.md`.

If accepted change alters logic/adds path, ensure test coverage; add/update test if needed.

**Code comments - follow `.claude/docs/code-comment-policy.md`.** Default to none; its *When a reviewer asks for a comment* section owns this case.

**Treat a reviewer's example as a bug class, not a line.** Two thread shapes need a sweep
rather than a point fix, and the second is easy to miss because the reviewer names only one
instance:

- The comment names several cases that must land differently - "`null` and `[...]` both
  look like 'no value'", "string and list should both be malformed".
- The comment names one instance of something that plausibly repeats - a wrong
  `Constraint #N` reference, a stale call site, an outdated identifier.

Either way: enumerate what was named, derive the pattern shape from it, grep the whole file
for siblings, and check each hit against where it should land - the intended branch for an
input case, the source of truth for a reference. Any hit still landing in the old branch or
still pointing at the wrong target means the fix is not done. Watch for a per-type
short-circuit above the new gate (`if x is None: continue`), which makes a visible check
unreachable for exactly the case the reviewer named. Verify each with its own fixture before
resolving, fix every broken instance in the same commit, and state the sweep's scope in the
reply (`cross-checked every {pattern} ref in this file, fixed {N}`) so the reviewer can
spot-check.

**Expected values a reviewer changed:** apply `.claude/docs/pr-review-fix-verification.md` §1.
If the test fails at the suggested value, keep the structural improvement but restore the
original expected value and name the runtime constraint in the reply.

**A fix that narrows or gates an existing guard** so a failing test passes must re-ask the
question the original guard answered: does the condition it now skips occur in production?
State the answer in the reply and name the production input that still triggers the guard.
A gate that disables the guard for the only shape production sends turns a loud failure
into a silent no-op under a green suite.

## Phase 6.5: Fix Failing Required Checks

Skip when `required_failures` is empty. Run it after Phase 6 so one Phase 7 loop covers both the thread fixes and the check fixes.

For each failing check, in this order:

1. **Read the failure.** For GitHub Actions the `link` has the shape `.../actions/runs/{run_id}/job/{job_id}`; pass the number after `/runs/` to `gh run view {run_id} --repo {owner}/{repo} --log-failed`, not the job id. For another provider (Azure Pipelines, SonarCloud), open the details the check exposes through its own CLI or API. Quote the shortest decisive error line. If the log is unreadable with the tools at hand, say so and ask; do not guess a cause.
2. **Check the base first.** Resolve the base commit and read the same check on it (`gh pr checks` does not cover the base):

   ```bash
   base_sha=$(git -C {repo_path} rev-parse origin/{baseRefName})
   gh api "repos/{owner}/{repo}/commits/${base_sha}/check-runs" \
     --jq '.check_runs[] | select(.name == "{check_name}") | {name, conclusion, html_url}'
   ```

   If `conclusion` is anything other than `success`, `neutral`, `skipped`, or `null` (still running) there too, the base is already red for this check. Report that and ask whether to fix it here; do not change this PR's code to hide a base failure. An empty result means the base did not run that check: say so instead of calling it green.
3. **Reproduce locally.** Run the same command the check runs, as taken from the workflow file or the log. Fix only after you see the failure in your own terminal. A fix you cannot reproduce is a guess.
4. **Fix the cause.** Fix the production code. Do not weaken, skip, or delete a test, loosen a threshold, or add a lint ignore to turn the check green. If the test itself is wrong because the intended behavior changed, update it and say why. If the check is flaky (it passes on re-run with no code change), report it as flaky and do not edit code for it.
5. **Re-run the same command** and keep the passing output as evidence.

A Required failure that was caused by the merge conflict is already fixed by Phase 5.5; confirm it by running its command, then move on. A failure needing a secret, a deploy, or a service that is not available locally cannot be reproduced: report it as blocked with the evidence and leave it.

Phase 7 then runs the repo's configured gates on the whole diff. Do not wait for the new CI run after the push (see the entrypoint invariants), and say in the final report that these fixes are verified locally only.

### For decline threads:

Follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-reply`. Draft a direct reply: clear reason, technical context if needed, no defensive tone.

The `github-review-reply` row there owns the bot/AI no-courtesy-opener rule. Read the thread's `comments[].authorIsBot` from the dossier rather than judging the login by eye; `is_bot_login` in `.claude/scripts/pr-github-helper.py` owns that verdict and already covers the suffix-less AI reviewers.

Example: "The current approach handles X because [reason]. Changing to Y would [specific downside]."

**Per-thread concrete evidence rule:** each decline reply must cite evidence for *this* thread:
- dead-style file:line ref (`style removed in {sha} - the rule no longer renders`)
- no-op pre-PR behavior (`{option} was already a no-op in {framework} v{N} - see {link}`)
- design-intent confirmation (`{property} is consumed at {file}:{line}`)
- planning-doc redirect (`captured as follow-up in {Jira link}`)

A decline rationale ("this is intentional because X") is a claim about a mechanism. Trace X on `origin/{pr_branch}` plus this round's accepted fixes before drafting, and name that ref beside the claim, so the Phase 7.5 gate is the second check, not the first.

One reply per declined thread, ≤3 lines each. Do not batch declines under blanket "out of scope" / "scope-creep" wording.

### For reply-only threads:

Follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-reply`. Draft concise, non-defensive reply text.

Hold all replies until Phase 9 (post-push) so the reviewer sees both the code fix and the reply together.

### Reply tense (accept, decline, and reply-only alike): only what is true when written

Replies are drafted here and posted in Phase 9, with the push (Phase 8) and the PR-description edit
(Phase 8b) in between. A reply may only assert what is already true when its text is written - at
draft time, or when the Phase 9 post is composed. Write the still-pending part in
present-progressive (`pushing the fix now`, `updating the description to match the template`), never
in the past tense (`was corrected`, `has been pushed`), and never defer the write that would make a
past-tense claim true. Ordering alone does not protect the claim: any gate skipped between here and
Phase 9 leaves a false statement posted to a human reviewer. Re-check and rewrite the reply in
Phase 9 before posting, so a claim that only becomes true after Phase 8 is added then, not left in
the draft.

A past-tense `executed` is allowed only when a run covers the current edits; if the last run
predates an edit (Phase 7.25, or a 7.5-triggered return to Phase 6), re-run or drop the claim. A
`committed` claim requires a Phase 8 commit (`no_commit=false`) that contains every edit: apply the
`.claude/docs/commit-push-pattern.md` §5 HEAD check, then confirm
`git -C {worktree_path} status --porcelain` names no uncommitted file from this round - a clean tree
alone also matches the no-commit path. A `pushed` claim additionally requires
`git -C {worktree_path} rev-parse HEAD` to equal
`git -C {worktree_path} rev-parse origin/{pr_branch}`. Never invent a SHA; if either check fails,
finish the commit/push or drop the claim. Scope words in replies (`all N`, `verified`, `green`)
follow `.claude/docs/anti-rationalization.md → Universal`.

## Phase 7: Build & Test (max 5 iterations)

Get configured build, lint, typecheck, and test commands from the KB file or repo's `CLAUDE.md`.
Follow the build & test iteration loop in `.claude/docs/build-test-loop.md` (max 5 iterations). Every configured gate must pass before proceeding. After all gates pass, apply the Step 2.6 test-presence soft gate against the Phase 6 edits (`{merge_sha}..HEAD` plus the working tree when Phase 5.5 ran, otherwise `origin/{pr_branch}`) - if an accepted thread changed logic but the diff adds no test, the Phase 6 "ensure test coverage" promise was missed; add the test or record the justification in the reply for that thread.
On success: proceed to Phase 7.5.

## Phase 7.25: Optional Post-Edit CLI Gates

Run the changed-file-type gates from `.claude/docs/cli-tooling.md -> Skill Integration Map` (`fsd` / `address-comments` row) against the Phase 6 edits - the same diff Phase 8 judges - probing as that document's *Running the post-edit gates* section specifies.

Apply a formatter or scanner fix only when it stays inside the accepted thread's scope. Scanner output is not reviewer intent: check each finding against the review thread as well as the diff before expanding the patch.

## Phase 7.5: Review-Thread Resolution Gate

Follow `.claude/docs/pr-review-fix-verification.md → Review-Thread Resolution Gate`. The gate is mandatory before commit or outward replies, and it has no availability branch: the verifier is a local fresh-context subagent.

## Phase 8: Commit & Push

Judge the accept-thread check against the Phase 6 edits only. A Phase 5.5 merge commit is base content and proves nothing about a thread, and `git diff origin/{pr_branch}` now contains it. When Phase 5.5 ran, compare against the recorded `merge_sha`; otherwise compare against `origin/{pr_branch}`:

```bash
# with a merge commit
git -C {worktree_path} diff {merge_sha}..HEAD
git -C {worktree_path} status --porcelain
# without one
git -C {worktree_path} diff origin/{pr_branch}
git -C {worktree_path} status --porcelain
```

If the final post-Phase-4 dossier/action map has any `accept` thread and that diff is empty, stop. Report `Accepted thread(s) produced no code diff; fix the code change or reclassify before replying/resolving.` Do not proceed to Phase 9.

A Phase 5.5 merge commit or a Phase 6.5 fix means there is something to push: follow the commit & push sequence below, committing any uncommitted Phase 6 edits first.

If there are no code changes after Phase 6 and neither a merge commit nor a Phase 6.5 fix exists:
- If the final dossier/action map has only `reply-only` / `decline` threads, skip commit and push. Set `no_commit=true`, report `No code changes; proceeding to review replies/resolution only.`, skip Phase 8b, and continue to Phase 9.

**Re-verify worktree HEAD before commit** - a concurrent session can move your branch and drop edits; recover per `worktree-pattern.md`.

Conform the commit subject to `gate_profile.commit_format` per `.claude/docs/pr-gates-consumption.md` §3 (documented `type`/`scope`, no `fixup!`/`squash!`) before committing.

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md`.
Deviation: in "Confirm before push" mode, show the staged diff (`git diff --cached --stat` + key hunks) and the commit message before pushing, then use `AskUserQuestion`:

```
question: "Ready to push these changes?"
header: "Push Confirmation"
options:
  - label: "Push"
    description: "Push and proceed to resolve comments"
  - label: "Abort"
    description: "Stop here - I'll handle it manually"
```

If aborted: print the worktree path so the user can continue manually, and stop.

## Phase 8b: Update PR Description to Match Template

After push, check PR description against repo template via `.claude/docs/pr-creation-pattern.md` Step 1.

If a template exists and the current PR description doesn't follow it (missing sections, wrong headings):
- Fetch current PR body: `gh pr view {pr_number} --repo {owner}/{repo} --json body -q .body`
- Restructure the description to match the template's section headings
- Preserve existing author-written content - migrate it into the correct sections
- Fill the "How to Review" section if empty, based on the changes made in this session
- Do not overwrite sections the author already filled correctly
- Apply `.claude/docs/pr-gates-consumption.md` §3 with `gate_profile`: every required PR-body section must exist at its minimum length, and `## How to Review` must be filled if the PR's size bucket mandates it. Never invent a ticket key - keep the placeholder and flag it.

Before running `gh pr edit`, show the proposed PR body and use `AskUserQuestion` as the immediate external-mutation gate:

```
question: "Update the PR description to match the template with this body?"
header: "PR Body"
options:
  - label: "Update PR body"
    description: "Run gh pr edit with the proposed body shown above"
  - label: "Skip PR edit"
    description: "Leave the current PR description unchanged"
```

If skipped, continue to Phase 9. Do not reuse earlier "Full auto" or push confirmation; show concrete body immediately before edit.

Write the approved body to a mode-600 `PR_BODY_FILE`; install `trap 'rm -f "$PR_BODY_FILE"' EXIT`. Use `external-write-action.py` to prepare the exact `gh pr edit {pr_number} --repo {owner}/{repo} --body-file "$PR_BODY_FILE"` action, show its manifest, then authorize and execute that manifest. Do not reuse any earlier approval.

If the description already follows the template, skip this phase.

## Phase 9: Reply & Resolve Comments

Every `gh` mutation in this phase goes through `.claude/scripts/external-write-action.py`, which enforces the account guard itself (`.claude/docs/external-mutation-policy.md → GitHub auth account guard`: `prepare` binds the owner-to-account mapping into the hashed action, `execute` re-reads it and verifies the token actor). There is no snippet to run and no `gh auth` call to make - raw `gh auth token`/`login`/`logout`/`refresh`/`switch` are blocked.

After push or no-code skip, handle each thread: **reply first, then resolve**.

For each thread, compose the reply body based on its category:
- **accept**: `"Fixed - {brief description of what was changed}."`
- **decline**: the explanation drafted in Phase 6
- **reply-only**: the reply drafted in Phase 6

**Bulk throttle**: apply the shared throttle rule from `.claude/docs/github-queries.md → Resolve Review Threads → Shared throttle rule` whenever the total number of threads to reply to exceeds 30.

Re-query `reviewThreads` live immediately before building the payload. A thread that became resolved, or gained a comment after the Phase 2 dossier, drops out of the payload and is reported to the user as changed.

Before making any GitHub reply or resolve API call, show the concrete per-thread payload:

- Thread id / comment id
- Category from the final post-Phase-4 dossier/action map
- Reply body
- Whether it will be resolved (`accept`, `reply-only`) or left open (`decline`)

Then use `AskUserQuestion`:

```
question: "Post these review replies and resolve the listed threads?"
header: "Review Threads"
options:
  - label: "Post + resolve"
    description: "Run the GitHub reply calls and resolve only accept/reply-only threads shown above"
  - label: "Skip GitHub writes"
    description: "Leave replies and thread resolution for manual follow-up"
```

If skipped, report the pending reply/resolve payload and stop before Phase 9b.

Prepare, show, authorize, and execute each reply and resolve separately with `external-write-action.py`; each action gets its own one-shot token. Reply with the exact shape in `.claude/docs/github-queries.md -> Reply To A Review Thread` (jq-built `--input` payload, integer `databaseId`) - never improvise the `gh api` field flag, because `-f body=@FILE` silently posts the file path instead of the reply. Run that section's read-back verification after each reply: a mismatch means the reply did not land, so report the comment ID and leave the thread unresolved. Resolve with Shape A from `.claude/docs/github-queries.md -> Resolve Review Threads` and the GraphQL opaque `id`.

Process `accept` and `reply-only` threads using this pattern (reply + resolve). For `decline` threads: **reply only, do NOT resolve** - the reviewer may want to respond or push back. Resolving a declined thread shuts down the conversation prematurely.

**Category source-of-truth**: use the post-Phase-4 dossier/action map - NOT the initial Step 3c classification. If a thread was reclassified during Phase 4 user override (e.g., decline → accept), it goes into the resolve set here. Confirm by reading the final dossier/action map once before iterating.

## Phase 9b: Optional Reviewer Ping (Human Reviewers Only)

After replies + resolves succeed, offer to Slack-ping any human reviewers whose comments were addressed. Bots don't need a ping - they don't read Slack and re-reviews from them re-trigger automatically on the next push.

**Build the ping set.** From the threads addressed in Phase 9 (`accept` + `reply-only`; declined threads stay open intentionally), take each thread's `firstComment` - the original review comment, not your reply - and drop every one whose `firstComment.authorIsBot` is true. That flag comes from `is_bot_login` in `.claude/scripts/pr-github-helper.py`, which owns the whole rule (the named set, the `[bot]`/`-bot` suffixes, `NASE_BOT_LOGINS`), so do not re-derive it from the login text. Drop the PR author's own login. Phase 2's `comment-dossiers` does not carry it - `guards` holds repo identity only - so read it once with `gh api user --jq .login`. Keep each remaining `author` with the count of threads addressed for them.

If the set is empty, skip this phase silently - no message to the user.

**Ask, then hand off.** Use a single `AskUserQuestion` listing the unique human reviewers (up to 3 plus "None - skip all"; batch into multiple calls in the same turn if more):

```
question: "Addressed comments from these reviewers. Draft a Slack ping for any so they know to re-review?"
header: "Re-review ping"
multiSelect: true
options:
  - label: "@{login_1}"
    description: "{N_1} threads addressed"
  - label: "@{login_2}"
    description: "{N_2} threads addressed"
  - label: "None - skip all"
    description: "Don't ping anyone"
```

On "None - skip all" or an empty selection, skip the rest of this phase.

Otherwise invoke `/nase:request-review {pr_url} --mode re-review-ping` with the selected handles and the current `no_commit` value. That skill owns Slack-user resolution, the draft voice, and the staging report; duplicating any of it here is how the two copies drifted apart. Because the ping is handled, Phase 12 must not offer "Request review" again.

## Phase 10: Learn

Offer `/nase:kb-update` for confirmed non-obvious architectural constraints. Put general coding lessons under the `code` category in `workspace/tasks/lessons.md` using `.claude/docs/lessons-format.md`.

## Phase 11: Cleanup and Report

For a worktree, follow `.claude/docs/worktree-pattern.md -> Cleanup` and consume the
return code per its *Return codes* section. Then print:

```
PR comments addressed ✓

  PR:              {pr_url}
  Accepted:        {N} threads (code changed)
  Declined:        {N} threads (replied with reasoning)
  Replies:         {N} threads
  Resolved:        {total_resolved} / {total_threads}
  Build/test:      passed (iteration {N})
  Merge conflict:  {resolved via merge of origin/{baseRefName} | none}
  Required checks: {N} fixed (local re-run passed), {M} blocked or flaky: {names}   # omit when none failed
  Worktree:        {retained path or n/a}
  Slack pings:     {M} drafts staged for {comma-separated logins}   # omit when 0
  Commit:          {short_sha} - {commit_subject}                   # omit when no commit
```

If PR gates came from the live fallback, add the stale-KB note from `.claude/docs/pr-gates-consumption.md` section 2.

Append the daily log before the next prompt using `.claude/docs/daily-log-format.md` with tag `address-comments`:

`{repo_name}#{pr_number} - {N} resolved ({M} accepted, {K} declined, {J} replies)`

## Phase 12: Next-step handoff

Follow `.claude/docs/pr-next-step-handoff.md -> Address-Comments Handoff`.

## Error handling

- Never force-push or change tests merely to make them pass.
- Resolve conflicts by merging the base in, never by rebase. Never take one whole side of a hand-written source file to clear the markers; lockfiles and generated files are the exception, taken from the base and regenerated.
- A Required check you could not reproduce, or that fails on the base too, is reported with evidence and left alone. It is never "fixed" by weakening the check.
- Reply before resolve; never resolve a declined thread.
- On partial API failure, report exact failed thread IDs for manual recovery.
- If reviewer intent remains ambiguous, ask instead of guessing.
