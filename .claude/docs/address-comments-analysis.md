# Address Comments Analysis

Read this file only when /nase:address-comments enters Phases 1-4. It owns PR resolution, bounded dossiers, evidence-backed classification, and the user execution checkpoint. Return the final dossier/action map to the command entrypoint.

## Phase 1: Locate Repo & Fetch Context

Parse the PR reference with the shared helper before hand-written extraction:

```bash
python3 .claude/scripts/pr-github-helper.py parse "$PR_URL_OR_ARGUMENTS"
```

If parsing fails, ask for a single GitHub PR URL. Use the helper's normalized `owner`, `repo`, and `number` for every `gh` call.

Resolve the single local repo from the PR URL and load its KB file - see `.claude/docs/repo-resolution.md` (Part 1 + Part 2).

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

**Load the PR gate profile.** Follow `.claude/docs/pr-gates-consumption.md` §1–2 to read the repo's `## PR Gates` KB section (with the live-fetch fallback when stale/empty) into `gate_profile`. Phases 8 and 8b use it so the commit subject and any PR-body restructure satisfy the repo's commit-lint and PR-description gates.

## Phase 2: Fetch Latest & Unresolved Review Threads

Fetch remote refs for the KB-resolved repo:

```bash
git -C {repo_path} fetch origin
```

Use the shared helper for the full unresolved-thread GraphQL query:

```bash
python3 .claude/scripts/pr-github-helper.py comment-dossiers "$PR_URL" --local-repo "{repo_path}" --unresolved-only > "$TMPDIR/pr-comment-dossiers-{owner}-{repo}-{number}.json"
```

Use a **PR-unique** dossier filename (`{owner}-{repo}-{number}`) - `$TMPDIR` is a shared per-user dir on macOS, and a concurrent nase session running this helper for a different PR can clobber a fixed `pr-comment-dossiers.json` between write and re-read, silently loading the wrong PR's threads.

Capture `baseRefName`, `headRefName`, `headRepository.nameWithOwner`, and unresolved thread dossiers from that JSON. If the helper or `gh` fails, stop with the raw error; do not fall back to an ad hoc query unless you also update `.claude/scripts/pr-github-helper.py` and its tests.

**Same-repo guard:** `headRepository.nameWithOwner` must match `{owner}/{repo}` case-insensitively. If null or different, stop; this command does not handle forks or second repos.

Set `pr_head_ref = origin/{headRefName}` for Phase 3 code reads and Phase 5 worktree setup. Verify it exists before proceeding:

```bash
git -C {repo_path} rev-parse --verify origin/{headRefName}
```

Capture both thread `id` (GraphQL resolve) and `databaseId` (REST reply); they are not interchangeable.

If there are zero unresolved threads: report "No unresolved comments found" and stop.

## Phase 3: Build Dossiers, Evaluate, & Present Plan

Follow `.claude/docs/pr-review-verification.md` and `.claude/docs/ai-code-verification-debt.md` before classifying any thread. Every unresolved thread gets a bounded dossier; high-risk comments get deeper evidence, but low-risk comments still need a short evidence chain.

**Step 3a - Build one dossier per unresolved thread before classification:**

Use `threads[]` from `$TMPDIR/pr-comment-dossiers-{owner}-{repo}-{number}.json` as the baseline dossier: comment chain, `id`/`databaseId`, path/line, head/base excerpts, diff availability, and KB mentions are already bounded there. Before trusting a re-read of this file, re-assert `headRefName` and `headRepository.nameWithOwner` still match the target `{owner}/{repo}` (the Phase 2 same-repo guard); if they differ, stop - the file was clobbered by a concurrent session. The helper uses the same `mentions:<path>` lookup shape as the older manual pass.

For each thread, add only the evidence the helper cannot know:

- Caller/dependency impact via `rg`, `git grep`, or language-aware search for referenced symbols, config keys, routes, schema fields, or public contracts.
- Related test/scanner evidence, or the exact missing verification signal.
- Explicit AI provenance per `.claude/docs/ai-code-verification-debt.md → Explicit AI Provenance`; record `none-found` instead of inferring from style.

