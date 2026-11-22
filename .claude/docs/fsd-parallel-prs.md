# FSD Parallel PRs

When `/nase:fsd` is handed an effort doc that plans several PRs, it builds every PR that can start now, together. A PR that only builds on another plan PR starts now too: it opens stacked on its parent's branch, so it never waits for the parent to merge. This file owns the wave: which PRs, how they fan out in layers, what only the main thread may write, and how the results join.

## Contents

- When it applies
- Pick the wave
- Stacked PRs
- Intake once, setup per PR
- Fan out
- Join
- Native stack link
- Failure and follow-up

## When it applies

All of these hold:

- Phase 1 matched an effort slug and extracted `design_pr_plan`.
- The plan has more than one PR.

With one remaining PR after the selection below, run the normal single-PR flow for it. When the user's arguments name one PR (`PR2`, `PR-2`, "just the cache one"), the wave is that PR alone, even when others are ready. The user's explicit choice outranks the default, but it does not erase a dependency: a named PR that is not `fsd-ready` is a warning, not a bypass. Say which dependency or blocker it has and ask before starting it.

## Pick the wave

Read the plan with `.claude/docs/pr-plan-readiness.md`. Then:

1. Keep rows with `fsd-ready: yes` or `yes - stacks on {PR}`.
2. Drop a row whose PR already exists and is open or merged. Check the effort doc's `## Lifecycle` rows and the repo's PRs (`gh pr list --repo {owner}/{repo} --search "{slug}" --state all --json number,state,url,headRefName,headRefOid`). A closed-unmerged PR is not work done: keep the row and say the earlier attempt was closed. An open PR's `headRefName` and `headRefOid` are the `base_branch` and parent `head_sha` for a kept row that stacks on it (see *Stacked PRs*).
3. Re-check overlap within the same repo. Two kept rows, or a kept row and an open PR of this plan, that share a `Touches` path conflict unless one is stacked on the other, directly or through a chain, or the design marked the overlap as safe. When they conflict, keep the earlier PR and defer the later one. Say which path caused it.
4. The rows left are `ready_prs`. Every other row goes to `deferred_prs` with its reason (`waits on PR1 to merge`, `blocked: {blocker}`, `overlaps PR2 on {path}`, `already opened: {url}`).

When `ready_prs` is empty and at least one row is `no` only because the plan is silent on `Depends on` or `External blockers`, do not stop with an empty wave: ask once, naming the unproven rows, and run the rows the user marks ready. That answer is the evidence for those rows on this run.

When `ready_prs` is still empty, report every deferred row with its reason and stop before Phase 2.

Run all of `ready_prs`. There is no cap and no "first one only" default: PRs that do not depend on each other have no reason to wait for each other.

## Stacked PRs

A row `yes - stacks on {parent}` is built on top of its parent, so the wave runs in layers.

- **Layer 0** is every ready row with `Depends on = none`, plus any row whose stack parent is already an open PR from an earlier run. **Layer N+1** is every row whose parent is in layer N. Rows in one layer run in parallel.
- **`base_branch`** is `{default_branch}` for layer 0 with no open parent. For a stacked PR it is the parent's `branch_name`, read from the parent's agent result, or from the `headRefName` of the earlier run's open PR. That earlier PR counts as reviewed when its `## Lifecycle` row is ticked, because fsd opens a PR only after its review gate. An open PR with no ticked row is not a base: the row is `no - waits on {PR} to merge`. A merged parent is not a base: the row is a plain layer 0 PR on `{default_branch}`.
- **A child starts as soon as its own parent is pushed.** The parent is frozen once its agent returns: nothing pushes to it again in this run. The parent must have returned a pushed `branch_name`, its `head_sha`, and `review_outcome` approved. The child brief carries that `head_sha`, and Phase 3 checks it. A child built on a parent that has not passed its own review would inherit unreviewed code. A slow unrelated PR never holds a child back.
- **The child's review sees only its own layer.** Phase 6.1 takes the merge base against `origin/{base_branch}`, so the bundle holds this PR's diff and not the parent's.
- **A parent that did not push strands its descendants.** Put every descendant in `deferred_prs` with `parent {PR} did not push`, and run the rest of the wave. When `open_pr` is true the parent also needs a `pr_url`, otherwise its descendants are deferred as `parent {PR} has no PR`.

