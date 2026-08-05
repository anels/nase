---
name: nase:fsd
description: "Implement and verify a feature or fix through a draft PR. Use for fsd, just do it, run autonomously, fire and forget, or feature/fix handoff."
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

`success_criteria`, `success_criteria_from_design`, `design_constraints`, `canonical_task_spec`, `design_impl_plan`, `design_pr_plan`, `repo_hint_from_design`, `execution_mode`, `worktree`, `worktree_report`, `open_pr`, `tdd_mode`, `topology`, `gate_profile`, `module_inventory`, `branch_name`, `branch_slug`, `work_root`, `kb_path_constraints`, `research_gate_findings`, `task_type`, `principle_order`, `reuse_findings`, `pre_impl_grep_findings`, `qa_round`, `tested_candidate_tree_oid`, `candidate_tree_oid`, `bundle_sha256`, `contract_inventory_sha256`, `quality_action`, `spec_action`, and `approved_candidate_tree_oid`.

## Phase map

| Phase | Owner and load point |
|---|---|
| 0 | This entrypoint: validate input. |
| 1-3 and 3.7 | Read `.claude/docs/fsd-intake-and-setup.md` when entering Phase 1. |
| 3.5-6.1 | Read `.claude/docs/fsd-implementation-loop.md` when entering Phase 3.5. |
| 6.25 and 6.5 | Read `.claude/docs/fsd-delivery-gates.md` at Phase 6.25 and follow the named sections. |
| 7 | This entrypoint plus `commit-push-pattern.md`. |
| 8, 8.5, 8c | The already-loaded `fsd-delivery-gates.md`. |
| 8b | `effort-lifecycle.md -> FSD Update`. |
| 9-10 | This entrypoint owns Phase 9 worktree cleanup; the already-loaded `fsd-delivery-gates.md` owns Phase 10 closeout, closure ledger, report, logging, and error handling. |

## Phase 0: Input Guard

If `$ARGUMENTS` is empty, output `Usage: /nase:fsd <task description or plan>` and stop.

## Phases 1-3.7: Intake and setup

Read `.claude/docs/fsd-intake-and-setup.md` once, then execute its phases in order. It owns effort-doc intake, repo inference, topology, the single batched options prompt, branch/worktree setup, and phase-isolation decomposition.

Before Phase 3.5, confirm that the applicable state above is populated. If phase isolation completes implementation, skip Phase 4 as directed by that document.

## Phases 3.5-6.5: Implementation and final QA

At Phase 3.5, read `.claude/docs/fsd-implementation-loop.md` once. Execute its research, preflight, Direct/Team/TDD implementation, initial build/test loop, simplification, post-edit deterministic gates, final size guard, and candidate bundle rules in order.

At Phase 6.25, read `.claude/docs/fsd-delivery-gates.md`. Run its fresh independent quality review and deterministic reducer, then the independent spec review on the same bundle. Quality and spec share three total QA rounds. A local, reversible, bounded failure is autofixed without asking, then the full finalization chain restarts at Phase 6. Only reducer-approved human blockers or terminal infrastructure/evidence states interrupt the user.

Run the operator preflight in that document before every reducer call. If the preflight finds a malformed inventory, reviewer result, or bundle hash, fix the input and re-request from the provider before calling `reduce`. Once invoked, reducer-input `INVALID` follows the shared state machine and may consume the round.

## Phase 7: Commit & Push

Before committing, conform the commit subject to `gate_profile.commit_format` per `.claude/docs/pr-gates-consumption.md` §3 (documented `type`/`scope` set, no `fixup!`/`squash!`). Pass those constraints into `/nase:improve-commit-message` so the polished subject still clears the repo's commit-lint gate.

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md`. Deviation: use `push -u origin {branch_name}` on first push (sets upstream tracking).

After its explicit-file staging step and before commit, assert the real index matches the reviewed tree:

```bash
test "$(git -C {worktree_or_repo} write-tree)" = "$approved_candidate_tree_oid"
```

After the initial commit and again after `/nase:improve-commit-message`, assert:

```bash
test "$(git -C {worktree_or_repo} rev-parse 'HEAD^{tree}')" = "$approved_candidate_tree_oid"
```

Any mismatch invalidates `quality_action`, `spec_action`, and the approved tree. Do not push. Restart at Phase 6 and repeat deterministic gates plus both fresh reviews.

---

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/fsd-delivery-gates.md → Phase 8`. It owns template and gate-profile conformance, the explicit draft-PR confirmation, and the payload-bound GitHub action.

---

## Phase 8.5: Verification Matrix

Follow `.claude/docs/fsd-delivery-gates.md → Phase 8.5`. It owns local execution, evidence recording, and the separately approved PR-body update.

---

## Phase 8b: Effort Doc Update

Follow `.claude/docs/effort-lifecycle.md → FSD Update`. If $ARGUMENTS contains a slug that matches `workspace/efforts/{slug}.md`, stage the lifecycle/status edit with the workspace write guard. If the slug cannot be inferred, skip silently - not every fsd invocation comes from a design doc.

## Phase 8c: KB Update

Follow `.claude/docs/fsd-delivery-gates.md → Phase 8c`. Persist research and
implementation discoveries before cleanup. Keep any team-mode research artifact
with a retained worktree; delete it at the start of Phase 10 when no worktree
was created.

## Phase 9: Cleanup (if worktree = Yes)

Follow `.claude/docs/worktree-pattern.md -> Cleanup` with remote `origin`, remote
ref `refs/heads/{branch_name}`, and the full OID from
`git -C {worktree_path} rev-parse HEAD`.

- Return `3`: keep the retained worktree and both artifacts, report every
  returned path plus up to 20 dirty items and any omitted-item count, and continue
  to the final report as a non-failure cleanup result.
- Return `2`: keep all artifacts, stop, and report the helper error.

Set `worktree_report` for Phase 10 from the actual outcome:

- no worktree flow: `n/a`
- return `3`: `retained at {exact returned worktree path}`

Never summarize return `3` as removed or cleaned up.
For a verified-clean worktree, return `3` is the normal locked-quarantine result.

---

## Phase 10: Report and Error Handling

Follow `.claude/docs/fsd-delivery-gates.md -> Phase 10`. It owns no-worktree
artifact cleanup, the closure ledger, final report, daily log, optional journal,
and terminal error handling.
