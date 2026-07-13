---
name: nase:fsd
description: "End-to-end task workflow from plan to merged-ready draft PR; writes and pushes code after upfront options are confirmed. Use for fsd, full self-develop, just do it, run it autonomously, fire and forget, or feature/fix handoff. For design-only planning, use /nase:design."
argument-hint: "<task description or effort doc>"
pattern: pipeline
category: Design & implementation
sub-patterns: [supervisor]
---

Confirm execution options upfront, then continue through implementation until done or blocked.

**Input:** $ARGUMENTS - the task description or implementation plan

Follow:

- `.claude/docs/external-mutation-policy.md` for every external write.
- `.claude/docs/workspace-write-guard.md` for effort, topology, lifecycle, and KB writes.
- `.claude/docs/repo-task-flow.md` for repo resolution, branch/worktree setup, build/test, push, GitHub gates, cleanup, and logging.

**Language preflight (run first):** read `workspace/config.md -> ## Language`. Use `conversation:` for chat and `output:` for commits, PRs, and GitHub text. Default to English when absent and note that once.

## Standing invariants

- Before push, build/lint, the full test suite, and flake checks must be green. Attribute failures, then fix them. The full rule lives in `.claude/docs/fsd-implementation-loop.md -> Engineering Excellence Bar`.
- Never commit directly to `main`, `master`, `develop`, or `release/*`; always use a feature branch.
- A PR is optional but, when requested, is always draft and every PR mutation has its own concrete approval gate.
- Use the design PR plan unless a repo, release, reviewer-owner, or hard diff-size boundary forces a split.
- For touched source/config paths, preserve the KB lookup shape `mentions:<path>`.
- Continue after upfront configuration unless blocked at an explicitly named checkpoint.

## State contract

Preserve these names across phase documents:

`success_criteria`, `success_criteria_from_design`, `design_constraints`, `design_impl_plan`, `design_pr_plan`, `repo_hint_from_design`, `execution_mode`, `worktree`, `open_pr`, `tdd_mode`, `topology`, `gate_profile`, `module_inventory`, `branch_name`, `branch_slug`, `work_root`, `kb_path_constraints`, `research_gate_findings`, `task_type`, `principle_order`, `reuse_findings`, and `pre_impl_grep_findings`.

## Phase map

| Phase | Owner and load point |
|---|---|
| 0 | This entrypoint: validate input. |
| 1-3 and 3.7 | Read `.claude/docs/fsd-intake-and-setup.md` when entering Phase 1. |
| 3.5-6 | Read `.claude/docs/fsd-implementation-loop.md` when entering Phase 3.5. |
| 5.75 and 6.5 | Read `.claude/docs/fsd-delivery-gates.md` at Phase 5.75 and follow the named sections. |
| 7 | This entrypoint plus `commit-push-pattern.md`. |
| 8, 8.5, 8c | The already-loaded `fsd-delivery-gates.md`. |
| 8b | `effort-lifecycle.md -> FSD Update`. |
| 9-10 | This entrypoint: cleanup, closure ledger, report, and logging. |

## Phase 0: Input Guard

If `$ARGUMENTS` is empty, output `Usage: /nase:fsd <task description or plan>` and stop.

## Phases 1-3.7: Intake and setup

Read `.claude/docs/fsd-intake-and-setup.md` once, then execute its phases in order. It owns effort-doc intake, repo inference, topology, the single batched options prompt, branch/worktree setup, and phase-isolation decomposition.

Before Phase 3.5, confirm that the applicable state above is populated. If phase isolation completes implementation, skip Phase 4 as directed by that document.

## Phases 3.5-6: Implementation loop

At Phase 3.5, read `.claude/docs/fsd-implementation-loop.md` once. Execute its research, preflight, Direct/Team/TDD implementation, build/test loop, optional CLI gates, diff guard, and simplification rules in order.

At Phase 5.75, read `.claude/docs/fsd-delivery-gates.md` and run its mandatory fresh-context self-review. Resume Phase 6 only after zero accepted P0/P1 findings. At Phase 6.5, run the mandatory pre-push gate from the same document.

## Phase 7: Commit & Push

Before committing, conform the commit subject to `gate_profile.commit_format` per `.claude/docs/pr-gates-consumption.md` §3 (documented `type`/`scope` set, no `fixup!`/`squash!`). Pass those constraints into `/nase:improve-commit-message` so the polished subject still clears the repo's commit-lint gate.

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md`. Deviation: use `push -u origin {branch_name}` on first push (sets upstream tracking).

---

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/fsd-delivery-gates.md → Phase 8`. It owns template and gate-profile conformance, the explicit draft-PR confirmation, and the payload-bound GitHub action.