A stack merges bottom-up. fsd never merges anything, so the order stays a human gate (`/nase:prep-merge`, bottom PR first).

## Intake once, setup per PR

- **The effort-doc intake runs once for the wave; freshness, repo inference, KB load, and `gate_profile` run once per distinct repo; the Phase 2 prompt runs once for the whole wave.** State the wave in the derived-values line: `Wave: PR1, PR2 (parallel). Deferred: PR3 (waits on PR1).` The single options prompt covers every PR in the wave. `Yes - draft PR, create without asking` covers all of them and each PR's Verification-section append.
- **Q2 is `Yes - worktree` for a wave.** Two PRs cannot share one checkout. When the user answers `No` for a wave of two or more PRs, ask one follow-up: run the wave in per-PR worktrees, or run one PR now and defer the rest. Never run two agents in one checkout.
- **Per PR, Phase 1.5 and Phase 3 run separately.** Each PR gets its own `repo`, `topology`, `branch_name`, `branch_slug`, `work_root`, worktree, `gate_profile`, and `kb_path_constraints`. Phase 3 names each branch from what that PR changes, never from the effort slug or the PR id, so two PRs in one wave collide only when they change the same thing - and that overlap is the signal to sharpen the scope, not to lean on the `-v2` fallback. A stacked PR also gets its own `base_branch` (see *Stacked PRs*).
- **Per PR, `canonical_task_spec`** is that row's `Scope`, plus the `success_criteria` and `design_constraints` that apply to its `Touches` paths, plus the whole `design_intent` (it is wave-wide) and the `design_validation` lines that exercise its `Touches` paths, plus the shared options. Criteria that belong to no ready PR stay out of every spec and are reported as owed by the deferred PRs. Do not copy the whole effort doc into each spec.
- **Per PR, `execution_mode`** comes from that PR's own steps in `design_impl_plan`, not from the whole plan.

## Fan out

Spawn one `Agent()` per layer 0 PR in a single message, so they run concurrently. Spawn each stacked PR in a later message, as soon as its own parent's agent has returned a pushed branch. Siblings that share a parent go in one message. The Join below runs once, after the last agent. Use the `worker` role from `.claude/roles.yaml`, passing that role's `model`, `effort`, and `tools` as written there. Each spawn uses a **fresh context window** - never reuse an agent across PRs, and never carry one PR's transcript into another. Candidate-review fixes go to a fresh worker too, not the one that implemented the phase. Each brief carries:

- the effort slug, the PR id, and that PR's `canonical_task_spec`, `design_constraints`, `topology`, `gate_profile`, `base_branch`, `branch_name`, `work_root`, and the shared Phase 2 answers; for a stacked PR also the parent's `head_sha`
- the instruction to run `/nase:fsd` Phases 3.5 through 8.5 for that PR only, from `.claude/commands/nase/fsd.md`, with every standing invariant and every gate unchanged: green build, lint, tests, and flake checks before push; one fresh candidate review; a draft PR only when `open_pr` is true, created without a second question only when `pr_preauthorized` is true, and otherwise returned as a blocker with the proposed title and body
- the instruction to **skip** Phase 8.6, Phase 8b, Phase 8c, Phase 9, and Phase 10. Phase 8.6 appends an audit entry to the shared daily log, and the others write shared state or quarantine worktrees; the main thread runs them after the join
- what to return: `pr_id`, `base_branch`, `branch_name`, `pr_url` or `none`, `closure_state`, `review_outcome`, `unrun_required_rows` (the `required` Phase 8.5 rows marked `not run`, or `none`), `verification_in_body`, `worktree_path`, the branch's `head_sha`, KB discoveries as text, and any human blocker as one question, including a Phase 6.1 Step 3 real run that cannot execute

