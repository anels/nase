# FSD Closeout

This reference owns the end of a `/nase:fsd` run: the Phase 10 report, the success-criteria closure ledger, the daily log line, and error handling. Load it at Phase 10.

## Contents

- [Phase 10: Report](#phase-10-report)
- [Error Handling](#error-handling)

## Phase 10: Report

For a no-worktree flow, delete `workspace/tmp/fsd-phases-{branch_slug}.md` and
`workspace/tmp/fsd-research-{branch_slug}.md` before reporting.

**First build the Success-Criteria Ledger.** One row per `success_criteria` item (from Phase 2 / the design doc), each mapped to exactly one:
- `proven` - cite the evidence: a test name, a Phase 8.5 matrix row, or a check run. A green build is not proof a criterion is met.
- `waived` - recorded reason.
- `blocked` - named blocker.

Derive `closure_state`:
- `done` - every required criterion is `proven`; the review returned `PROCEED` for the final candidate and bundle; the staged and committed trees equal `approved_candidate_tree_oid`; and final command evidence is newer than the last modification.
  - `review_outcome = not-run` fails this by definition, since there is no `PROCEED` and no `approved_candidate_tree_oid`. Such a run is at best `conditional`.
- `conditional` - every required criterion is `proven` or `waived`, with waiver reasons named.
- `not-closed` - any required criterion is `blocked` or unproven.

Never print `done ✓` when a criterion or final QA condition is unproven. If `success_criteria` = "Manual verify" (no explicit criteria), skip the ledger, but still require the review and tree-binding conditions. Note only the user-facing verification deferral.

**When the decision carried `disclose_unreviewed_repair`,** the tree that shipped is not the tree that was reviewed. Say so in the report and name the files the repair touched, so whoever reads the PR can weigh it. A repair applied after the only review is defensible; one that goes unmentioned is not.

**When `review_outcome = not-run`,** nothing was reviewed at all, which is the wider version of the same problem. The report says so, names the provider and what came back, and states which deterministic gates did pass - the build, the suite against its baseline, the lint and format gates, the flake evidence - because those are the whole basis for shipping in that case and the reader deserves to see the actual basis rather than infer it. Point at the retained candidate artifacts too. `disclose_unreviewed_repair` and `not-run` can both be set; report both rather than letting the larger one absorb the smaller. In the summary below, `Candidate` carries `tested_candidate_tree_oid`, `Reviewed` reads `not reviewed`, and `Review` names the provider and what came back rather than an action the reducer never returned.

Print a concise summary:

```
FSD {done ✓ | conditional ⚠ | not-closed ✗}

  Repo:        {repo_name}
  Branch:      {branch_name}
  Test iters:  {N} (passed on iteration N)
  Candidate:   {approved_candidate_tree_oid}
  Reviewed:    {reviewed_candidate_tree_oid} - append "(repaired after review, unreviewed)" when disclose_unreviewed_repair
  Bundle SHA:  {bundle_sha256}
  Review:      {review_action} - note the retry or context refill when the pass used one
  Tests:       {focused and canonical command evidence}
  QA fixes:    {P0/P1 auto-fixed count}; {deferred count} deferred
  Context:     {context batch count}
  QA blocker:  {infrastructure/evidence blocker or "none"}
  PR:          {PR URL} - or "not opened"
  Worktree:    {worktree_report}

Criteria: - omit block if "Manual verify"
  - {criterion} - proven: {evidence}
  - {criterion} - waived: {reason} - or blocked: {blocker}

Verification before promote (full matrix appended to PR body):
  🔥 Critical:  {critical layer label} - {why} - omit if no critical row
  Caveat:      {coverage caveat} - omit if none
  Required:    {list required rows by short label}
  Recommended: {list recommended rows by short label} - omit if none

Next: open the draft PR, run the Verification matrix, then promote to "ready for review".
```

If Phase 8.5 produced no rows (pure docs / comments change), omit the entire "Verification before promote" block.

If the Phase 1 gate-profile load used the live-fetch fallback, add the stale-KB note from `.claude/docs/pr-gates-consumption.md` §2 (`Run /nase:onboard {repo} to persist`).

Append to the daily log following `.claude/docs/daily-log-format.md` (tag: `fsd`; add `large-diff` too if Phase 6.1 marked it).
Log: `{one-line task summary} -> \`{branch_name}\` [{PR URL or "no PR"}]`

If the run had a surprise/non-obvious win (novel approach, avoided near-miss, build iters > 1, ambiguous requirement resolved), append to `workspace/journals/{YYYY-MM-DD}.md`:

```
### fsd: {one-line task summary}
- **Approach**: {Direct / Team / Phase-isolated} - {why it fit this task}
- **What worked**: {key decision or technique that made implementation smooth}
- **Build iters**: {N}/5
- **Gotchas**: {any surprise or near-miss}
```

Skip failed or routine no-surprise runs; routine wins dilute downstream skill-optimization signal.

## Error Handling

<error_handling>

- **Continue after Phase 2** - ordinary build, test, quality, and spec failures are automatically repaired and reverified. Ask only for an approved human blocker, the existing external mutation gates, >1500-line scope choice, or secret uncertainty.
- **Protected branches** - never commit directly to `main`, `master`, `develop`, or `release/*`. FSD always works on a feature branch.
- **Worktree path** - always take it from `.claude/docs/worktree-pattern.md -> Naming Convention` (`$HOME/.nase-worktrees/{repo_name}-{suffix}`). Never create it inside the repo, which causes git nesting issues, and never under `/tmp`, which the OS sweeps.
- **Secrets** - if unsure about a file during the staging scan, stop and ask rather than committing and reverting later.
- **Test loop bound** - 5 cumulative iterations is a hard cap and the review pass does not reset it. Exhaust automatic repairs before surfacing an evidence or infrastructure terminal state.
- **PR is always draft** - FSD never opens a ready-for-review PR. Promotion is a human decision.

</error_handling>
