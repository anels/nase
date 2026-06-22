---
name: nase:address-comments
description: "Act on unresolved PR review comments with per-thread dossiers, code fixes or replies, push when code changed, and resolve approved threads. Use for address comments, fix review comments, handle PR feedback, resolve comments, or respond to reviewer. For first-pass read-only review, use /nase:discuss-pr."
pattern: pipeline
category: Git workflow
---

**Input:** $ARGUMENTS — a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`)

Follows `.claude/docs/external-mutation-policy.md`: code push, `gh pr edit`, replies, thread resolution, and Slack DMs each have their own gate.
Follows `.claude/docs/workspace-write-guard.md` for KB/lesson updates and other durable workspace writes.
Follows `.claude/docs/repo-task-flow.md` for shared repo/PR resolution, fetch + branch state checks, worktree setup, build/test loops, pre-push verification, commit/push, GitHub mutation gates, and cleanup/logging. This command still owns the review-thread dossier and comment-resolution logic below.

---

## Phase 0: Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` minimum Step 0. Use `conversation:` for chat/prompts and `output:` for GitHub text.

## Phase 0.5: Input Guard

Follow the PR input guard in `.claude/docs/pr-input-guard.md` — except on empty input, ask the user for the PR URL using `AskUserQuestion` instead of printing usage.

## Phase 1: Locate Repo & Fetch Context

Parse the PR reference with the shared helper before hand-written extraction:

```bash
python3 .claude/scripts/pr-github-helper.py parse "$PR_URL_OR_ARGUMENTS"
```

If parsing fails, ask for a single GitHub PR URL. Use the helper's normalized `owner`, `repo`, and `number` for every `gh` call.

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

## Phase 2: Fetch Latest & Unresolved Review Threads

Fetch remote refs for the KB-resolved repo:

```bash
git -C {repo_path} fetch origin
```

Use the shared helper for the full unresolved-thread GraphQL query:

```bash
python3 .claude/scripts/pr-github-helper.py review-threads "$PR_URL" --unresolved-only > "$TMPDIR/pr-review-threads.json"
```

Capture `baseRefName`, `headRefName`, `headRepository.nameWithOwner`, and unresolved threads from that JSON. If the helper or `gh` fails, stop with the raw error; do not fall back to an ad hoc query unless you also update `.claude/scripts/pr-github-helper.py` and its tests.

**Same-repo guard:** `headRepository.nameWithOwner` must match `{owner}/{repo}` case-insensitively. If null or different, stop; this command does not handle forks or second repos.

Set `pr_head_ref = origin/{headRefName}` for Phase 3 code reads and Phase 5 worktree setup. Verify it exists before proceeding:

```bash
git -C {repo_path} rev-parse --verify origin/{headRefName}
```

Capture both thread `id` (GraphQL resolve) and `databaseId` (REST reply); they are not interchangeable.

If there are zero unresolved threads: report "No unresolved comments found" and stop.

## Phase 3: Build Dossiers, Evaluate, & Present Plan

Follow `.claude/docs/pr-review-verification.md` and `.claude/docs/ai-code-verification-debt.md` before classifying any thread. Every unresolved thread gets a bounded dossier; high-risk comments get deeper evidence, but low-risk comments still need a short evidence chain.

**Step 3a — Build one dossier per unresolved thread before classification:**

For each thread, collect:

- Full comment chain, including author login, `id`, `databaseId`, path, line, and timestamps.
- Referenced file from PR head: `git -C {repo_path} show {pr_head_ref}:{path}`.
- Base-branch version when the claim depends on diff scope: `git -C {repo_path} show origin/{baseRefName}:{path}`.
- PR diff hunk for the file and nearby changed context.
- KB / repo / Confluence / past-decision constraints that match the file, module, or reviewer premise; if none are found, write `none found`.
- Run `bash .claude/scripts/kb-search.sh mentions:<path> --max-entry-lines 8` for each review-thread file and include hits in the KB/repo constraints; if no hits, write `none found`.
- Caller/dependency impact via `rg`, `git grep`, or language-aware search for referenced symbols, config keys, routes, schema fields, or public contracts.
- Related test/scanner evidence, or the exact missing verification signal.
- Explicit AI provenance per `.claude/docs/ai-code-verification-debt.md → Explicit AI Provenance`; record `none-found` instead of inferring from style.

Use the dossier shape from `.claude/docs/ai-code-verification-debt.md → Comment Dossier Contract`; the bullets above are the concrete evidence sources for its `Evidence checked` block.

**Step 3b — Assign risk before deciding action:**

