---
name: nase:fsd
description: "End-to-end task workflow from plan to merged-ready draft PR; writes and pushes code after upfront options are confirmed. Use for fsd, full self-develop, just do it, run it autonomously, fire and forget, or feature/fix handoff. For design-only planning, use /nase:design."
pattern: pipeline
category: Design & implementation
sub-patterns: [supervisor]
---

Confirm execution options upfront (team mode, worktree, PR), then continue through implementation until done or blocked.

**Input:** $ARGUMENTS — the task description or implementation plan

Follows `.claude/docs/external-mutation-policy.md`: batch upfront decisions, only create/edit PR when `open_pr=true`, and push via standard commit-push pattern.
Follows `.claude/docs/workspace-write-guard.md` for effort-doc topology/lifecycle updates and any KB writes from research findings.
Follows `.claude/docs/repo-task-flow.md` for shared repo resolution, fetch + branch state checks, worktree setup, build/test loops, pre-push verification, commit/push, GitHub mutation gates, and cleanup/logging. This command still owns FSD planning, implementation, verification scope, and PR creation decisions below.

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
- `### Implementation / PR Plan` → store as `design_pr_plan`. Default to the design PR plan when deciding whether to keep one PR or split; do not create extra PRs just because the implementation has multiple phases.
- `## Topology` (if present) → seed Phase 1.5 with it instead of rebuilding; Phase 3 finalization re-verifies the listed paths still exist in `{work_root}`.
- Frontmatter `repo:` → store as `repo_hint_from_design`; use it as the target repo unless the user explicitly named a different one.

If no slug matches, continue normally — not every fsd run comes from a design doc.

Infer target repo from explicit user text first, then `repo_hint_from_design`, then task keywords/domain/stack. Resolve path and load KB sections for build/run, architecture, constraints, modules/components; see `.claude/docs/repo-resolution.md`.

Then fetch latest and collect deterministic preflight context:

```bash
git -C {repo} fetch origin
python3 .claude/scripts/fsd-preflight.py --repo "{repo}" --task "$ARGUMENTS" --kb-file "{kb_file}" --json > "$TMPDIR/fsd-preflight.json"
```

Use `repo`, `moduleInventory`, `kbMentionCandidates`, and `toolAvailability` from `$TMPDIR/fsd-preflight.json`. The helper output is bounded and deterministic; do not repeat the git-status/default-branch/tool-availability probes by hand unless it failed.

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

## Phase 3.5: Research Gate (unfamiliar APIs/libraries only)

Before code, check whether external APIs/libraries/frameworks are not already documented in repo KB or `CLAUDE.md`.

1. **Scan** the task description ($ARGUMENTS) for library names, API references, SDK mentions, or framework-specific terms
2. **Cross-check** against the repo's KB file (loaded in Phase 1) and `CLAUDE.md` for existing coverage
3. **Decision**:
   - If all referenced APIs/libraries are already in KB or CLAUDE.md → **skip** (no overhead for familiar territory)
   - If task is purely internal code changes with no external dependencies → **skip**
   - If task references APIs/libraries NOT in KB → **research gate**:
     - Run WebSearch for official documentation of each unfamiliar API/library
     - WebFetch the most relevant doc page (API reference, getting started, or migration guide)
     - Extract: method signatures, required parameters, return types, common pitfalls
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

**Classify task type and pick your lead principles:**

| Context | Examples | Lead with |
|---------|----------|-----------|
| Architecture / requirements analysis | system redesign, new service, cross-cutting concern | First Principles → SOLID |
| New feature / incremental development | adding an endpoint, extending a handler, new config option | YAGNI → KISS |
| Small function / utility | helper, formatter, parser, extension method | KISS → DRY |
| Complex business component / OOP modelling | domain entity, stateful service, multi-class hierarchy | First Principles → SOLID → DRY |

Store `task_type` and `principle_order`; use them as the design lens.

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