Use the dossier shape from `.claude/docs/ai-code-verification-debt.md → Comment Dossier Contract`; do not re-fetch full files or full diffs unless the bounded excerpt is insufficient for a specific thread. Keep this investigation **diff-first** per `.claude/docs/pr-review-verification.md` §11: the bounded dossier is your diff anchor - narrow with `rg`/`git grep` from the changed symbol before reading, widen only to a contract the diff evidences (cite the diff→widen link), and on a failed search retry once with the changed symbol/path, then mark evidence-missing rather than guessing neighboring paths. Before classifying, run the **Trace-shape self-check** (`.claude/docs/pr-review-verification.md` §12) on your own dossier-building investigation - narrowed? batched? diff-anchored? recovered without guessing? - and treat evidence from a widen-first / path-guessing trace as WEAK, re-verifying before it supports an accept/decline.

**Step 3b - Assign risk before deciding action:**

Use `.claude/docs/ai-code-verification-debt.md → Risk Tiers` as the source of truth. Required labels are `P0 security/data-loss`, `P1 correctness/runtime`, `P2 architecture/maintainability`, and `P3 style/nit`; apply that doc's evidence-depth and AI-provenance escalation rules.

**Step 3c - Evaluate and classify only after dossier evidence exists:**

Apply these gates in order:

0. **Dossier completeness gate**: if code, diff/base, KB/repo, caller impact, and verification evidence are not all checked or explicitly marked missing, classification is blocked.
1. **File-vs-description**: apply `.claude/docs/pr-review-verification.md` §3. If the reviewer's prose does not match the file at the referenced line, decline the suggestion regardless of other factors.
2. **Conditional premise verification**: for suggestions phrased "if X, then change Y", "match the existing pattern A", or "unify on existing behavior", verify X or trace why pattern A exists before classifying. If the premise is wrong or the cited pattern is itself buggy, classify as `decline` and reply with the missed evidence. When the premise concerns a predicate/guard/disabled-state (e.g. "this gate is always true so the window never happens"), trace who *populates* that state at runtime - async effects, child components, fixtures - not just the static expression; a test that force-passes N× proves timing, not that the state window cannot exist. (Declines built on async-seeded state have cost a Codex resolution-gate FAIL on an outward reply.)
3. **Correctness**: Does the suggestion fix an actual bug or prevent a real failure mode? Or is the current code already correct?
4. **Context**: Does the suggestion conflict with API contracts, performance constraints, framework behavior, KB rules, or cross-repo consumers?
5. **Substance vs. style**: Does it meaningfully improve correctness, clarity, testability, or maintainability? Or is it preference-only churn?
6. **Regression risk**: Could accepting introduce a new invariant break, test gap, or rollout risk?

**Classify each thread after the gates:**

| Category | When to use | Action |
|----------|-------------|--------|
| **accept** | Suggestion fixes a real issue, improves correctness, or meaningfully improves clarity/maintainability | Modify the code |
| **decline** | Current code is correct and the suggestion is stylistic, based on incomplete context, or would introduce risk | Reply explaining why the current approach is intentional |
| **reply-only** | Question, discussion point, or acknowledgment needed - no code involved | Write a reply |
| **ask-user** | Business intent, product tradeoff, or hidden repo context is required to decide safely | Ask the exact missing question before Phase 4 |

Accept only when the change measurably improves correctness/clarity. If current code is equally valid, decline with concrete evidence from the dossier. Declines must prove the reviewer premise is false, already addressed, out of PR scope, or lower-value than the risk it introduces.

**Probe for a middle ground before committing to accept-vs-decline.** Before classifying, check whether a scoped third option (partial accept, a narrower fix, or a follow-up issue for out-of-scope asks) better serves the reviewer's intent.

**Step 3d - Pre-confirmation second opinion for risky or uncertain threads:**

Before Phase 4, run an independent read-only verification pass for any thread with `P0`, `P1`, `ask-user`, or uncertainty in the dossier.

- If Codex MCP is loaded, gate per `.claude/docs/codex-review.md → Prerequisite` and use `Mode: comment-dossier`. Pass the review-thread dossier, supporting evidence, and missing-evidence notes; do not pass your intended classification.
- If Codex MCP is unavailable but a fresh-context read-only verifier subagent is available, use the same artifact/contract packet and tag the result `fallback-verify`.
- If neither is available, keep the uncertainty in the dossier and ask the user before executing.

Verifier output is review input, not authority. Reconcile it against the dossier before changing the dossier/action map.

**Step 3e - Resolve unclear threads before Phase 4:**

Ask about any `ask-user` threads using the full dossier. Collect answers, update the dossier, and recompute the dossier/action map before the final plan.

**Step 3f - Present the complete plan:**

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