Use `.claude/docs/ai-code-verification-debt.md → Risk Tiers` as the source of truth. Required labels are `P0 security/data-loss`, `P1 correctness/runtime`, `P2 architecture/maintainability`, and `P3 style/nit`; apply that doc's evidence-depth and AI-provenance escalation rules.

**Step 3c — Evaluate and classify only after dossier evidence exists:**

Apply these gates in order:

0. **Dossier completeness gate**: if code, diff/base, KB/repo, caller impact, and verification evidence are not all checked or explicitly marked missing, classification is blocked.
1. **File-vs-description**: apply `.claude/docs/pr-review-verification.md` §3. If the reviewer's prose does not match the file at the referenced line, decline the suggestion regardless of other factors.
2. **Conditional premise verification**: for suggestions phrased "if X, then change Y", "match the existing pattern A", or "unify on existing behavior", verify X or trace why pattern A exists before classifying. If the premise is wrong or the cited pattern is itself buggy, classify as `decline` and reply with the missed evidence. When the premise concerns a predicate/guard/disabled-state (e.g. "this gate is always true so the window never happens"), trace who *populates* that state at runtime — async effects, child components, fixtures — not just the static expression; a test that force-passes N× proves timing, not that the state window cannot exist. (Declines built on async-seeded state have cost a Codex resolution-gate FAIL on an outward reply.)
3. **Correctness**: Does the suggestion fix an actual bug or prevent a real failure mode? Or is the current code already correct?
4. **Context**: Does the suggestion conflict with API contracts, performance constraints, framework behavior, KB rules, or cross-repo consumers?
5. **Substance vs. style**: Does it meaningfully improve correctness, clarity, testability, or maintainability? Or is it preference-only churn?
6. **Regression risk**: Could accepting introduce a new invariant break, test gap, or rollout risk?

**Classify each thread after the gates:**

| Category | When to use | Action |
|----------|-------------|--------|
| **accept** | Suggestion fixes a real issue, improves correctness, or meaningfully improves clarity/maintainability | Modify the code |
| **decline** | Current code is correct and the suggestion is stylistic, based on incomplete context, or would introduce risk | Reply explaining why the current approach is intentional |
| **reply-only** | Question, discussion point, or acknowledgment needed — no code involved | Write a reply |
| **ask-user** | Business intent, product tradeoff, or hidden repo context is required to decide safely | Ask the exact missing question before Phase 4 |

Accept only when the change measurably improves correctness/clarity. If current code is equally valid, decline with concrete evidence from the dossier. Declines must prove the reviewer premise is false, already addressed, out of PR scope, or lower-value than the risk it introduces.

**Probe for a middle ground before committing to accept-vs-decline.** Before classifying, check whether a scoped third option (partial accept, a narrower fix, or a follow-up issue for out-of-scope asks) better serves the reviewer's intent.

**Step 3d — Pre-confirmation second opinion for risky or uncertain threads:**

Before Phase 4, run an independent read-only verification pass for any thread with `P0`, `P1`, `ask-user`, or uncertainty in the dossier.

- If Codex MCP is loaded, gate per `.claude/docs/codex-review.md → Prerequisite` and use `Mode: comment-dossier`. Pass the review-thread dossier, supporting evidence, and missing-evidence notes; do not pass your intended classification.
- If Codex MCP is unavailable but a fresh-context read-only verifier subagent is available, use the same artifact/contract packet and tag the result `fallback-verify`.
- If neither is available, keep the uncertainty in the dossier and ask the user before executing.

Verifier output is review input, not authority. Reconcile it against the dossier before changing the dossier/action map.

**Step 3e — Resolve unclear threads before Phase 4:**

Ask about any `ask-user` threads using the full dossier. Collect answers, update the dossier, and recompute the dossier/action map before the final plan.

**Step 3f — Present the complete plan:**