Get configured build/lint/typecheck/test commands from KB or `CLAUDE.md`. Follow `.claude/docs/build-test-loop.md`; every configured gate must pass, and missing gates need documented absence. After all gates pass, apply the Step 2.6 test-presence soft gate against the merge-base diff (skip it when tdd_mode = true — RED gate already covers it).

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

## Phase 6: Simplify

Run `/nase:simplify` on changed files; it uses `code-simplifier` when installed and self-reviews otherwise. Apply improvements before commit.

Do not skip because the change seems small; invoke the skill and let it decide.

### Anti-rationalization gate (apply before deciding to skip any sub-step in Phases 5–7)

| Rationalization | Reality |
|---|---|
| "Linting / format warning is a false positive — leave it." | The CI gate doesn't read intent. Either silence with a justified `// noqa: <code>`-style comment or fix it. Re-running CI on a known-red diff burns minutes per cycle. |
| "Failing CI test is flaky / unrelated — I'll re-run it." | Per `feedback_ci-unrelated-test-check-develop-first.md`: first `git log --since='48 hours ago' origin/{default} -- <test-path>`. Only after confirming upstream stability is "flaky" allowed; otherwise it's your bug. |
| "This comment / TODO is obvious — Phase 6 doesn't need to touch it." | Code/comment drift is the #1 source of stale review-cycles. If the comment no longer matches the post-Phase-4 code, fix it now — the reviewer will catch it and you'll re-push anyway. |
| "Simplifier didn't find anything — diff is already clean." | Verify by reading the simplifier's output, not by inferring from silence. If the run produced no diff, log `simplify: no changes` once and proceed. Skipping the invocation is not equivalent. |
| "I already squashed once today, second prep-merge can reuse." | Per `feedback_prep-merge-upstream-check.md`: `git log origin/{default}..HEAD` first. Base may have shifted; refresh PR body if so. |
| "I'm confident the change is small enough to skip Phase 6.5 verify." | Confidence on novel code correlates poorly with correctness. If Codex MCP is loaded, run Codex; otherwise run the single-model fallback — the cost is bounded, a wrong push isn't. |

---

## Phase 6.5: Pre-Push Verification Gate (Codex, with single-model fallback)

Gate per `.claude/docs/codex-review.md → Prerequisite`. If the Codex MCP is not loaded, skip cleanly past only the Codex invocation.

Do NOT skip this gate: run the single-model fallback below instead. The verification step is mandatory; only the cross-model variant is optional.

If tempted to skip or self-approve, see `.claude/docs/anti-rationalization.md → /nase:fsd`.

**Single-model fallback (Codex unavailable):** spawn one fresh-context read-only subagent (role `verifier` per `.claude/roles.yaml`, tools: Read/Grep/Glob/Bash — no Edit/Write). Give it ONLY:
- the original task spec from `$ARGUMENTS` verbatim (the CONTRACT)
- the verification bundle path (or the merge-base diff) and `{work_root}` (the ARTIFACT)
- the instruction to answer in the exact `VERDICT: PASS | FAIL | NEEDS-HUMAN` shape below

Do NOT include your own assessment, implementation reasoning, or expected verdict. The subagent must judge spec-vs-diff independently, following the same principle as the `discuss-pr` doubt cycle: hand it the artifact and contract, not your conclusion.

Parse its output with the same decision tree as Codex. Log `verify: single-model fallback (Codex unavailable)` and use tag `fallback-verify` instead of `codex-override` for overrides. A fallback PASS is weaker evidence than a cross-model PASS; note that in the Phase 10 report line.

Build the verification bundle per `.claude/docs/codex-verification-bundle.md`:

```bash
BASE=$(git -C {worktree_or_repo} merge-base origin/{default_branch} HEAD)
python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" \
  --base "$BASE" \
  --task "$ARGUMENTS" \
  --output "{nase_workspace}/workspace/tmp/codex-verify-{short_sha}.md"
```

Invoke the Codex MCP with the `verify` mode contract from `.claude/docs/codex-review.md`:

- `cwd` = `{worktree_path}` (or `{repo}` if worktree = No)
- `prompt` = the original task spec from `$ARGUMENTS` verbatim, the bundle path, merge base, changed-file count, and the insufficient-manifest instruction from `.claude/docs/codex-verification-bundle.md`
- `developer-instructions` = the `verify` template verbatim
- `sandbox` = `read-only`

Parse `content`. Expected shape:
```
VERDICT: PASS | FAIL | NEEDS-HUMAN
SPEC ITEMS NOT ADDRESSED: ...
SCOPE CREEP: ...
REASONING: ...
```

**Decision tree:**

- **PASS** → log one line (`Codex verify: PASS`) and proceed to Phase 7. No user prompt.
- **NEEDS-HUMAN** → write the full Codex output next to the bundle as `codex-verify-{short_sha}-result.md`, then present only `VERDICT`, missing context/files, and the top 5 requested follow-ups via `AskUserQuestion`:
  - Q: "Codex flagged ambiguity — proceed to push or revise first?"
  - Options: `Proceed — push anyway` / `Revise — pause for me to look` / `Show me the diff side-by-side first`
  - Honor the user's choice.
- **FAIL** → do NOT push. Write the full Codex output next to the bundle as `codex-verify-{short_sha}-result.md`, then present only `VERDICT`, top 5 failures, and the result path. Ask via `AskUserQuestion`:
  - Q: "Codex says the diff doesn't match the spec. What now?"
  - Options: `Fix it` / `Override — Codex is wrong, push anyway` / `Cancel — abandon this run`
  - On "Fix it": re-enter Phase 3.7 for phase-isolated runs or Phase 4 otherwise, then rerun verifier.
  - On "Override": log reason to daily log with tag `codex-override`.

**Malformed output** (no `VERDICT:` line) → write raw `content` next to the bundle as `codex-verify-{short_sha}-result.md`, treat as `NEEDS-HUMAN`, present a short malformed-output note plus the result path, and ask the user.

If Codex explicitly reports missing context that is available locally, read only those requested files or hunks, update the bundle, and rerun the verifier once. Do not loop beyond one context-completion rerun without asking the user.

Codex reviews the code Claude wrote; do not self-approve in the same active context.

---

## Phase 7: Commit & Push

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md`.
Deviation: use `push -u origin {branch_name}` on first push (sets upstream tracking).

---

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–4) to discover the PR template, draft the description with `surface=github-pr-body`, align the title with the commit subject, and preserve co-authors (relevant in team mode).

Before the `gh pr create` / `gh pr edit` calls below, run the GitHub auth account guard snippet from `.claude/docs/external-mutation-policy.md → GitHub auth account guard`.

Draft the exact PR payload and show it to the user. Gate creation via `AskUserQuestion` immediately before the mutation:

```
question: "Create this draft PR?"
header: "Draft PR"
options:
  - label: "Create draft PR"
    description: "Run gh pr create with the title, body, base, and head shown above"
  - label: "Skip PR create"
    description: "Leave the pushed branch without opening a PR"
```

If skipped, do not call `gh pr create`; report the pushed branch and the command the user can run later.

If approved, run the auth guard and open a draft PR with the approved payload:
```bash
gh pr create \
  --draft \
  --title "{commit_subject_line}" \
  --body "$(cat <<'EOF'
{pr_body_from_template}
EOF
)" \
  --base {default_branch} \
  --head {branch_name} \
  -R {repo_owner}/{repo_name}
