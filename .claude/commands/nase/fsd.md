---
name: nase:fsd
description: "End-to-end task workflow from plan to merged-ready draft PR; writes and pushes code after upfront options are confirmed. Use for fsd, full self-develop, just do it, run it autonomously, fire and forget, or feature/fix handoff. For design-only planning, use /nase:design."
argument-hint: "<task description or effort doc>"
pattern: pipeline
category: Design & implementation
sub-patterns: [supervisor]
---

Confirm execution options upfront (team mode, worktree, PR), then continue through implementation until done or blocked.

**Input:** $ARGUMENTS — the task description or implementation plan

Follows `.claude/docs/external-mutation-policy.md`: batch upfront decisions, only create/edit PR when `open_pr=true`, and push via standard commit-push pattern.
Follows `.claude/docs/workspace-write-guard.md` for effort-doc topology/lifecycle updates and any KB writes from research findings.
Follows `.claude/docs/repo-task-flow.md` for shared repo resolution, fetch + branch state checks, worktree setup, build/test loops, pre-push verification, commit/push, GitHub mutation gates, and cleanup/logging. This command still owns FSD planning, implementation, verification scope, and PR creation decisions below.

## Engineering Excellence Bar

This workspace holds a high bar for the health of the tree we push. Three signals are **non-negotiable before push** — build/lint green, the full test suite green, and zero flaky tests — and they hold *regardless of whether this effort caused the problem*. A red or flaky gate you encounter is yours to fix the moment you see it; "not caused by my change" explains the failure, it does not license leaving it broken. Pushing on top of a known-red or flaky suite erodes the suite for everyone and hides the next real regression.

This is the one sanctioned exception to `CLAUDE.md`'s "while we're at it" rejection — and it is narrow: it covers **lint errors, test failures, and test flakiness only**, never general drive-by refactors.

**Attribute, then fix — both, not either:**
- First attribute. Is this a regression my diff introduced, or pre-existing / upstream? Per `feedback_ci-unrelated-test-check-develop-first.md`, run `git log --since='48 hours ago' origin/{default_branch} -- <test-path>` and rebase onto current default before debugging. Attribution tells you *what kind* of failure it is; it never tells you to skip the fix.
- A regression you introduced → fix inline; it is part of this change.
- Pre-existing / upstream that survives the rebase → still fix it. **Default: fix inline in this branch and call it out in the Phase 10 report.** Isolate into a separate commit/PR (or escalate to the owning team) *only* when the fix crosses a repo or owner boundary, or would materially balloon the diff past the Phase 5.5 guardrail — but never leave the gate red to keep the diff small.

**Flakiness is a defect, not noise.** A test that passes only on re-run is broken — fix the root cause (test isolation, async/timing, shared state). Do not paper over it with retries, sleeps, or a `cy.wait` on a deduped fetch (`feedback_swr-cywait-alias-flake.md`) — that deepens the flake. If the true fix is genuinely out of scope for this branch, quarantine the test explicitly (skip + a tracked follow-up), never re-run until it happens to go green.

## Mode Quick-Reference

| Task type | Recommended mode |
|-----------|-----------------|
| Bug fix, small feature, single-area changes | **Direct** — fast, single agent |
| Feature spanning API + data + UI in parallel | **Team** — parallel specialist agents |
| Large feature, multiple code layers, context rot risk | **Direct with Phase isolation** — sequential subagents per layer |
| Unsure | **Direct** — easiest to start; upgrade if context grows |

---

## Phase 0: Input Guard

If $ARGUMENTS is empty: output `Usage: /nase:fsd <task description or plan>` and stop.

## Phase 1: Infer Context (do the homework before asking anything)

Research first; minimize questions. Read `workspace/context.md`, then `workspace/config.md → ## Language` for `output:` language (default English if missing).