```
Found {N} unresolved review threads:

  1. [{risk}] [{path}:{line}] {premise} -> accept
     evidence: {diff/base/head + KB/caller/test summary}
     action: {what_you_plan_to_do}
     verification: {post-change check}
  2. [{risk}] [{path}:{line}] {premise} -> decline
     evidence: {why the premise is false / already fixed / out of scope / risky}
     reply: {draft_reply_summary}
  3. [{risk}] [{path}:{line}] {premise} -> reply-only
     evidence: {why no code change is needed}
     reply: {draft_reply_summary}
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

If user changes classifications, recompute the final per-thread dossier/action map explicitly; Phase 9 uses only this map.

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

Before marking any thread resolved, check `.claude/docs/anti-rationalization.md → /nase:address-comments` — a reply is not a fix.

### For accept threads:

Read referenced file/line range. Apply the planned minimal change using repo standards from KB/`CLAUDE.md`.

If accepted change alters logic/adds path, ensure test coverage; add/update test if needed.

**Multi-case malformed-input checklist:** when a comment names multiple input cases that must land differently ("`null` and `[…]` both look like 'no value'", "string and list both should be malformed", "X / Y / Z should all surface as errors"):
1. Write each named value as a checklist line.
2. Map each value to its code landing site: `malformed` / `read_errors` / `silent` / `kept`.
3. If any reviewer-named value lands in `silent`, the fix is not done. Revise until every named case reaches the intended branch.
4. Verify with a fixture per named case before resolving.

Watch for per-type short-circuits (`if x is None: continue`) before the new gate; they can make a visible check unreachable.

**AI-reviewer assertion-value guard:** apply `.claude/docs/pr-review-verification.md` §1. If the test fails at the suggested expected value, keep the structural improvement (e.g. null-safe cast on the indexer) but restore the original expected value, and note the runtime constraint in the reply. A pattern that survives both null and empty-string is `string.IsNullOrEmpty((string?)token["k"]).Should().BeTrue(...)`.

**Cross-reference identifier audit:** if a reviewer flags an incorrect doc/comment identifier, treat it as a bug class, not one line.

1. Derive the pattern shape from the flagged token — language/doc-style dependent (`Constraint #[0-9]+`, `Foo\.\w+:[0-9]+`, `§[0-9]+(\.[0-9]+)?`, etc. are illustrative, not prescriptive).
2. Grep the whole file: `grep -nE "{pattern}" {file}`.
3. Cross-check every occurrence against the source of truth.
4. Fix all broken instances in the same commit.
5. In the reply, mention the broader audit so the reviewer can spot-check: `"cross-checked every {pattern-name} ref in this file, fixed {N} broken ones (lines {L1}, {L2}, …)"`.

### For decline threads:

Follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-reply`. Draft a direct reply: clear reason, technical context if needed, no defensive tone.

Example: "The current approach handles X because [reason]. Changing to Y would [specific downside]."

**Per-thread concrete evidence rule:** each decline reply must cite evidence for *this* thread:
- dead-style file:line ref (`style removed in {sha} — the rule no longer renders`)
- no-op pre-PR behavior (`{option} was already a no-op in {framework} v{N} — see {link}`)
- design-intent confirmation (`{property} is consumed at {file}:{line}`)
- planning-doc redirect (`captured as follow-up in {Jira link}`)

One reply per declined thread, ≤3 lines each. Do not batch declines under blanket "out of scope" / "scope-creep" wording.

### For reply-only threads:

Follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-reply`. Draft concise, non-defensive reply text.

Hold all replies until Phase 9 (post-push) so the reviewer sees both the code fix and the reply together.

## Phase 7: Build & Test (max 5 iterations)

Get configured build, lint, typecheck, and test commands from the KB file or repo's `CLAUDE.md`.
Follow the build & test iteration loop in `.claude/docs/build-test-loop.md` (max 5 iterations). Every configured gate must pass before proceeding. After all gates pass, apply the Step 2.6 test-presence soft gate against `origin/{pr_branch}` — if an accepted thread changed logic but the diff adds no test, the Phase 6 "ensure test coverage" promise was missed; add the test or record the justification in the reply for that thread.
On success: proceed to Phase 7.5.

## Phase 7.25: Optional Post-Edit CLI Gates

Follow `.claude/docs/cli-tooling.md`. Probe local optional tools with `python3 .claude/scripts/tool-availability.py --group baseline --group ci --group review --group security --format json`, then run only the gates that match files changed while addressing accepted review threads. Missing optional tools are warning-only and must not block replies or thread resolution when the code/test evidence is otherwise adequate.

Classify the current diff against `origin/{pr_branch}`:

- Shell files (`*.sh`, hooks, generated script fixes): run `shellcheck` when available; run `shfmt -d` when available and apply formatting only if it stays within the accepted thread scope.
- GitHub Actions workflows (`.github/workflows/*.{yml,yaml}`): run `actionlint` when available.
- Dockerfiles: run `hadolint` when available and only apply fixes within accepted thread scope.
- Secret-risk changes: run `gitleaks detect --redact --report-format json --report-path -` when available, keeping findings redacted.
- YAML / TOML / XML / HCL / JSON config touched by a reviewer request: use `yq` when available to parse or extract the fields under review.
- Repeated structural edits across multiple files: use `ast-grep` when available to confirm every intended call site was updated.