```

Report the PR URL.

---

## Phase 8.5: Verification Matrix

Build a verification matrix so the reviewer knows what to run before promoting the draft PR.

Follow `.claude/docs/verification-matrix.md` §1, §2, §3, §5. Skip §4 because fsd is producing the plan. Phase 5 unit tests become the Unit `✅ done` row.

**Execute before rendering:** a matrix fsd only writes is a promise; a matrix fsd partially ran is evidence. Before rendering:
- Attempt every `required` row whose `command` runs locally inside `{work_root}`: local builds, env-var-switched `dotnet run`/`npm start` smoke checks, dry-run commands.
- Attempt the 🔥 critical row above all when it can run locally.
- Record outcomes as `✅ done` with the actual output as evidence.
- Skip rows needing deployment, external environments, or credentials fsd doesn't hold. Mark those `not run by fsd` explicitly; never fabricate.
- If the 🔥 critical row exists and could not be run locally, say so in the Phase 10 report's Critical line.

Skill-specific outputs:

1. **Append to PR body** only if `open_pr = true` and matrix has rows. Show the exact `## Verification` section and gate `gh pr edit` via `AskUserQuestion`:
   ```
   question: "Append this Verification section to the draft PR?"
   header: "PR Verification"
   options:
     - label: "Append verification"
       description: "Run gh pr edit --body-file with the section shown above"
     - label: "Skip PR edit"
       description: "Leave the PR body unchanged; include the matrix only in the final report"
   ```
   If skipped, do not edit the PR body; still surface the matrix in Phase 10. If approved, use:
   ```bash
   gh pr view {pr_number} -R {owner}/{repo} --json body --jq .body > /tmp/fsd-pr-body-{pr_number}.md
   # Append the Verification section to the file, then:
   gh pr edit {pr_number} -R {owner}/{repo} --body-file /tmp/fsd-pr-body-{pr_number}.md
   ```
   Append only; never overwrite. Skip when matrix has no rows.

2. **Surface in Phase 10 report**: pass critical layer and caveat to final report.

3. **No PR**: render the matrix in Phase 10.

---

## Phase 8b: Effort Doc Update

Follow `.claude/docs/effort-lifecycle.md → FSD Update`. If $ARGUMENTS contains a slug that matches `workspace/efforts/{slug}.md`, stage the lifecycle/status edit with the workspace write guard. If the slug cannot be inferred, skip silently — not every fsd invocation comes from a design doc.

## Phase 8c: KB Update

Persist before cleanup:

**1. Research gate findings** (from Phase 3.5): if `research_gate_findings` is non-empty, write each library/API to the general KB:
- Target: `workspace/kb/general/{technology}.md` (e.g. `azure-service-bus.md`, `signalr.md`) — create if it doesn't exist
- Use standard `### YYYY-MM-DD — {topic}` entry format
- Add `**Tags:** api-contract` and `**Confidence:** medium` (web-sourced, not yet battle-tested in this repo)
- Include: signatures, required params, return types, pitfalls, official doc URL
- If the file is new, register it in `workspace/kb/.domain-map.md` under `## General`

**2. Implementation discoveries**: if implementation revealed new patterns, architectural insights, or hard constraints specific to the target repo, invoke `/nase:kb-update [domain]` with a concise summary.

Team mode: read and delete `workspace/tmp/fsd-research-{branch_slug}.md` if present. Do not defer KB updates to wrap-up.

## Phase 9: Cleanup (if worktree = Yes)

Remove the worktree (safe since the branch is already pushed):
```bash
git -C {repo} worktree remove {worktree_path} --force
```
Confirm: "Worktree removed."

---

## Phase 10: Report

Print a concise summary:
```
FSD complete ✓

  Repo:        {repo_name}
  Branch:      {branch_name}
  Test iters:  {N} (passed on iteration N)
  PR:          {PR URL}   ← or "not opened"
  Worktree:    cleaned up ← or "n/a"

Verification before promote (full matrix appended to PR body):
  🔥 Critical:  {critical layer label} — {why}     ← omit line if no critical row
  Caveat:      {coverage caveat}                   ← omit line if none
  Required:    {list required rows by short label}
  Recommended: {list recommended rows by short label}  ← omit line if none

Next: open the draft PR, run the Verification matrix, then promote to "ready for review".
```

If Phase 8.5 produced no rows (pure docs / comments change), omit the entire "Verification before promote" block.

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
