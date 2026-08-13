# FSD Implementation Loop

## Contents

- Engineering Excellence Bar
- Phase 3.5: Research Gate (external dependencies only)
- Phase 3.6: Implementation Preflight (all execution modes)
- Phase 4: Implement (TDD - Red → Green → Refactor)
- Phase 5: Initial Build & Test Loop (shared max 5 iterations)
- Phase 6: Simplify
- Phase 6.1: Post-Edit Deterministic Gates and Candidate Bundle

Read this file only when /nase:fsd enters Phases 3.5-6.1. It owns research, implementation preflight, implementation, build/test, simplification, final CLI checks, diff sizing, and candidate creation.

## Engineering Excellence Bar

This workspace holds a high bar for the health of the tree we push. Three signals are **non-negotiable before push** - build/lint green, the full test suite green, and zero flaky tests - and they hold *regardless of whether this effort caused the problem*. A red or flaky gate you encounter is yours to fix the moment you see it; "not caused by my change" explains the failure, it does not license leaving it broken. Pushing on top of a known-red or flaky suite erodes the suite for everyone and hides the next real regression.

This is the one sanctioned exception to `CLAUDE.md`'s "while we're at it" rejection - and it is narrow: it covers **lint errors, test failures, and test flakiness only**, never general drive-by refactors.

**Attribute, then fix - both, not either:**
- First attribute. Is this a regression my diff introduced, or pre-existing / upstream? Per `feedback_ci-unrelated-test-check-develop-first.md`, run `git log --since='48 hours ago' origin/{default_branch} -- <test-path>` and rebase onto current default before debugging. Attribution tells you *what kind* of failure it is; it never tells you to skip the fix.
- A regression you introduced → fix inline; it is part of this change.
- Pre-existing / upstream that survives the rebase → still fix it. **Default: fix inline in this branch and call it out in the Phase 10 report.** Isolate into a separate commit/PR (or escalate to the owning team) *only* when the fix crosses a repo or owner boundary, or would materially balloon the diff past the Phase 6.1 guardrail - but never leave the gate red to keep the diff small.

**Flakiness is a defect, not noise.** A test that passes only on re-run is broken - fix the root cause (test isolation, async/timing, shared state). Do not paper over it with retries, sleeps, or a `cy.wait` on a deduped fetch (`feedback_swr-cywait-alias-flake.md`) - that deepens the flake. If the true fix is genuinely out of scope for this branch, quarantine the test explicitly (skip + a tracked follow-up), never re-run until it happens to go green.

## Phase 3.5: Research Gate (external dependencies only)

Before code, check whether the task depends on external APIs, libraries, frameworks, SDKs, CLIs, services, or platform behavior. KB and `CLAUDE.md` can satisfy familiar repo patterns, but not current external facts.

1. **Scan** the task description ($ARGUMENTS) for library names, API references, SDK mentions, or framework-specific terms
2. **Pin version** when possible from manifests, lockfiles, SDK config, or service tier/config
3. **Decision**:
   - If task is purely internal code changes with no external dependencies → **skip**
   - If external behavior is familiar and not version-sensitive → use KB/`CLAUDE.md` as context; no web research required
   - If unfamiliar, version-sensitive, dependency-bump, breaking-change, deprecation/EOL, or behavior is in doubt → run `.claude/docs/design-research.md → Part A: External Research`
     - Prefer that source ladder: `ms-learn` / `context7`, then official docs, pinned source/changelog, then issue trackers
     - Extract: method signatures, required parameters, return types, version constraints, and common pitfalls
     - Hold this context for Phase 4 - do not write to KB yet (Phase 8c handles that)

**Track findings for KB:** always record `research_gate_findings`:
```
research_gate_findings:
  - {LibraryName}: key method signatures, required params, return types, pitfalls, doc URL
```
Record findings even when obvious to avoid re-researching.

Direct / phase-isolated: keep findings in context. Team: also write the same block to `workspace/tmp/fsd-research-{branch_slug}.md` for Phase 8c and subagent prompts.

---

## Phase 3.6: Implementation Preflight (all execution modes)

Read repo `CLAUDE.md` and relevant KB architecture before coding.

**Classify task type and pick your principle ordering** per `.claude/docs/design-principles.md` (canonical framework + the 4 dynamic orderings):

