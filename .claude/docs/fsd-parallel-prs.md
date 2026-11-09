# FSD Parallel PRs

When `/nase:fsd` is handed an effort doc that plans several PRs, it builds every PR that can start now, together. This file owns the wave: which PRs, how they fan out, what only the main thread may write, and how the results join.

## Contents

- When it applies
- Pick the wave
- Intake once, setup per PR
- Fan out
- Join
- Failure and follow-up

## When it applies

All of these hold:

- Phase 1 matched an effort slug and extracted `design_pr_plan`.
- The plan has more than one PR.

With one remaining PR after the selection below, run the normal single-PR flow for it. When the user's arguments name one PR (`PR2`, `PR-2`, "just the cache one"), the wave is that PR alone, even when others are ready. The user's explicit choice outranks the default, but it does not erase a dependency: a named PR that is not `fsd-ready` is a warning, not a bypass. Say which dependency or blocker it has and ask before starting it.

## Pick the wave

Read the plan with `.claude/docs/pr-plan-readiness.md`. Then:

1. Keep rows with `fsd-ready: yes`.
2. Drop a row whose PR already exists and is open or merged. Check the effort doc's `## Lifecycle` rows and the repo's PRs (`gh pr list --repo {owner}/{repo} --search "{slug}" --state all`). A closed-unmerged PR is not work done: keep the row and say the earlier attempt was closed.
3. Re-check overlap within the same repo. When two kept rows share a `Touches` path and the design did not mark the overlap as safe, keep the earlier PR and defer the later one. Say which path caused it.
4. The rows left are `ready_prs`. Every other row goes to `deferred_prs` with its reason (`waits on PR1`, `blocked: {blocker}`, `overlaps PR2 on {path}`, `already opened: {url}`).

When `ready_prs` is empty and at least one row is `no` only because the plan is silent on `Depends on` or `External blockers`, do not stop with an empty wave: ask once, naming the unproven rows, and run the rows the user marks ready. That answer is the evidence for those rows on this run.

When `ready_prs` is still empty, report every deferred row with its reason and stop before Phase 2.

Run all of `ready_prs`. There is no cap and no "first one only" default: PRs that do not depend on each other have no reason to wait for each other.

## Intake once, setup per PR

- **The effort-doc intake runs once for the wave; freshness, repo inference, KB load, and `gate_profile` run once per distinct repo; the Phase 2 prompt runs once for the whole wave.** State the wave in the derived-values line: `Wave: PR1, PR2 (parallel). Deferred: PR3 (waits on PR1).` The single options prompt covers every PR in the wave. `Yes - draft PR, create without asking again` covers all of them and each PR's Verification-section append; `Yes - draft PR, ask before creating` batches one confirmation for the wave, not one per PR.
- **Q2 is `Yes - worktree` for a wave.** Two PRs cannot share one checkout. When the user answers `No` for a wave of two or more PRs, ask one follow-up: run the wave in per-PR worktrees, or run one PR now and defer the rest. Never run two agents in one checkout.
- **Per PR, Phase 1.5 and Phase 3 run separately.** Each PR gets its own `repo`, `topology`, `branch_name`, `branch_slug`, `work_root`, worktree, `gate_profile`, and `kb_path_constraints`. Derive the branch from the effort slug plus the PR id so names cannot collide.
- **Per PR, `canonical_task_spec`** is that row's `Scope`, plus the `success_criteria` and `design_constraints` that apply to its `Touches` paths, plus the shared options. Criteria that belong to no ready PR stay out of every spec and are reported as owed by the deferred PRs. Do not copy the whole effort doc into each spec.
- **Per PR, `execution_mode`** comes from that PR's own steps in `design_impl_plan`, not from the whole plan.

## Fan out

Spawn one `Agent()` per PR in a single message, so they run concurrently. Use the `worker` role from `.claude/roles.yaml`, passing that role's `model`, `effort`, and `tools` as written there. Each brief carries:

- the effort slug, the PR id, and that PR's `canonical_task_spec`, `design_constraints`, `topology`, `gate_profile`, `branch_name`, `work_root`, and the shared Phase 2 answers
- the instruction to run `/nase:fsd` Phases 3.5 through 8.5 for that PR only, from `.claude/commands/nase/fsd.md`, with every standing invariant and every gate unchanged: green build, lint, tests, and flake checks before push; one fresh candidate review; a draft PR only when `open_pr` is true, created without a second question only when `pr_preauthorized` is true, and otherwise returned as a blocker with the proposed title and body
- the instruction to **skip** Phase 8b, Phase 8c, Phase 9, and Phase 10. Those write shared state or quarantine worktrees; the main thread runs them after the join
- what to return: `pr_id`, `branch_name`, `pr_url` or `none`, `closure_state`, `review_outcome`, `worktree_path`, the branch's `head_sha`, KB discoveries as text, and any human blocker as one question

**Only the main thread writes shared files.** The effort doc, `workspace/tasks/todo.md`, and the daily log are one file each across the whole wave; each repo's KB is one file per repo. Agents writing them concurrently race on the same path, and the workspace write guard's staged files collide. Agents write only inside their own worktree and `workspace/tmp/` paths that carry their `branch_slug`.

An agent cannot ask the user. It returns `blocked` with the question and stops. The main thread batches every returned question into one `AskUserQuestion`, then re-dispatches that PR's agent as a fresh `Agent()` call with its original brief, the state it returned (branch, worktree, phase, candidate tree), and the answer, so it resumes instead of redoing intake.

## Join

When every agent has returned, the main thread:

1. Runs Phase 8b once for the wave, following `.claude/docs/effort-transitions.md → FSD Update` (multi-PR rows).
2. Runs Phase 8c once per distinct repo, from the KB discoveries that repo's agents returned.
3. Runs Phase 9 for each PR's `worktree_path`, following `.claude/commands/nase/fsd.md → Phase 9`, and records its `worktree_report`. A worktree that returned `2` is reported as `n/a (stopped at invalid)`; the other PRs still join.
4. Runs Phase 10 once as a combined report: one line per PR with its `pr_url`, `closure_state`, `review_outcome`, and `worktree_report`, then the `deferred_prs` with reasons. Append one daily-log line per PR, per `.claude/docs/daily-log-format.md`.

## Failure and follow-up

- A failed or blocked PR does not cancel its siblings. Report it with its evidence and leave its worktree retained.
- Do not start a deferred PR in the same run, even when the PR it waited on has opened its draft PR. A dependency is the merge, and merging is a human action.
- Close the report with the next step: when the wave's PRs merge, run `/nase:fsd {slug}` again. The next run finds the deferred PRs that are now ready.
