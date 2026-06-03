---
name: nase:address-comments
description: "Fix unresolved PR review comments — makes code changes, pushes, checks currently failed PR gates once, fixes mechanical failures only, then resolves threads. Use when you have reviewer feedback to act on (not for initial PR analysis). Triggers: 'address comments', 'fix review comments', 'handle PR feedback', 'resolve comments', 'respond to reviewer'. For read-only analysis before feedback exists, use /nase:discuss-pr instead."
---

**Input:** $ARGUMENTS — a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`)

Follows `.claude/docs/external-mutation-policy.md`: code push, `gh pr edit`, replies, thread resolution, and Slack DMs each have their own gate.

---

## Phase 0: Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` minimum Step 0. Use `conversation:` for chat/prompts and `output:` for GitHub text.

## Phase 0.5: Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md` — except on empty input, ask the user for the PR URL using `AskUserQuestion` instead of printing usage.

## Phase 1: Locate Repo & Fetch Context

Resolve the single local repo from the PR URL and load its KB file — see `.claude/docs/repo-resolution.md` (Part 1 + Part 2).

Mutates one repo only. PR URL, KB path, local `origin`, and PR head repo must all match `{owner}/{repo}`; otherwise stop and ask.

Verify local `origin` before any fetch or comment read:

```bash
REMOTE_URL=$(git -C {repo_path} remote get-url origin)
REMOTE_REPO=$(printf '%s\n' "$REMOTE_URL" \
  | sed -E 's#^https://([^/@]+@)?github.com/##; s#^git@github.com:##; s#^ssh://git@github.com/##; s#/*$##; s#\.git$##')
REMOTE_REPO_LC=$(printf '%s\n' "$REMOTE_REPO" | tr '[:upper:]' '[:lower:]')
EXPECTED_REPO_LC=$(printf '%s\n' "{owner}/{repo}" | tr '[:upper:]' '[:lower:]')
if [ "$REMOTE_REPO_LC" != "$EXPECTED_REPO_LC" ]; then
  echo "Resolved local repo origin ($REMOTE_REPO) does not match PR repo ({owner}/{repo}). Stop and ask for the correct local path."
  exit 1
fi
```

If this fails, do not update `.local-paths` automatically; ask for the correct path and rerun Phase 1.

**Module-inventory extraction:** capture KB `## Modules` / `## Components`. If absent, set `module_inventory = needs-grep`; derive it in Phase 5 from the PR worktree, not the pre-worktree checkout.

**PR Gates extraction:** read the KB's `## PR Gates` section (template in `.claude/docs/kb-template.md`). Cache the per-gate fix recipes for Phase 8.7. If the section is absent or empty, set `pr_gates_kb_missing=true`; Phase 8.7 offers a backfill.

## Phase 2: Fetch Latest & Unresolved Review Threads

Fetch remote refs for the KB-resolved repo:

```bash
git -C {repo_path} fetch origin
```

Use `.claude/docs/github-queries.md` full unresolved-thread GraphQL query.

Capture `baseRefName`, `headRefName`, `headRepository.nameWithOwner`, and unresolved threads (`isResolved == false`).

**Same-repo guard:** `headRepository.nameWithOwner` must match `{owner}/{repo}` case-insensitively. If null or different, stop; this command does not handle forks or second repos.

Set `pr_head_ref = origin/{headRefName}` for Phase 3 code reads and Phase 5 worktree setup. Verify it exists before proceeding:

```bash
git -C {repo_path} rev-parse --verify origin/{headRefName}
```

Capture both thread `id` (GraphQL resolve) and `databaseId` (REST reply); they are not interchangeable.

If there are zero unresolved threads: report "No unresolved comments found" and stop.

## Phase 3: Critically Evaluate & Present Plan

**Step 3a — Load context before evaluating:**

For each thread, read full comment chain plus surrounding code from PR head: `git -C {repo_path} show {pr_head_ref}:{path}`. Cross-reference KB/Confluence/past decisions before classifying.

**Step 3b — Resolve unclear threads first:**

Ask about ambiguous/design threads first using full comment chain; collect answers before final plan.