| Context | Examples | Ordering |
|---------|----------|----------|
| Architecture / requirements analysis | system redesign, new service, cross-cutting concern | First Principles → YAGNI → KISS → SOLID → DRY |
| New feature / incremental development | adding an endpoint, extending a handler, new config option | YAGNI → KISS → SOLID → DRY → First Principles |
| Small function / utility | helper, formatter, parser, extension method | KISS → DRY → YAGNI → SOLID → First Principles |
| Complex business component / OOP modelling | domain entity, stateful service, multi-class hierarchy | First Principles → SOLID → YAGNI → KISS → DRY |

Store `task_type` and the full `principle_order`. Apply the **lead** principle during Green (implement only what it requires) and walk the **full order** during Refactor - see Phase 4.

**Complexity self-check:** if a senior engineer would call it overcomplicated, simplify first. Signals: single-implementor abstraction, single-value config, impossible-error handling, >3 indirection layers.

**DRY scan:** Grep overlapping utilities/helpers/patterns; reuse or extend before creating. Store `reuse_findings`.

**Pre-implementation greps:** Follow `.claude/docs/fsd-pre-impl-greps.md` when applicable to the task type. Store `pre_impl_grep_findings`; if skipped, record why.

Carry `task_type`, `principle_order`, `reuse_findings`, and `pre_impl_grep_findings` into Team, Direct, and phase-isolation prompts/state.

---

## Phase 4: Implement (TDD - Red → Green → Refactor)

Use the `task_type`, `principle_order`, `reuse_findings`, and `pre_impl_grep_findings` captured in Phase 3.6, plus `design_constraints` and `success_criteria_from_design` from Phase 1 when present - implementation must satisfy the design's constraints or stop and report the conflict, never silently diverge. Do not re-run the preflight unless the implementation scope changed.
If `design_pr_plan` exists, preserve it unless the diff-size hard gate, repo boundary, release boundary, or a reviewer-owner boundary clearly forces a split. Implementation phases are not PR boundaries by themselves.

**Comments - write sparingly.** Default to none (`CLAUDE.md → Code Quality`; `workspace/kb/general/clean-code.md`). Add a comment only when the logic is genuinely non-obvious, and then explain the *why* (the invariant, the bug a workaround references) - never restate what the code already says. Comments that narrate the obvious are AI-slop the final quality review will flag.

**If execution mode = Team:**
Invoke `/team` with the task, `task_type`, and `principle_order`. **Each agent prompt MUST include:**
- Configured build/lint/typecheck/test commands; verify every configured gate, and state evidence for skipped gates.
- Final `module_inventory`; grep it before new helpers and require 3+ usages for new abstractions.
- Final `topology` (if any); edit only `affected_files` unless you stop and report back.
- Phase 3.6 `reuse_findings` and `pre_impl_grep_findings`; reuse patterns and preserve surfaced invariants.
- `design_constraints` from Phase 1 (if present); each constraint is binding - report back instead of diverging.
- `design_pr_plan` from Phase 1 (if present); implement toward the target PR count and report before expanding into extra branches/PRs.

If Phase 3.5 wrote `workspace/tmp/fsd-research-{branch_slug}.md`, each Team prompt must tell agents to read it before coding.

After agents finish, immediately run configured gates. Failures count as Phase 5 iteration 1.

**If execution mode = Direct - follow Red → Green → Refactor in vertical slices:**

**If tdd_mode = true (Q4=Yes) - strict TDD gates are MANDATORY, not advisory:**

| Gate | Requirement |
|------|-------------|
| **RED** | Run test after writing it. Must fail with assertion failure (not compile error). If it PASSES: STOP - report `"RED gate blocked: test '{test_name}' passed immediately. Behavior may already exist, or test doesn't exercise the right code path."` Do not proceed. |
| **GREEN** | After implementation: test must GREEN + full suite zero new failures. Full suite failures: fix before proceeding - no deferrals. |
| **Refactor** | Re-run full suite after each refactor pass. All green before Phase 5. |
| **Non-testable** | Config/docs/infra → skip RED gate. Mark `[RED skip: non-testable]` in progress notes and proceed directly to implementation. |

**Vertical-slice rule:** one test → one implementation → repeat. Never write all tests up front. See `workspace/kb/general/system-design.md` § Vertical Slices.

For each behavior, do one full Red→Green cycle before starting the next:

1. **Red** - write ONE test for the next behavior (skip for non-testable tasks like configuration, documentation, or infrastructure files):
   - Scan existing test files to understand conventions (location, naming, assertion style, mocking patterns).
   - Write one failing test for observable behavior through the public interface.
   - Run the test. Confirm it fails *for the right reason* (not a compile error - the behavior genuinely doesn't exist yet).

2. **Green** - implement the minimum to pass THIS test:
   - Apply the top-ranked principle from Phase 3.6. Implement only what the current test requires.
   - Write the smallest implementation that makes this single test pass.
   - Re-run the test. It must be green; no existing tests may regress.
   - Loop back to Red for the next behavior. Stop when all planned behaviors are covered.

3. **Refactor** - apply the lead principles from Phase 3.6 once all Red→Green cycles are done:
   - Never refactor while RED. Get to GREEN first.
   - Walk the lead principles: does the code satisfy each? If not, refactor until it does before moving on.
   - Re-run the full test suite after each refactor pass to confirm nothing broke.

---

## Phase 5: Initial Build & Test Loop (shared max 5 iterations)

Get configured build, lint, typecheck, and test commands from KB or `CLAUDE.md`. Follow `.claude/docs/build-test-loop.md`; every configured gate must pass, and missing gates need documented absence. The exit condition is the **Engineering Excellence Bar** above: green build/lint/test and zero flakes, including pre-existing or upstream failures and flakes the run surfaces. Attribute with the default-branch check, then fix. The five-iteration budget is cumulative for the whole FSD run. QA rounds and Phase 6 restarts never reset it.

After all gates pass, apply the Step 2.6 test-presence soft gate against the merge-base diff. Skip it when `tdd_mode = true` because the RED gate already covers it.

If `claudeRunSkills.recipes` from preflight is non-empty and this task changes runtime behavior, prefer Claude Code `/verify` as the first behavioral smoke check after local gates. Record the exact command result as preliminary evidence. If no recipe exists, or the change is docs/config-only, record why `/verify` was not applicable.

**Dependency-bump consumer fixes:** build the full solution, including `*Tests.csproj`, and run affected suites. A single-project or Release-only build is insufficient because CI may stop before compiling test consumers.

On success, proceed to Phase 6.

---

## Phase 6: Simplify

Run `/nase:simplify` on changed files. It uses `code-simplifier` when installed and self-reviews otherwise. Apply improvements before final verification. Do not skip because the change seems small; invoke the skill and let it decide.

Any edit after this point, including an autofix, formatter write, test correction, or commit-tree mismatch, invalidates the candidate bundle and all review results. Restart at Phase 6 so simplification and every final gate run against one final candidate.

---

## Phase 6.1: Post-Edit Deterministic Gates and Candidate Bundle

Run these steps in order. Any candidate write restarts Phase 6. A read-only failure uses the remaining shared build/test iteration budget, fixes the root cause, then restarts Phase 6.

### 1. CLI and formatter gates

Follow `.claude/docs/cli-tooling.md`. Probe optional tools with `python3 .claude/scripts/tool-availability.py --group baseline --group ci --group review --group security --format json`, then run only gates matching changed files:

- shell: `shellcheck` and `shfmt -d` when available
- GitHub Actions: `actionlint`
- Dockerfiles: `hadolint`
- secret-risk changes: redacted `gitleaks detect`
- edited YAML, TOML, XML, HCL, or JSON: parse the exact depended-on fields with an available native or repo tool
- repeated structural edits: `ast-grep` when available
- repo-specific gates named by `gate_profile.lint_gates`

Missing optional tools are warning-only unless the task explicitly depends on their evidence. Verify tool findings against the changed source before editing.

### 2. Freeze the base and tested candidate

Capture the candidate metadata once, then extract both values used by the final bundle:

```bash
BASE=$(git -C {worktree_or_repo} merge-base origin/{default_branch} HEAD)
candidate_metadata=$(python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" --base "$BASE" --candidate-tree-only)
tested_candidate_tree_oid=$(printf '%s\n' "$candidate_metadata" | jq -er '.candidate_tree_oid')
changed_path_count=$(printf '%s\n' "$candidate_metadata" | jq -er '.changed_path_count')
```

This uses the same temporary-index algorithm as the final bundle and performs the redacted candidate secret preflight. An unresolved secret match stops before any reviewer payload is written.

### 3. Focused behavioral evidence

Run the smallest regression test for every changed user path or reported bug, plus the original reproduction or strict-TDD RED evidence when available. For a bug fix without captured RED evidence, record the smallest plausible mutation the regression test would reject. Do not delete, weaken, or rewrite an assertion merely to make an existing failing test green. Adding or strengthening tests for the real contract is allowed.

Use scoped mutation, property, or fuzz evidence only when the target repository already configures the tool and the changed risk surface clearly fits it. Never install a new tool for FSD.

### 4. Canonical gates and flake evidence

Rerun the complete build, lint, typecheck, and test command set after the last edit. Then run the repo's documented flake or repeat strategy. Record command, exit code, and a bounded normalized result in canonical JSON. All evidence must come from after the last modification.

### 5. Final diff-size guard

Use the commit base frozen in Step 2 and measure the complete candidate, including untracked text:

```bash
git -C {worktree_or_repo} diff --stat "$BASE" | tail -1
git -C {worktree_or_repo} ls-files --others --exclude-standard
```

`total_lines_changed` is tracked insertions plus deletions plus lines in untracked text. List binary untracked files without counting their lines.

| Bucket | Action |
|---|---|
| <= 100 | Proceed silently. |
| 101-250 | Report the advisory and continue. |
| 251-500 | Report the caution with `git diff --stat` and continue. |
| 501-1500 | Report strong caution, continue only for one coherent design slice, and add `large-diff` to Phase 10. |
| > 1500 | Preserve the existing explicit human gate: show the stat and ask whether to split, proceed as one PR, or show the file list. |

### 6. Freeze inventory and build the candidate bundle

Build `canonical_task_spec` from the original task plus every Phase 2/design success criterion and constraint. Derive a non-empty fixed inventory from that complete source as canonical JSON with `ref`, `id`, and exact `summary` for every requirement. Write command evidence with exact keys `candidate_tree_oid` and `commands`; every command record has `command`, zero `exit_code`, and bounded `summary`. Bind it to `tested_candidate_tree_oid`.

Resolve the candidate tree again and require exact equality with `tested_candidate_tree_oid`. A test, build, formatter, or tool that changed candidate content invalidates its own evidence; restart Phase 6. Keep inventory, evidence, result, state, and bundle under `workspace/tmp/`, outside the target repository.

```bash
python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" \
  --base "$BASE" \
  --task "$canonical_task_spec" \
  --inventory-file "{inventory_json}" \
  --evidence-file "{command_evidence_json}" \
  --max-files "$changed_path_count" \
  --reviewer-identity-output "{nase_workspace}/workspace/tmp/fsd-qa-{branch_slug}-r{qa_round}-identity.json" \
  --output "{nase_workspace}/workspace/tmp/fsd-qa-{branch_slug}-r{qa_round}.md"
```

Use `changed_path_count` from Step 2 as a safe upper bound. The helper rejects stale evidence, secret-like candidate/evidence content, silently omitted text paths, unbounded binary patches, and oversized output before writing the reviewer artifact. It writes the trusted reviewer identity JSON from the exact completed bundle bytes. Preserve that file outside the candidate bundle and proceed to Phase 6.25 with its immutable `base_oid`, `candidate_tree_oid`, `contract_inventory_sha256`, and `bundle_sha256`.

### Anti-rationalization gate (apply before deciding to skip any sub-step in Phases 5–7)

| Rationalization | Reality |
|---|---|
| "Linting / format warning is a false positive - leave it." | The CI gate doesn't read intent. Either silence with a justified `// noqa: <code>`-style comment or fix it. Re-running CI on a known-red diff burns minutes per cycle. |
| "Failing CI test is flaky / unrelated - I'll re-run it." | Per `feedback_ci-unrelated-test-check-develop-first.md`: first `git log --since='48 hours ago' origin/{default} -- <test-path>` and rebase. That *attributes* the failure - it never excuses it. Per the **Engineering Excellence Bar**, a real failure or a flake gets fixed (root-cause the flake; quarantine + tracked follow-up only when the true fix is out of scope), even if pre-existing. Re-running until green is not a fix. |
| "This comment / TODO is obvious - Phase 6 doesn't need to touch it." | Code/comment drift is the #1 source of stale review-cycles. If the comment no longer matches the post-Phase-4 code, fix it now - the reviewer will catch it and you'll re-push anyway. |
| "Simplifier didn't find anything - diff is already clean." | Verify by reading the simplifier's output, not by inferring from silence. If the run produced no diff, log `simplify: no changes` once and proceed. Skipping the invocation is not equivalent. |
| "I already squashed once today, second prep-merge can reuse." | Per `feedback_prep-merge-upstream-check.md`: `git log origin/{default}..HEAD` first. Base may have shifted; refresh PR body if so. |
| "I'm confident the change is small enough to skip final QA." | Follow `.claude/docs/fsd-delivery-gates.md`; both final reviews are mandatory and bind to the candidate tree. |

---