**Effort-doc intake (design handoff):** before repo inference, scan `$ARGUMENTS` tokens for a slug matching `workspace/efforts/{slug}.md`. If found, read the effort doc and extract:
- `### Success Criteria` → store as `success_criteria_from_design`. Phase 2 drops Q0 and uses these as the done-definition.
- The latest `## Grill Session → ### Constraints for implementation` block (if any) → store as `design_constraints`. These are evidence-backed decisions — carry them into Phase 4 and every subagent prompt; do not re-litigate them silently.
- `### Implementation Plan` → store as `design_impl_plan` (per-step files/tests/done + dependency graph). Seed Phase 3.7 decomposition from these steps instead of re-deriving them; the design already marked which steps are parallel vs sequential.
- `### PR Plan` → store as `design_pr_plan`. Default to the design PR plan when deciding whether to keep one PR or split; do not create extra PRs just because the implementation has multiple phases.
- `## Topology` (if present) → seed Phase 1.5 with it instead of rebuilding; Phase 3 finalization re-verifies the listed paths still exist in `{work_root}`.
- Frontmatter `repo:` → store as `repo_hint_from_design`; use it as the target repo unless the user explicitly named a different one.

If no slug matches, continue normally — not every fsd run comes from a design doc.

Infer target repo from explicit user text first, then `repo_hint_from_design`, then task keywords/domain/stack. Resolve path and load KB sections for build/run, architecture, constraints, modules/components; see `.claude/docs/repo-resolution.md`. Then fetch latest and collect deterministic preflight context:

```bash
git -C {repo} fetch origin
python3 .claude/scripts/fsd-preflight.py --repo "{repo}" --task "$ARGUMENTS" --kb-file "{kb_file}" --json > "$TMPDIR/fsd-preflight.json"
```

Use `repo`, `moduleInventory`, `kbMentionCandidates`, `toolAvailability`, and `claudeRunSkills` from `$TMPDIR/fsd-preflight.json`. The helper output is bounded and deterministic; do not repeat the git-status/default-branch/tool-availability/run-skill probes by hand unless it failed.

**Load the PR gate profile.** Follow `.claude/docs/pr-gates-consumption.md` §1–2 to read the repo's `## PR Gates` KB section (with the live-fetch fallback when it is stale/empty) into `gate_profile`. This carries the repo's commit-format, PR-title, required-body-section, size, and local-lint rules so Phases 5.25/7/8 satisfy them before push instead of after a CI rejection. Skip only when the repo has no discoverable gates (`gate_profile = generic`).

**If repo cannot be inferred with confidence**, use AskUserQuestion immediately:
```
question: "Which repo should I work in? (I couldn't determine it from the task description)"
header: "Target Repo"
options: one option per repo in context.md, plus "Other — I'll type the path"
```
After the answer, resume Phase 1 for that repo (path, KB, `fsd-preflight`), then proceed to Phase 1.5.

## Phase 1.5: Topology Map (before any code intent is locked in)

For non-trivial tasks, write the affected surface before code intent locks in.

**Skip topology silently when:**
- Single-file edit < 50 LoC delta — skip.
- Docs / comments / README only — skip.
- The repo is unfamiliar but the task is mechanical (rename, bump version, regenerate fixture) — skip.

Otherwise set `topology = needs-work-root`; Phase 3 builds it inside `{work_root}` only.

```
topology:
  affected_files:        # files you expect to touch (grep / Glob first; prefix `?` if uncertain)
    - {path:line range}
  entry_points:          # public functions / handlers / CLI commands the task starts from
    - {symbol @ path:line}
  call_or_dep_relations: # who calls whom in 1-2 hops (use `git grep -nE`/Glob)
    - {caller} → {callee}
  invariants_to_preserve:
    - {invariant — observable behavior, persistence shape, ordering, perf budget, etc.}
  open_questions:        # things the map could not resolve (ask before Phase 4 if material)
    - {question}
```

If topology exists, Phase 4 edits only `affected_files`; add files by re-entering Phase 3 finalization. If skipped, rely on Phase 4 greps.

**Early size signal:** if `affected_files` already exceeds ~15 files, say so now and name the natural split seams — cheaper to scope down before code intent locks in than at the Phase 5.5 diff measurement.

## Phase 2: Upfront Config — single batched AskUserQuestion, then execution