**Step 3c — Evaluate and classify remaining threads:**

Evaluate each suggestion:

0. **Verify first**: apply `.claude/docs/pr-review-verification.md` §3 (File-vs-description). If the reviewer's prose does not match the file at the referenced line, decline the suggestion regardless of other factors.
1. **Correctness**: Does the reviewer's suggestion fix an actual bug or prevent a real failure mode? Or is the current code already correct?
2. **Context**: Does the reviewer have full context? Sometimes a suggestion makes sense locally but conflicts with constraints elsewhere (e.g., API contracts, performance requirements, framework limitations).
3. **Substance vs. style**: Is this a meaningful improvement to correctness, readability, or maintainability? Or is it a cosmetic/stylistic preference that doesn't materially improve the code?
4. **Risk**: Could accepting this change introduce a regression, break an invariant, or conflict with the broader design?

**Classify each thread:**

| Category | When to use | Action |
|----------|-------------|--------|
| **accept** | Suggestion fixes a real issue, improves correctness, or meaningfully improves clarity/maintainability | Modify the code |
| **decline** | Current code is correct and the suggestion is stylistic, based on incomplete context, or would introduce risk | Reply explaining why the current approach is intentional |
| **reply-only** | Question, discussion point, or acknowledgment needed — no code involved | Write a reply |

Accept only when the change measurably improves correctness/clarity. If current code is equally valid, decline with concrete KB/architecture context when available.

**Step 3d — Present the complete plan:**

```
Found {N} unresolved review threads:

  1. ✅ [{path}:{line}] {first_comment_summary} → accept: {what_you_plan_to_do}
  2. ↩️ [{path}:{line}] {first_comment_summary} → decline: {why current code is correct/better}
  3. 💬 [{path}:{line}] {first_comment_summary} → reply-only: {draft_reply_summary}
  ...
```

## Phase 4: User Override & Confirm Execution

After presenting the plan, use `AskUserQuestion` to ask the user to review the classifications:

```
question: "Review the plan above. Want to change any classifications before I proceed?"
header: "Plan Review"
options:
  - label: "Looks good"
    description: "Proceed as planned"
  - label: "I have changes"
    description: "Let me adjust some items"
```

If user changes classifications, recompute the final per-thread category map explicitly; Phase 9 uses only this map.

Then use `AskUserQuestion` to ask for execution mode:

```
question: "How should I proceed?"
header: "Execution Mode"
options:
  - label: "Full auto"
    description: "Make changes, build, test, and push; still ask the required concrete gate before GitHub replies/resolves"
  - label: "Confirm before push"
    description: "Make changes and run build/tests, but pause for your review before pushing"
```

## Phase 5: Setup Worktree

Determine the PR branch name from `headRefName` (captured in Phase 2). Remote was already fetched in Phase 2.

If current checkout is clean and already on `{pr_branch}`, set `{worktree_path}` to `{repo_path}` and work in place. Otherwise follow the worktree pattern in `.claude/docs/worktree-pattern.md`: suffix `address-comments`, ref `origin/{pr_branch}`. After creation, checkout the PR branch:

```bash
git -C {worktree_path} checkout -B {pr_branch} origin/{pr_branch}
```

Finalize `module_inventory`: keep KB version or derive 5-15 lines inside `{worktree_path}` from top-level src/helper/service/util/client files. Prefer existing modules.

## Phase 6: Execute Changes

### For accept threads:

Read referenced file/line range. Apply the planned minimal change using repo standards from KB/`CLAUDE.md`.

If accepted change alters logic/adds path, ensure test coverage; add/update test if needed.

**AI-reviewer assertion-value guard:** apply `.claude/docs/pr-review-verification.md` §1. If the test fails at the suggested expected value, keep the structural improvement (e.g. null-safe cast on the indexer) but restore the original expected value, and note the runtime constraint in the reply. A pattern that survives both null and empty-string is `string.IsNullOrEmpty((string?)token["k"]).Should().BeTrue(...)`.

**Cross-reference identifier audit:** if a reviewer flags an incorrect doc/comment identifier, treat it as a bug class, not one line.