---

## Phase 8.5: Verification Matrix

Follow `.claude/docs/fsd-delivery-gates.md → Phase 8`. It owns local execution, evidence recording, and the separately approved PR-body update.

---

## Phase 8b: Effort Doc Update

Follow `.claude/docs/effort-lifecycle.md → FSD Update`. If $ARGUMENTS contains a slug that matches `workspace/efforts/{slug}.md`, stage the lifecycle/status edit with the workspace write guard. If the slug cannot be inferred, skip silently - not every fsd invocation comes from a design doc.

## Phase 8c: KB Update

Follow `.claude/docs/fsd-delivery-gates.md → Phase 8c`. Persist research and implementation discoveries before cleanup, then remove any team-mode research artifact.

## Phase 9: Cleanup (if worktree = Yes)

Remove the worktree (safe since the branch is already pushed):
```bash
git -C {repo} worktree remove {worktree_path} --force
```
Confirm: "Worktree removed."

---

## Phase 10: Report

**First build the Success-Criteria Ledger.** One row per `success_criteria` item (from Phase 2 / the design doc), each mapped to exactly one:
- `proven` - cite the evidence: a test name, a Phase 8.5 matrix row, or a check run. A green build is not proof a criterion is met.
- `waived` - recorded reason.
- `blocked` - named blocker.

Derive `closure_state`:
- `done` - every required criterion `proven`.
- `conditional` - every required criterion `proven` or `waived`, with waiver reasons named.
- `not-closed` - any required criterion `blocked` or unproven.

Never print `done ✓` when a criterion is unproven. If `success_criteria` = "Manual verify" (no explicit criteria), skip the ledger and print `done ✓` as before, noting verification is deferred to the user.

Print a concise summary:
```
FSD {done ✓ | conditional ⚠ | not-closed ✗}

  Repo:        {repo_name}
  Branch:      {branch_name}
  Test iters:  {N} (passed on iteration N)
  PR:          {PR URL}   ← or "not opened"
  Worktree:    cleaned up ← or "n/a"

Criteria:                                            ← omit block if "Manual verify"
  - {criterion} - proven: {evidence}
  - {criterion} - waived: {reason}                   ← or blocked: {blocker}

Verification before promote (full matrix appended to PR body):
  🔥 Critical:  {critical layer label} - {why}     ← omit line if no critical row
  Caveat:      {coverage caveat}                   ← omit line if none
  Required:    {list required rows by short label}
  Recommended: {list recommended rows by short label}  ← omit line if none

Next: open the draft PR, run the Verification matrix, then promote to "ready for review".
```

If Phase 8.5 produced no rows (pure docs / comments change), omit the entire "Verification before promote" block.

If the Phase 1 gate-profile load used the live-fetch fallback, add the stale-KB note from `.claude/docs/pr-gates-consumption.md` §2 (`Run /nase:onboard {repo} to persist`).

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `fsd`; add `large-diff` too if Phase 5.5 marked it).
Log: `{one-line task summary} → \`{branch_name}\` [{PR URL or "no PR"}]`

If the run had a surprise/non-obvious win (novel approach, avoided near-miss, build iters > 1, ambiguous requirement resolved), append to `workspace/journals/{YYYY-MM-DD}.md`:
```
### fsd: {one-line task summary}
- **Approach**: {Direct / Team / Phase-isolated} - {why it fit this task}
- **What worked**: {key decision or technique that made implementation smooth}
- **Build iters**: {N}/5
- **Gotchas**: {any surprise or near-miss}
```
Skip failed or routine no-surprise runs; routine wins dilute downstream skill-optimization signal.

---

## Error Handling

<error_handling>

- **Continue after Phase 2** - do not pause unless blocked. For sub-skill prompts, reuse captured options for mechanical choices and Phase 2 preferences for design/scope; ask only when uncovered.
- **Protected branches** - never commit directly to `main`, `master`, `develop`, or `release/*`. FSD always works on a feature branch.
- **Worktree path** - always create it as a sibling to the repo (not inside it) to avoid git nesting issues.
- **Secrets** - if unsure about a file during the staging scan, stop and ask rather than committing and reverting later.
- **Test loop bound** - 5 iterations is a hard cap. Reporting an honest failure is better than an infinite loop.
- **PR is always draft** - FSD never opens a ready-for-review PR. Promotion is a human decision.

</error_handling>