Scanner/tool output is not reviewer intent by itself. Verify findings against the review thread, diff scope, and source lines before expanding the patch.

## Phase 7.5: Review-Thread Resolution Gate (Codex, with single-model fallback)

Gate per `.claude/docs/codex-review.md → Prerequisite`. If the Codex MCP is not loaded, skip cleanly past only the Codex invocation.

Do NOT skip this gate: replying to and resolving someone's review threads is an outward-facing, hard-to-undo action, so it always gets the single-model fallback check below.

**Single-model fallback (Codex unavailable):** spawn one fresh-context read-only subagent (role `verifier` per `.claude/roles.yaml`, tools: Read/Grep/Glob/Bash — no Edit/Write). Give it ONLY:
- the unresolved review threads from Phase 2 (full comment chains)
- the final post-Phase-4 dossier/action map and drafted replies from Phase 6
- the same diff payload described for the Codex prompt below

Ask it to judge independently, per thread:
- does the diff/reply actually address what the reviewer asked?
- is any decline reply factually wrong?
- does any reply contradict the dossier evidence or omit a required verification note?

Do NOT include your own classification reasoning or expected verdict. It must answer in the same `VERDICT:` shape below; apply the same decision tree. Log `thread-resolution verify: single-model fallback (Codex unavailable)`; overrides use tag `fallback-verify`.

Invoke the Codex MCP with the `comment-resolution` mode contract from `.claude/docs/codex-review.md`:

- `cwd` = `{worktree_path}`
- `prompt` = unresolved review threads from Phase 2, the final post-Phase-4 dossier/action map, drafted replies from Phase 6, and the implementation diff:
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
- If the final post-Phase-4 dossier/action map has any `accept` threads, stop. Report `Accepted thread(s) produced no code diff; fix the code change or reclassify before replying/resolving.` Do not proceed to Phase 9.
- If the final dossier/action map has only `reply-only` / `decline` threads, skip commit and push. Set `no_commit=true`, report `No code changes; proceeding to review replies/resolution only.`, skip Phase 8b, and continue to Phase 9.

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

## Phase 8.7: PR Gates — Skip

Do not read, wait on, or poll PR pipeline gates. After the review-comment fix lands, proceed straight to Phase 9. Do not claim gates are green or CI passed; you have not checked. If CI fails after this push, it surfaces on the PR like any other failure; the user can run another `/nase:address-comments` round or fix it directly.

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

**Category source-of-truth**: use the post-Phase-4 dossier/action map — NOT the initial Phase 3c classification. If a thread was reclassified during Phase 4 user override (e.g., decline → accept), it goes into the resolve set here. Confirm by reading the final dossier/action map once before iterating.

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

**Step 9b.4 — Draft (do NOT send) one Slack DM per resolved reviewer.** Use `slack_send_message_draft`. Follow `.claude/docs/slack-draft-style.md` and `.claude/docs/voice-profile-routing.md` with `surface=slack-dm`. One short sentence + bare PR URL on its own line (no `<URL|label>` embed, per `feedback_slack-full-url-not-embed`).

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

## Phase 12: Offer Next-Step Handoff

Skip this phase if all threads were `decline` (PR still has open conversations the reviewer may push back on). Otherwise prompt so the user can choose the next workflow without retyping the PR URL.

Reason for the prompt: after comments are addressed, the common next steps are prep-merge (squash/finalize) or request-review (find reviewers and stage Slack DM drafts). Do not auto-run either: prep-merge rewrites history, and request-review stages human pings. The user must choose each time.

```
question: "What should I do next for this PR? {pr_url}"
header: "Next Step"
options:
  - label: "Prep merge"
    description: "Invoke /nase:prep-merge {pr_url} to squash/finalize the PR"
  - label: "Request review"
    description: "Invoke /nase:request-review {pr_url} to find reviewers and stage Slack DM drafts"
  - label: "Stop here"
    description: "Do nothing else; leave follow-up for later"
```

If "Prep merge": invoke `/nase:prep-merge {pr_url}`.
If "Request review": invoke `/nase:request-review {pr_url}`.
If "Stop here": stop.

---

## Error Handling

- **Never force-push** — this skill pushes normal commits on top of the existing PR branch.
- **Never modify tests** to make them pass — fix the production code.
- **Reply before resolve** — always post the reply so the reviewer sees the response, then resolve the thread.
- **Partial failure** — if some threads fail to resolve via API, report which ones failed and their thread IDs so the user can resolve manually.
- **Respect reviewer intent** — when in doubt about what a reviewer means, ask the user rather than guessing. A wrong "fix" is worse than asking a question.