1. Derive the pattern shape from the flagged token — language/doc-style dependent (`Constraint #[0-9]+`, `Foo\.\w+:[0-9]+`, `§[0-9]+(\.[0-9]+)?`, etc. are illustrative, not prescriptive).
2. Grep the whole file: `grep -nE "{pattern}" {file}`.
3. Cross-check every occurrence against the source of truth.
4. Fix all broken instances in the same commit.
5. In the reply, mention the broader audit so the reviewer can spot-check: `"cross-checked every {pattern-name} ref in this file, fixed {N} broken ones (lines {L1}, {L2}, …)"`.

### For decline threads:

Draft a direct reply: clear reason, technical context if needed, no defensive tone.

Example: "The current approach handles X because [reason]. Changing to Y would [specific downside]."

### For reply-only threads:

Draft concise, non-defensive reply text.

Hold all replies until Phase 9 (post-push) so the reviewer sees both the code fix and the reply together.

## Phase 7: Build & Test (max 5 iterations)

Get configured build, lint, typecheck, and test commands from the KB file or repo's `CLAUDE.md`.
Follow the build & test iteration loop in `.claude/docs/build-test-loop.md` (max 5 iterations). Every configured gate must pass before proceeding.
On success: proceed to Phase 7.5.

## Phase 7.5: Codex Review-Thread Resolution Gate

Gate per `.claude/docs/codex-review.md → Prerequisite`; skip cleanly to Phase 8 if MCP is not loaded.

Invoke the Codex MCP with the `comment-resolution` mode contract from `.claude/docs/codex-review.md`:

- `cwd` = `{worktree_path}`
- `prompt` = unresolved review threads from Phase 2, the final post-Phase-4 category map, drafted replies from Phase 6, and the implementation diff:
  - If code changed: `git -C {worktree_path} diff origin/{pr_branch}` (working tree diff before commit)
  - Also include `git -C {worktree_path} ls-files --others --exclude-standard` and the full content of any task-created untracked files
  - If no code changed: say `No code diff; reply-only / decline verification only`
  - For diffs >2000 lines: use `git diff --stat` plus the 5 most-changed files in full
- `developer-instructions` = the `comment-resolution` template verbatim
- `sandbox` = `read-only`

Expected shape:
```
VERDICT: PASS | FAIL | NEEDS-HUMAN
THREADS NOT ADDRESSED: ...
REPLY / RESOLVE RISKS: ...
SCOPE CREEP: ...
REASONING: ...
```

Decision tree:

- **PASS** → log one line (`Codex thread-resolution verify: PASS`) and proceed to Phase 8. No user prompt.
- **NEEDS-HUMAN** → present the full Codex output and ask via `AskUserQuestion`:
  - Q: "Codex flagged ambiguity in the review-thread resolution. What now?"
  - Options: `Revise first` / `Proceed — push anyway` / `Show me the diff + replies`
  - Honor the user's choice.
- **FAIL** → do NOT commit or push. Present the full Codex output and ask via `AskUserQuestion`:
  - Q: "Codex says at least one review thread isn't safely addressed. What now?"
  - Options: `Fix it` / `Override — Codex is wrong` / `Cancel`
  - On "Fix it": re-enter Phase 6 with the failing thread(s) as requirements, then rerun build/test and this gate.
  - On "Override": log the override to the daily log (tag: `codex-override`) before proceeding.

Malformed output (no `VERDICT:` line) → treat as `NEEDS-HUMAN`, present raw `content`, and ask the user.

This gate checks reviewer intent, not just tests.

## Phase 8: Commit & Push

If there are no code changes after Phase 6:
- If the final post-Phase-4 category map has any `accept` threads, stop. Report `Accepted thread(s) produced no code diff; fix the code change or reclassify before replying/resolving.` Do not proceed to Phase 9.
- If the final map has only `reply-only` / `decline` threads, skip commit and push. Set `no_commit=true`, report `No code changes; proceeding to review replies/resolution only.`, skip Phase 8b, and continue to Phase 9.

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md`.
Deviation: in "Confirm before push" mode, show the staged diff (`git diff --cached --stat` + key hunks) and the commit message before pushing, then use `AskUserQuestion`:

```
question: "Ready to push these changes?"
header: "Push Confirmation"
options:
  - label: "Push"
    description: "Push and proceed to resolve comments"
  - label: "Abort"
    description: "Stop here — I'll handle it manually"
