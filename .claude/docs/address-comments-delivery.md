# Address Comments Delivery

## Contents

- Phase 5: Setup Worktree
- Phase 6: Execute Changes
- Phase 7: Build & Test (max 5 iterations)
- Phase 7.25: Optional Post-Edit CLI Gates
- Phase 7.5: Review-Thread Resolution Gate (Codex, with single-model fallback)
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

**Expected values a reviewer changed:** apply `.claude/docs/pr-review-verification.md` §1.
If the test fails at the suggested value, keep the structural improvement but restore the
original expected value and name the runtime constraint in the reply.

### For decline threads:

Follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-reply`. Draft a direct reply: clear reason, technical context if needed, no defensive tone.

The `github-review-reply` row there owns the bot/AI no-courtesy-opener rule. Read the thread's `comments[].authorIsBot` from the dossier rather than judging the login by eye; `is_bot_login` in `.claude/scripts/pr-github-helper.py` owns that verdict and already covers the suffix-less AI reviewers.

Example: "The current approach handles X because [reason]. Changing to Y would [specific downside]."

**Per-thread concrete evidence rule:** each decline reply must cite evidence for *this* thread:
- dead-style file:line ref (`style removed in {sha} - the rule no longer renders`)
- no-op pre-PR behavior (`{option} was already a no-op in {framework} v{N} - see {link}`)
- design-intent confirmation (`{property} is consumed at {file}:{line}`)
- planning-doc redirect (`captured as follow-up in {Jira link}`)

One reply per declined thread, ≤3 lines each. Do not batch declines under blanket "out of scope" / "scope-creep" wording.

### For reply-only threads:

Follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-reply`. Draft concise, non-defensive reply text.

Hold all replies until Phase 9 (post-push) so the reviewer sees both the code fix and the reply together.

## Phase 7: Build & Test (max 5 iterations)

Get configured build, lint, typecheck, and test commands from the KB file or repo's `CLAUDE.md`.
Follow the build & test iteration loop in `.claude/docs/build-test-loop.md` (max 5 iterations). Every configured gate must pass before proceeding. After all gates pass, apply the Step 2.6 test-presence soft gate against `origin/{pr_branch}` - if an accepted thread changed logic but the diff adds no test, the Phase 6 "ensure test coverage" promise was missed; add the test or record the justification in the reply for that thread.
On success: proceed to Phase 7.5.

## Phase 7.25: Optional Post-Edit CLI Gates

Probe optional tools, then run the changed-file-type gates from `.claude/docs/cli-tooling.md -> Skill Integration Map` (`fsd` / `address-comments` row) against the diff vs `origin/{pr_branch}`:

```bash
python3 .claude/scripts/tool-availability.py --group baseline --group ci --group review --group security --format json
```

Apply a formatter or scanner fix only when it stays inside the accepted thread's scope. Missing optional tools are warning-only and must not block replies or thread resolution when the code/test evidence is otherwise adequate. Scanner output is not reviewer intent: verify findings against the review thread, diff scope, and source lines before expanding the patch.

## Phase 7.5: Review-Thread Resolution Gate (Codex, with single-model fallback)

Follow `.claude/docs/pr-review-verification.md → Review-Thread Resolution Gate`. The gate is mandatory before commit or outward replies: use Codex when available, otherwise the documented fresh-context fallback.

## Phase 8: Commit & Push

If there are no code changes after Phase 6:
- If the final post-Phase-4 dossier/action map has any `accept` threads, stop. Report `Accepted thread(s) produced no code diff; fix the code change or reclassify before replying/resolving.` Do not proceed to Phase 9.
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

Before any `gh` mutation in this phase, run the GitHub auth account guard snippet from `.claude/docs/external-mutation-policy.md → GitHub auth account guard`.

After push or no-code skip, handle each thread: **reply first, then resolve**.

For each thread, compose the reply body based on its category:
- **accept**: `"Fixed - {brief description of what was changed}."`
- **decline**: the explanation drafted in Phase 6
- **reply-only**: the reply drafted in Phase 6

**Bulk throttle**: apply the shared throttle rule from `.claude/docs/github-queries.md → Resolve Review Threads → Shared throttle rule` whenever the total number of threads to reply to exceeds 30.

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

**Step 9b.1 - Filter to human reviewers.** From the threads addressed in Phase 9 (i.e. `accept` + `reply-only`; excluding declined since those threads stay open intentionally), collect each thread's `firstComment` (the original review comment, not your reply) and drop every one whose `firstComment.authorIsBot` is true. That flag comes from `is_bot_login` in `.claude/scripts/pr-github-helper.py`, which owns the whole rule - the named set, the `[bot]`/`-bot` suffixes, and `NASE_BOT_LOGINS` - so do not re-derive it from the login text. Keep the unique remaining `author` values, and also drop the PR author's own login; use `gh api user --jq .login` once if you don't already know it.

If the remaining set is empty, skip this phase silently - no message to the user.

**Step 9b.2 - Ask whether to draft pings.** For each human reviewer, you have how many threads were addressed (count from Phase 9). Use a single `AskUserQuestion` whose options are the unique human reviewers (up to 3 plus a "skip all" option; if >3, batch into multiple `AskUserQuestion` calls in the same turn):

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

If the user picks "None - skip all" (or doesn't select any reviewers), skip the rest of this phase.

**Step 9b.3 - Resolve each selected GitHub login to a Slack user.** Get the real name from the repo KB's handle mappings first, then `gh api users/{login} --jq .name`, and search Slack with the query shape `/nase:request-review` Step 4 documents (bare given name for an uncommon one, `"{Given} {Surname}"` for a common one, never the corporate suffix). If a login stays unresolved after both name sources, surface `"Couldn't resolve {login} on Slack - skipping ping"` and move on.

**Step 9b.4 - Draft (do NOT send) one Slack DM per resolved reviewer.** Use `slack_send_message_draft`, per `.claude/docs/slack-draft-style.md` and `.claude/docs/voice-profile-routing.md` with `surface=slack-dm`. The body is one opener line, a blank line, then the bare PR URL on its own line:

```
{ping_opener}

{pr_url}
```

This is a re-review ping, not a review request, so the opener names what changed: `"Pushed fixes for your comments on the PR - ready for another look when you get a minute."`, or `"Responded to your comments on the PR - ready for another look when you get a minute."` when `no_commit=true`.

After staging each draft, print: `"Slack DM draft staged for @{login} (Slack: {slack_handle}) - review + send manually."` The user reviews and sends each draft themselves; this skill never sends.

## Phase 10: Learn

Offer `/nase:kb-update` for confirmed non-obvious architectural constraints. Put general coding lessons under the `code` category in `workspace/tasks/lessons.md` using `.claude/docs/lessons-format.md`.

## Phase 11: Cleanup and Report

For a worktree, follow `.claude/docs/worktree-pattern.md -> Cleanup`. Return `3`
retains it, including verified-clean quarantines, and return `2` stops. Report
the returned path plus up to 20 dirty items and any omitted-item count.
Never run cleanup when the workflow used the primary checkout. Then print:

```
PR comments addressed ✓

  PR:              {pr_url}
  Accepted:        {N} threads (code changed)
  Declined:        {N} threads (replied with reasoning)
  Replies:         {N} threads
  Resolved:        {total_resolved} / {total_threads}
  Build/test:      passed (iteration {N})
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
- Reply before resolve; never resolve a declined thread.
- On partial API failure, report exact failed thread IDs for manual recovery.
- If reviewer intent remains ambiguous, ask instead of guessing.