Ask all 5 config decisions in one `AskUserQuestion` `questions` array, then continue until done or blocked.

**If `success_criteria_from_design` exists** (Phase 1 effort-doc intake): drop Q0 from the batched call, set `success_criteria` = the design doc's Success Criteria, and say one line: `Done-definition taken from workspace/efforts/{slug}.md Success Criteria.` Ask only Q1–Q4.

Store answers: `success_criteria` = Q0 answer (or the design doc's criteria), `execution_mode` = Q1 answer, `worktree` = (Q2 = "Yes — worktree"), `open_pr` = (Q3 = "Yes — draft PR"), `tdd_mode` = (Q4 = "Yes").

**Single batched call:**

```
questions:
  - question: "How will we know this is done?"
    header: "Done When"
    multiSelect: false
    options:
      - label: "Tests pass"        , description: "All new + existing tests green (default for code changes)"
      - label: "Manual verify"     , description: "I'll check it myself after you push"
      - label: "Spec the criteria" , description: "I'll describe exactly what done looks like"
  - question: "How should I implement this task?"
    header: "Execution Mode"
    multiSelect: false
    options:
      - label: "Direct"                      , description: "I implement it myself (fast, good for focused tasks)"
      - label: "Team"                        , description: "Spawn coordinated agents in parallel (better for complex multi-area work)"
      - label: "Direct with Phase isolation" , description: "I orchestrate sequential subagents, one per code layer — prevents context rot on large features"
  - question: "Create an isolated git worktree for this task?"
    header: "Isolation"
    multiSelect: false
    options:
      - label: "Yes — worktree" , description: "Recommended: keeps the main branch clean while I work"
      - label: "No"             , description: "Work directly in the repo checkout"
  - question: "Open a draft PR on GitHub when done?"
    header: "Pull Request"
    multiSelect: false
    options:
      - label: "Yes — draft PR" , description: "Push branch and open a draft PR (you review and promote when ready)"
      - label: "No"             , description: "Just commit and push the branch"
  - question: "Enforce strict TDD? (RED→GREEN→Refactor hard gates per slice)"
    header: "Strict TDD"
    multiSelect: false
    options:
      - label: "No"  , description: "Advisory Red→Green→Refactor — current default behavior"
      - label: "Yes" , description: "Hard gates: test must FAIL before any implementation; PASS = stop and report"
```

**Post-answer handling:**
- If Q0 = "Spec the criteria": after the batched call returns, do a single follow-up `AskUserQuestion` with a free-text prompt to collect the criteria. Store as `success_criteria`.
- If Q1 = "Team": ignore the Q4 (Strict TDD) answer — TDD gating is per-direct-mode only.
- Proceed to Phase 3 immediately; do not pause for more input.

---

## Phase 3: Setup

Print: `FSD options captured — starting implementation.`

Generate `{branch_name}` before the worktree decision: lowercase kebab-case, `feat/` or `fix/` prefix, max 50 chars, strip filler words. If `git show-ref refs/heads/{branch_name} refs/remotes/origin/{branch_name}` finds it, append `-v2`, `-v3`, etc. until free.

Derive `{branch_slug}` only for local artifact paths: replace `/` and other characters outside `[A-Za-z0-9._-]` with `-`, trim leading/trailing `-`, and fall back to `branch` if empty. Never use `{branch_slug}` for git refs.

**If worktree = Yes:**
1. Follow the worktree pattern in `.claude/docs/worktree-pattern.md`. Suffix: `fsd`. Ref: `origin/{default_branch}`. Use the branch name generated above.
2. All subsequent git and file operations use absolute paths to `{worktree_path}`. Do NOT use `EnterWorktree` — it creates its own worktree and won't adopt this one.

**If worktree = No:**
- Confirm repo is on the default branch with a clean working tree. If not: stop and tell the user to clean up first (do not force-checkout or stash without asking).
- Create a new branch: `git -C {repo} checkout -b {branch_name} origin/{default_branch}`

Set `{work_root}` = `{worktree_path}` if worktree = Yes, else `{repo}`.

**Finalize `module_inventory`:** keep `moduleInventory` from `$TMPDIR/fsd-preflight.json`; grep inside `{work_root}` only if the helper found too little for this task. Carry into subagent prompts.

**Finalize topology (if `topology = needs-work-root`):** grep/glob inside `{work_root}` only, ≤25 lines. If this came from `/nase:design`, stage and append it to `workspace/efforts/{slug}.md` under `## Topology` using the workspace write guard; otherwise keep it in conversation context for Phase 4.

**KB mentions preflight:** start with `kbMentionCandidates` from `$TMPDIR/fsd-preflight.json`. Once touched paths are known from topology, run `bash .claude/scripts/kb-search.sh mentions:<path> --max-entry-lines 8` only for the expected touched source/config paths (cap at 10; skip generated files unless they are the primary edit target). Store hits as `kb_path_constraints`; if no hits, write `none found`. Carry this into Phase 4 prompts and the implementation constraints.

---

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
     - Hold this context for Phase 4 — do not write to KB yet (Phase 8c handles that)

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

Store `task_type` and the full `principle_order`. Apply the **lead** principle during Green (implement only what it requires) and walk the **full order** during Refactor — see Phase 4.

**Complexity self-check:** if a senior engineer would call it overcomplicated, simplify first. Signals: single-implementor abstraction, single-value config, impossible-error handling, >3 indirection layers.

**DRY scan:** Grep overlapping utilities/helpers/patterns; reuse or extend before creating. Store `reuse_findings`.

**Pre-implementation greps:** Follow `.claude/docs/fsd-pre-impl-greps.md` when applicable to the task type. Store `pre_impl_grep_findings`; if skipped, record why.

Carry `task_type`, `principle_order`, `reuse_findings`, and `pre_impl_grep_findings` into Team, Direct, and phase-isolation prompts/state.

---

## Phase 3.7: Task Decomposition (execution_mode = "Direct with Phase isolation" only)

**Skip entirely** if execution_mode ≠ "Direct with Phase isolation". Jump to Phase 4.

Follow `.claude/docs/fsd-phase-decomposition.md`, passing Phase 3.5 research and Phase 3.6 preflight into the state file and every subagent prompt.

If phase isolation falls back to Direct mode, continue to Phase 4 as Direct. If phase isolation completes successfully, proceed directly to Phase 5; the subagents already implemented the changes, so do not run Phase 4 again.

---

## Phase 4: Implement (TDD — Red → Green → Refactor)

Use the `task_type`, `principle_order`, `reuse_findings`, and `pre_impl_grep_findings` captured in Phase 3.6, plus `design_constraints` and `success_criteria_from_design` from Phase 1 when present — implementation must satisfy the design's constraints or stop and report the conflict, never silently diverge. Do not re-run the preflight unless the implementation scope changed.
If `design_pr_plan` exists, preserve it unless the diff-size hard gate, repo boundary, release boundary, or a reviewer-owner boundary clearly forces a split. Implementation phases are not PR boundaries by themselves.

**Comments — write sparingly.** Default to none (`CLAUDE.md → Code Quality`; `workspace/kb/general/clean-code.md`). Add a comment only when the logic is genuinely non-obvious, and then explain the *why* (the invariant, the bug a workaround references) — never restate what the code already says. Comments that narrate the obvious are AI-slop the Phase 5.75 review will flag.

**If execution mode = Team:**
Invoke `/team` with the task, `task_type`, and `principle_order`. **Each agent prompt MUST include:**
- Configured build/lint/typecheck/test commands; verify every configured gate, and state evidence for skipped gates.
- Final `module_inventory`; grep it before new helpers and require 3+ usages for new abstractions.
- Final `topology` (if any); edit only `affected_files` unless you stop and report back.
- Phase 3.6 `reuse_findings` and `pre_impl_grep_findings`; reuse patterns and preserve surfaced invariants.
- `design_constraints` from Phase 1 (if present); each constraint is binding — report back instead of diverging.
- `design_pr_plan` from Phase 1 (if present); implement toward the target PR count and report before expanding into extra branches/PRs.

If Phase 3.5 wrote `workspace/tmp/fsd-research-{branch_slug}.md`, each Team prompt must tell agents to read it before coding.

After agents finish, immediately run configured gates. Failures count as Phase 5 iteration 1.

**If execution mode = Direct — follow Red → Green → Refactor in vertical slices:**

**If tdd_mode = true (Q4=Yes) — strict TDD gates are MANDATORY, not advisory:**

| Gate | Requirement |
|------|-------------|
| **RED** | Run test after writing it. Must fail with assertion failure (not compile error). If it PASSES: STOP — report `"RED gate blocked: test '{test_name}' passed immediately. Behavior may already exist, or test doesn't exercise the right code path."` Do not proceed. |
| **GREEN** | After implementation: test must GREEN + full suite zero new failures. Full suite failures: fix before proceeding — no deferrals. |
| **Refactor** | Re-run full suite after each refactor pass. All green before Phase 5. |
| **Non-testable** | Config/docs/infra → skip RED gate. Mark `[RED skip: non-testable]` in progress notes and proceed directly to implementation. |

**Vertical-slice rule:** one test → one implementation → repeat. Never write all tests up front. See `workspace/kb/general/system-design.md` § Vertical Slices.

For each behavior, do one full Red→Green cycle before starting the next:

1. **Red** — write ONE test for the next behavior (skip for non-testable tasks like configuration, documentation, or infrastructure files):
   - Scan existing test files to understand conventions (location, naming, assertion style, mocking patterns).
   - Write one failing test for observable behavior through the public interface.
   - Run the test. Confirm it fails *for the right reason* (not a compile error — the behavior genuinely doesn't exist yet).

2. **Green** — implement the minimum to pass THIS test:
   - Apply the top-ranked principle from Phase 3.6. Implement only what the current test requires.
   - Write the smallest implementation that makes this single test pass.
   - Re-run the test. It must be green; no existing tests may regress.
   - Loop back to Red for the next behavior. Stop when all planned behaviors are covered.

3. **Refactor** — apply the lead principles from Phase 3.6 once all Red→Green cycles are done:
   - Never refactor while RED. Get to GREEN first.
   - Walk the lead principles: does the code satisfy each? If not, refactor until it does before moving on.
   - Re-run the full test suite after each refactor pass to confirm nothing broke.

---

## Phase 5: Build & Test Loop (max 5 iterations)

Get configured build/lint/typecheck/test commands from KB or `CLAUDE.md`. Follow `.claude/docs/build-test-loop.md`; every configured gate must pass, and missing gates need documented absence. The exit condition is the **Engineering Excellence Bar** above: green build/lint/test and zero flakes — *including* pre-existing or upstream failures and flakes the run surfaces. Attribute (rebase-check), then fix; do not proceed past a red or flaky gate, and do not burn the 5-iteration budget re-running a flake instead of root-causing it. After all gates pass, apply the Step 2.6 test-presence soft gate against the merge-base diff (skip it when tdd_mode = true — RED gate already covers it).

If `claudeRunSkills.recipes` from preflight is non-empty and this task changes runtime behavior, prefer Claude Code `/verify` as the first behavioral smoke check after local build/test gates. Use the matching `/run` recipe context surfaced by preflight; record `/verify` output as evidence. If no recipe exists, or the change is docs/config-only, keep the existing local gate flow and note that `/verify` was not applicable.

**Dependency-bump consumer fixes:** when fixing a consumer-side break from a breaking dependency bump, build the full solution, including `*Tests.csproj`, and run affected suites. CI stops at the first failing project, so a single-project or Release-only build can hide test-project Moq `Setup`/`Verify`, typed `Callback<>`, and ctor-arity breaks. Compile-clean on the main project is not enough.
On success: proceed to Phase 5.5.

---

## Phase 5.25: Optional Post-Edit CLI Gates

Follow `.claude/docs/cli-tooling.md`. Probe local optional tools with `python3 .claude/scripts/tool-availability.py --group baseline --group ci --group review --group security --format json`, then run only the gates that match changed files. Missing optional tools are warning-only and must not block a working implementation unless the current task explicitly depends on that evidence.

Use the same merge-base command shown in Phase 5.5 to classify changed files:

- Shell files (`*.sh`, hooks, script snippets promoted to files): run `shellcheck` when available; run `shfmt -d` when available and either apply the formatting or report why it was skipped.
- GitHub Actions workflows (`.github/workflows/*.{yml,yaml}`): run `actionlint` when available.
- Dockerfiles: run `hadolint` when available.
- Secret-risk changes: run `gitleaks detect --redact --report-format json --report-path -` when available, keeping any findings redacted.
- YAML / TOML / XML / HCL / JSON config edited by the task: use `yq` when available to parse or extract the exact fields the implementation depends on.
- Repeated structural code edits: use `ast-grep` when available to verify the pattern across all touched call sites.

Treat every optional gate result as a candidate signal. Verify findings against the changed source lines before changing code, and include skipped gates only when the skip affects confidence.

If `gate_profile.lint_gates` (Phase 1) names a repo-specific linter/formatter that maps to a locally runnable command, run it against the changed files here — clearing it now avoids a post-push CI rejection from that exact gate.

---

## Phase 5.5: Diff-Size Guardrail (soft gate)

Measure the diff against the base branch:

```bash
BASE=$(git -C {worktree_or_repo} merge-base origin/{default_branch} HEAD)
git -C {worktree_or_repo} diff --stat "$BASE" | tail -1
git -C {worktree_or_repo} ls-files --others --exclude-standard
```

`total_lines_changed` = tracked insertions + deletions + line count of untracked text files. List binary untracked files but do not count lines.

Reference: Google eng-practices change-sizing — review quality degrades sharply past ~100 lines; >250 lines cuts defect-detection rate roughly in half. See `workspace/kb/general/claude-prompting.md §2026-06-10` for the source-of-truth framing.

| Bucket | Action |
|--------|--------|
| ≤ 100 lines | sweet spot — proceed to Phase 6 silently |
| 101-250 lines | advisory: print one-line: `Diff is {N} lines — past the ~100-line sweet spot; continuing with the design PR plan unless a real split boundary exists.` Continue without asking. |
| 251-500 lines | caution: print `Diff is {N} lines — review quality drops sharply past 250 lines. Continue with the design PR plan; add a review guide rather than splitting unless a split criterion is met.` Render `git diff --stat`. Continue without asking. |
| 501-1500 lines | strong caution: print `Diff is {N} lines — past the 500-line single-PR guidance from Google eng-practices. Keeping one PR is acceptable only when the design PR plan is single-PR and the diff is one coherent vertical slice.` Continue without asking, but **mark `large-diff` for Phase 10 daily log automatically.** |
| > 1500 lines | **pause** — present `git diff --stat` and ask via `AskUserQuestion`: |

```
question: "Diff is {N} lines — past the 1500-line ceiling for a single PR. How to proceed?"
header: "Diff Size"
options:
  - label: "Split into smaller PRs"   , description: "Stop here; I'll guide you on a split plan and you re-run fsd per slice"
  - label: "Proceed — single PR"      , description: "Force-continue. Logged so we can audit how often this happens."
  - label: "Show me the file list"    , description: "Render the per-file breakdown before deciding"
```

On "Split": stop and suggest the minimum PR count from the design PR plan, topology clusters, and `git diff --stat`. On "Proceed": add `large-diff` tag to Phase 10 daily log.

---

## Phase 5.75: Pre-Commit Deep-Dive Self-Review Loop (fresh-context, until clean)

Follow `.claude/docs/fsd-delivery-gates.md → Phase 5.75`. It is mandatory, uses a fresh read-only verifier, and must finish with zero accepted P0/P1 findings before Phase 6.

## Phase 6: Simplify

Run `/nase:simplify` on changed files (after the self-review loop is clean); it uses `code-simplifier` when installed and self-reviews otherwise. Apply improvements before commit. Do not skip because the change seems small; invoke the skill and let it decide.

### Anti-rationalization gate (apply before deciding to skip any sub-step in Phases 5–7)

| Rationalization | Reality |
|---|---|
| "Linting / format warning is a false positive — leave it." | The CI gate doesn't read intent. Either silence with a justified `// noqa: <code>`-style comment or fix it. Re-running CI on a known-red diff burns minutes per cycle. |
| "Failing CI test is flaky / unrelated — I'll re-run it." | Per `feedback_ci-unrelated-test-check-develop-first.md`: first `git log --since='48 hours ago' origin/{default} -- <test-path>` and rebase. That *attributes* the failure — it never excuses it. Per the **Engineering Excellence Bar**, a real failure or a flake gets fixed (root-cause the flake; quarantine + tracked follow-up only when the true fix is out of scope), even if pre-existing. Re-running until green is not a fix. |
| "This comment / TODO is obvious — Phase 6 doesn't need to touch it." | Code/comment drift is the #1 source of stale review-cycles. If the comment no longer matches the post-Phase-4 code, fix it now — the reviewer will catch it and you'll re-push anyway. |
| "Simplifier didn't find anything — diff is already clean." | Verify by reading the simplifier's output, not by inferring from silence. If the run produced no diff, log `simplify: no changes` once and proceed. Skipping the invocation is not equivalent. |
| "I already squashed once today, second prep-merge can reuse." | Per `feedback_prep-merge-upstream-check.md`: `git log origin/{default}..HEAD` first. Base may have shifted; refresh PR body if so. |
| "I'm confident the change is small enough to skip Phase 6.5 verify." | Confidence on novel code correlates poorly with correctness. If Codex MCP is loaded, run Codex; otherwise run the single-model fallback — the cost is bounded, a wrong push isn't. |

---

## Phase 6.5: Pre-Push Verification Gate (Codex, with single-model fallback)

Follow `.claude/docs/fsd-delivery-gates.md → Phase 6.5`. The gate is mandatory: use Codex when available, otherwise the documented fresh-context fallback.

---

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

Follow `.claude/docs/effort-lifecycle.md → FSD Update`. If $ARGUMENTS contains a slug that matches `workspace/efforts/{slug}.md`, stage the lifecycle/status edit with the workspace write guard. If the slug cannot be inferred, skip silently — not every fsd invocation comes from a design doc.

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
- `proven` — cite the evidence: a test name, a Phase 8.5 matrix row, or a check run. A green build is not proof a criterion is met.
- `waived` — recorded reason.
- `blocked` — named blocker.

Derive `closure_state`:
- `done` — every required criterion `proven`.
- `conditional` — every required criterion `proven` or `waived`, with waiver reasons named.
- `not-closed` — any required criterion `blocked` or unproven.

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
  - {criterion} — proven: {evidence}
  - {criterion} — waived: {reason}                   ← or blocked: {blocker}

Verification before promote (full matrix appended to PR body):
  🔥 Critical:  {critical layer label} — {why}     ← omit line if no critical row
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
- **Approach**: {Direct / Team / Phase-isolated} — {why it fit this task}
- **What worked**: {key decision or technique that made implementation smooth}
- **Build iters**: {N}/5
- **Gotchas**: {any surprise or near-miss}
```
Skip failed or routine no-surprise runs; routine wins dilute downstream skill-optimization signal.

---

## Error Handling

<error_handling>

- **Continue after Phase 2** — do not pause unless blocked. For sub-skill prompts, reuse captured options for mechanical choices and Phase 2 preferences for design/scope; ask only when uncovered.
- **Protected branches** — never commit directly to `main`, `master`, `develop`, or `release/*`. FSD always works on a feature branch.
- **Worktree path** — always create it as a sibling to the repo (not inside it) to avoid git nesting issues.
- **Secrets** — if unsure about a file during the staging scan, stop and ask rather than committing and reverting later.
- **Test loop bound** — 5 iterations is a hard cap. Reporting an honest failure is better than an infinite loop.
- **PR is always draft** — FSD never opens a ready-for-review PR. Promotion is a human decision.

</error_handling>