```

If aborted: print the worktree path so the user can continue manually, and stop.

## Phase 8b: Update PR Description to Match Template

After push, check PR description against repo template via `.claude/docs/pr-creation-pattern.md` Step 1.

If a template exists and the current PR description doesn't follow it (missing sections, wrong headings):
- Fetch current PR body: `gh pr view {pr_number} --repo {owner}/{repo} --json body -q .body`
- Restructure the description to match the template's section headings
- Preserve existing author-written content — migrate it into the correct sections
- Fill the "How to Review" section if empty, based on the changes made in this session
- Do not overwrite sections the author already filled correctly

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

Update:
```bash
gh pr edit {pr_number} --repo {owner}/{repo} \
  --body "$(cat <<'NASE_PR_BODY'
{updated_description}
NASE_PR_BODY
)"
```

If the description already follows the template, skip this phase.

## Phase 8.7: Current PR Gate Check

Skip entirely if `no_commit=true` AND Phase 8b made no PR body change — without a new commit or body edit, CI won't re-run, so there is no new gate state to inspect.

After push (+ optional body update), read the PR gate state once. Do not wait or poll. If a gate is already failed at the time of the read and has a mechanical, documented fix, apply that fix. If checks are pending, queued, canceled, skipped unexpectedly, or unknown, report the current state and proceed to Phase 9 without claiming gates are green.

This phase does not grant a blanket external-write approval. Reading checks and failed-run logs is automatic. Any `gh pr edit`, new commit, or extra push must go through the same concrete gate as the phase that owns that mutation: Phase 8b for PR body/title edits, Phase 8 for code commits/pushes, and `.claude/docs/external-mutation-policy.md → GitHub auth account guard` immediately before each `gh` mutation.

**Step 8.7a — Read current checks once.**

```bash
checks_read_failed=false
checks_err=$(mktemp)
status_json=$(gh pr checks {pr_number} --repo {owner}/{repo} --json bucket,state,name,workflow,link 2>"$checks_err")
checks_rc=$?
if [ "$checks_rc" -ne 0 ] && [ "$checks_rc" -ne 8 ]; then
  echo "Unable to read PR checks; skipping PR gate check rather than treating checks as green." >&2
  cat "$checks_err" >&2
  checks_read_failed=true
fi
rm -f "$checks_err"
if [ "${checks_read_failed:-false}" != true ] && [ -z "$status_json" ]; then
  echo "Unable to read PR checks: gh returned no JSON. Skipping PR gate check." >&2
  checks_read_failed=true
fi
```

If `checks_read_failed=true`: report that PR gate status is unknown, log `PR gates: unknown (check read failed)`, skip the remaining Phase 8.7 steps, and proceed to Phase 9 without claiming gates are green.

**Step 8.7b — Identify failures.**

```bash
failed=$(printf '%s' "$status_json" | jq -r '.[] | select(.bucket == "fail") | [.name, (.workflow // ""), (.link // "")] | @tsv')
non_green=$(printf '%s' "$status_json" | jq -r '.[] | select(.bucket != "pass" and .bucket != "skipping") | [.name, .bucket, (.workflow // ""), (.link // "")] | @tsv')
```

Zero failures and zero `non_green` rows → log `PR gates: all green` to the daily log and skip to Phase 9. If `failed` is empty but `non_green` is not empty (for example, pending or canceled checks), report those rows as non-mechanical gate states and proceed to Phase 9 without claiming gates are green.

If failures exist alongside pending checks, fix only the currently failed rows with known mechanical recipes. Report the pending rows, but do not wait for them.

**Step 8.7c — Classify and apply fixes (max 2 fix iterations).**

For each failing check, match `name` against the cached `## PR Gates` table from Phase 1, falling back to the well-known list below. Use the KB's fix recipe when present — the table here is the safety net so the sweep works even for repos that haven't been onboarded with the new gates section yet.