**Only the main thread writes shared files.** The effort doc, `workspace/tasks/todo.md`, and the daily log are one file each across the whole wave; each repo's KB is one file per repo. Agents writing them concurrently race on the same path, and the workspace write guard's staged files collide. Agents write only inside their own worktree and `workspace/tmp/` paths that carry their `branch_slug`.

An agent cannot ask the user. It returns `blocked` with the question and stops. The main thread batches every returned question into one `AskUserQuestion`, then re-dispatches that PR's agent as a fresh `Agent()` call with its original brief, the state it returned (branch, worktree, phase, candidate tree), and the answer, so it resumes instead of redoing intake.

## Join

When every agent has returned, the main thread:

1. Runs Phase 8.6 for each PR that has a `pr_url`, parents before children (layer order), because a stacked PR's Unblocked condition reads its parent's `ready_state`, following `.claude/docs/fsd-pr-delivery.md → Phase 8.6`, with the `closure_state`, `unrun_required_rows`, and `verification_in_body` that PR's agent returned and `{work_root}` set to that PR's worktree. Take `{repo_owner}`, `{repo_name}`, and `{pr_number}` from that PR's `pr_url`. A PR with no `pr_url` gets `ready_state = n/a`. All PRs are already pushed, so their CI runs concurrently. Issue every PR's CI wait as parallel Bash calls in one message, so the join waits once, not once per PR. Only the CI waits run in parallel. After every wait has returned, prepare, authorize, and execute each `gh pr ready` one PR at a time, because only one `external-write-action.py` token may be active. Go parents first. Records each PR's `ready_state`.
2. Runs Phase 8b once for the wave, following `.claude/docs/effort-transitions.md → FSD Update` (multi-PR rows).
3. Runs Phase 8c once per distinct repo, from the KB discoveries that repo's agents returned.
4. Runs Phase 9 for each PR's `worktree_path`, following `.claude/commands/nase/fsd.md → Phase 9`, and records its `worktree_report`. A worktree that returned `2` is reported as `n/a (stopped at invalid)`; the other PRs still join.
5. Runs Phase 10 once as a combined report: one line per PR with its `pr_url`, `closure_state`, `review_outcome`, `ready_state`, and `worktree_report`, then the `deferred_prs` with reasons. Append one daily-log line per PR, per `.claude/docs/daily-log-format.md`.

## Native stack link

fsd reports this step and does not run it. `external-write-action.py` executes with the nase workspace as its working directory, and `gh stack` reads the repo from the working directory and takes no `-R`, so a manifest would act on the wrong repo. The base chain from *Stacked PRs* is already a valid stack of PRs. Linking adds GitHub's native stack view, bottom-up merge handling, and server-side rebase after the bottom PR merges.

When a chain has two or more PRs with a `pr_url`, add one line per chain to the Phase 10 report, bottom PR first:

```
stack link (optional): in a checkout of {repo_owner}/{repo_name}, run: gh stack link --base {default_branch} {bottom_pr_number} {next_pr_number} ...
```

The user runs it with the `!` prefix after confirming `gh extension list` shows `gh-stack` and that the repo has stacked PRs enabled. Set `stack_link = reported`. Never claim `linked`.

## Failure and follow-up

- A failed or blocked PR does not cancel its siblings. Report it with its evidence and leave its worktree retained.
- A PR deferred as `waits on {PR} to merge` does not start in this run, even when that PR has opened its draft PR. Only a stackable dependency lets a PR start before its parent merges. The merge is a human action.
- Close the report with the stack, if any (`PR1 <- PR2 <- PR3`, bottom first, with `stack_link`), and the next step: merge bottom-up, then run `/nase:fsd {slug}` again. The next run finds the deferred PRs that are now ready.