When a recipe needs a failed-run log, derive `run_id` from the check `link` (`.../actions/runs/{run_id}`) before running `gh run view {run_id} --log-failed`. If the link is missing or not a GitHub Actions run URL, summarize the check name + link and ask instead of guessing.

| Gate name pattern | Fix recipe |
|-------------------|------------|
| `Commit Lint` / `commitlint` | Pull failed-run log to identify the offending commit subject. If the bad commit has already been pushed, do **not** add a follow-up commit — commitlint will still fail on the original subject. Report the offending subject and ask whether to hand off to `/nase:prep-merge` or `/nase:improve-commit-message` with explicit force-push confirmation. Only run `/nase:improve-commit-message` directly when the offending commit is still local/unpushed. |
| `PR Description Check` / `pr-description-check` | Re-fetch body. If `## What` < 20 chars: extend with the implementation summary from this session's commits. If `## Testing` < 15 chars: fill with the build/test commands run in Phase 7. Reuse Phase 8b's `gh pr edit` mutation gate. |
| `PR Size Check` / `pr-size-check` | Workflow only fails when `## How to Review` is empty. Fill it with a short walkthrough drawn from `gh pr diff --name-only` + the per-file 1-line intent. Reuse Phase 8b's `gh pr edit` mutation gate. |
| `Check for JIRA issue key` / `checkjiraissuekey` | Inspect PR title; if no `[A-Z]+-[0-9]+` token, ask the user for the Jira key. Then show the exact new title and reuse Phase 8b's immediate `gh pr edit` mutation gate before running `gh pr edit {pr_number} --title "{new_title}"`. |
| `EF Migration Checker` / migration drift | Read the bot's drift comment to learn the missing `<Context>` name. Run `dotnet ef migrations add <Name> --context <Ctx>` in `{worktree_path}`, rerun Phase 7 verification, then re-enter Phase 8 for commit/push (including "Confirm before push" behavior). Do not commit or push directly from this table. |
| `Lint Code Base` / super-linter | If the workflow has `continue-on-error: true` (advisory), log but skip — these don't block merge. Otherwise the bot auto-commits fixes back to the PR branch; `git -C {worktree_path} pull --ff-only` so the local worktree matches, then move on. |
| Anything else | Fetch failed-run log; summarize the failure in 3 lines; present via `AskUserQuestion` with options `Fix manually now` / `Skip — leave failing` / `Show full log`. Honor the user's choice. |

After any fix that produces a new commit or PR-metadata edit, read current checks once again. Hard-cap at 2 fix iterations to avoid loops where a fix keeps breaking another gate.

**Step 8.7d — KB backfill prompt.**

If `pr_gates_kb_missing=true`, after Step 8.7c settles, summarize the gates observed this run (name + workflow path) and ask:

```
question: "KB has no `## PR Gates` section for this repo. Backfill from observed gates now?"
header: "KB Backfill"
options:
  - label: "Yes — write minimal section"
    description: "Append a `## PR Gates` table to the KB file using this run's gate names + workflow paths"
  - label: "No — run /nase:onboard later"
    description: "Skip backfill; record a [KB-TODO] in workspace/tasks/todo.md so /nase:today surfaces it"
```

On **yes**: enumerate `.github/workflows/*.{yml,yaml}` in `{worktree_path}` for `pull_request`-triggered workflows, also run `gh api repos/{owner}/{repo}/branches/{baseRefName}/protection --jq '((.required_status_checks.contexts // []) + ((.required_status_checks.checks // []) | map(.context))) | .[]'` for the branch-protection required list, then write the section into `workspace/kb/projects/{domain}.md` using `.claude/docs/kb-template.md → ## PR Gates` as the shape. Update the file's `<!-- Last updated -->` marker. This is a workspace write — no external mutation gate needed.

On **no**: append `- [ ] Backfill PR Gates section in workspace/kb/projects/{domain}.md (next /nase:onboard --force)` to `workspace/tasks/todo.md` under `## Scheduled Maintenance`.

Either way, log one line to the daily log (tag: `address-comments`): `PR gates: {observed} observed, {N} failed, {M} fixed, {K} remaining; KB backfill: {yes/no/already-present}`.

## Phase 9: Reply & Resolve Comments

Before any `gh` mutation in this phase, run the GitHub auth account guard snippet from `.claude/docs/external-mutation-policy.md → GitHub auth account guard`.

After push or no-code skip, handle each thread: **reply first, then resolve**.

For each thread, compose the reply body based on its category:
- **accept**: `"Fixed — {brief description of what was changed}."`
- **decline**: the explanation drafted in Phase 6
- **reply-only**: the reply drafted in Phase 6

**Bulk throttle**: apply the shared throttle rule from `.claude/docs/github-queries.md → Resolve Review Threads → Shared throttle rule` whenever the total number of threads to reply to exceeds 30.

Before making any GitHub reply or resolve API call, show the concrete per-thread payload:

- Thread id / comment id
- Category from the final post-Phase-4 map
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

Then execute both API calls in sequence:

```bash
# Step 1: Reply (use the integer comment ID from REST, i.e. `databaseId` if fetched via GraphQL)
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
  --method POST -f body="{reply_body}"

# Step 2: Resolve the thread — use Shape A (single-thread) from
# `.claude/docs/github-queries.md → Resolve Review Threads`.
# threadId is the GraphQL opaque `id`, NOT the integer databaseId.
```

Process `accept` and `reply-only` threads using this pattern (reply + resolve). For `decline` threads: **reply only, do NOT resolve** — the reviewer may want to respond or push back. Resolving a declined thread shuts down the conversation prematurely.

**Category source-of-truth**: use the post-Phase-4 category map — NOT the initial Phase 3c classification. If a thread was reclassified during Phase 4 user override (e.g., decline → accept), it goes into the resolve set here. Confirm by reading the final map once before iterating.

## Phase 9b: Optional Reviewer Ping (Human Reviewers Only)

After replies + resolves succeed, offer to Slack-ping any human reviewers whose comments were addressed. Bots don't need a ping — they don't read Slack and re-reviews from them re-trigger automatically on the next push.

**Step 9b.1 — Filter to human reviewers.** From the threads addressed in Phase 9 (i.e. `accept` + `reply-only`; excluding declined since those threads stay open intentionally), collect the unique `author.login` values of the *first* comment in each thread (the original review comment, not your reply). Drop any login matching a bot pattern:

- Ends with `[bot]` — covers `dependabot[bot]`, `github-actions[bot]`, `claude[bot]`, etc.
- Ends with `-bot`
- Matches one of the known AI-reviewer logins: `copilot-pull-request-reviewer`, `chatgpt-codex-connector`, `codecov-commenter`, `coderabbitai`, `sonarcloud`, `codacy-production`, `claude` (Claude review bot reports `type=User` on `/users/claude`, so the `[bot]`/`-bot` suffix filter misses it)

Also drop the PR author's own login (they don't ping themselves). Use `gh api user --jq .login` once if you don't already know it.

If the remaining set is empty, skip this phase silently — no message to the user.

**Step 9b.2 — Ask whether to draft pings.** For each human reviewer, you have how many threads were addressed (count from Phase 9). Use a single `AskUserQuestion` whose options are the unique human reviewers (up to 3 plus a "skip all" option; if >3, batch into multiple `AskUserQuestion` calls in the same turn):

```
question: "Addressed comments from these reviewers. Draft a Slack ping for any so they know to re-review?"
header: "Re-review ping"
multiSelect: true
options:
  - label: "@{login_1}"
    description: "{N_1} threads addressed"
  - label: "@{login_2}"
    description: "{N_2} threads addressed"
  - label: "None — skip all"
    description: "Don't ping anyone"
```

If the user picks "None — skip all" (or doesn't select any reviewers), skip the rest of this phase.

**Step 9b.3 — Resolve each selected GitHub login to a Slack user.** Use `slack_search_users` with the GitHub login first (it sometimes matches profile fields). If that returns no hits, fetch the GitHub display name via `gh api users/{login} --jq .name` and search Slack with that. For uncommon given names, follow the [feedback_slack-dm-no-name-opener] / `slack-user-search` lesson — bare given name often beats `"{Given} {Surname}"`.

If a Slack user can't be resolved after two tries, surface `"Couldn't resolve {login} on Slack — skipping ping"` and move on.

**Step 9b.4 — Draft (do NOT send) one Slack DM per resolved reviewer.** Use `slack_send_message_draft`. Follow `.claude/docs/slack-draft-style.md`. One short sentence + bare PR URL on its own line (no `<URL|label>` embed, per `feedback_slack-full-url-not-embed`).

Body template:

```
{ping_opener}

{pr_url}
```

Use `ping_opener = "Pushed fixes for your comments on the PR — ready for another look when you get a minute."` when a commit was pushed. If `no_commit=true`, use `ping_opener = "Responded to your comments on the PR — ready for another look when you get a minute."`.

If the same reviewer was addressed across multiple PRs in this run (rare for `address-comments`, which is single-PR scoped), list each URL on its own line and use the plural matching opener: `"Pushed fixes for your comments on these PRs — ready for another look when you get a minute."` when commits were pushed, or `"Responded to your comments on these PRs — ready for another look when you get a minute."` when `no_commit=true`.

After staging each draft, print: `"Slack DM draft staged for @{login} (Slack: {slack_handle}) — review + send manually."`

The user reviews and sends each draft themselves — this skill never sends.

## Phase 10: Learn from this session

If a reviewer suggestion revealed a non-obvious architectural constraint, run `/nase:kb-update` with the finding. If it was a general coding lesson, append to `workspace/tasks/lessons.md` under the `code` category — see `.claude/docs/lessons-format.md` for header and body format.

## Phase 11: Cleanup & Report

Remove the worktree (only if one was created — skip if Phase 5 detected in-place path):
```bash
# Only run if worktree_path != repo_path
git -C {repo_path} worktree remove {worktree_path} --force
```

Print summary:

```
PR comments addressed ✓

  PR:              {pr_url}
  Accepted:        {N} threads (code changed)
  Declined:        {N} threads (replied with reasoning)
  Replies:         {N} threads
  Resolved:        {total_resolved} / {total_threads}
  Build/test:      passed (iteration {N})
  Slack pings:     {M} drafts staged for {comma-separated logins}   # omit line if 0

  Commit: {short_sha} — {commit_subject}          # omit if no code changes / no commit
```

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `address-comments`) **before** prompting (ensures the log lands regardless of the user's next choice).
Log: `{repo_name}#{pr_number} — {N} resolved ({M} accepted, {K} declined, {J} replies)`

## Phase 12: Offer Prep-Merge Handoff

Skip this phase if any of: (a) all threads were `decline` (PR still has open conversations the reviewer may push back on), (b) the PR is the user's own and `total_resolved == total_threads` and `Build/test: passed` — natural handoff to prep-merge; otherwise default to prompting so the user decides.

Reason for the prompt: address-comments and prep-merge are the standard back-to-back sequence (fix → resolve → squash → force-push). Auto-running prep-merge is unsafe (it rewrites history) — the user must consent each time. Skipping the prompt forces the user to retype the PR URL.

```
question: "Run /nase:prep-merge on this PR now? {pr_url}"
header: "Prep Merge"
options:
  - label: "Yes — squash + force-push"
    description: "Hand off to /nase:prep-merge {pr_url} immediately"
  - label: "No — I'll handle it"
    description: "Stop here; run prep-merge later when ready"
```

If "Yes": invoke `/nase:prep-merge {pr_url}`.
If "No": stop.

---

## Error Handling

- **Never force-push** — this skill pushes normal commits on top of the existing PR branch.
- **Never modify tests** to make them pass — fix the production code.
- **Reply before resolve** — always post the reply so the reviewer sees the response, then resolve the thread.
- **Partial failure** — if some threads fail to resolve via API, report which ones failed and their thread IDs so the user can resolve manually.
- **Respect reviewer intent** — when in doubt about what a reviewer means, ask the user rather than guessing. A wrong "fix" is worse than asking a question.
