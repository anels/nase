---
name: nase:fsd
description: Fully autonomous task execution from plan to merged-ready PR. Use whenever the user says "fsd", "full self-develop", "full self-drive", "just do it", "run it autonomously", "fire and forget", or hands off a feature/fix task end-to-end. Also trigger when someone gives a task and clearly expects autonomous completion without babysitting.
---

Inspired by Tesla FSD: you describe the destination, buckle up, and it drives. Confirm execution options upfront (team mode, worktree, PR), then drive autonomously.

**Input:** $ARGUMENTS — the task description or implementation plan

---

## Phase 0: Input Guard

If $ARGUMENTS is empty: output `Usage: /nase:fsd <task description or plan>` and stop.

## Phase 1: Infer Context (do the homework before asking anything)

Research first — minimize questions to the user.

Read `workspace/context.md` — list of repos and their purposes.

Read `workspace/config.md` and extract the `output:` language (for PR title, description, commit messages, and all GitHub-facing content). Default to English if the file is missing or has no `## Language` section.

From the task in $ARGUMENTS, infer the most likely target repo by matching keywords, domain area, and tech stack against the repo list. Resolve repo path and load the KB file (focus on **Build & Run Commands**, **Architecture**, **Critical Constraints**) — see `.claude/docs/repo-resolution.md` (Part 1 + Part 2).

Then fetch latest and check the repo's git state:
```bash
git -C {repo} fetch origin
git -C {repo} symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || git -C {repo} remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p'
git -C {repo} status --short
git -C {repo} branch --show-current
```

**If repo cannot be inferred with confidence**, use AskUserQuestion immediately:
```
question: "Which repo should I work in? (I couldn't determine it from the task description)"
header: "Target Repo"
options: one option per repo in context.md, plus "Other — I'll type the path"
```
After receiving answer, immediately proceed to Phase 2.

## Phase 2: Upfront Config — 4–5 questions, front-loaded, then autonomous

Ask all questions before touching any code. After the last answer, drive to completion without pausing. The value of FSD is that decisions happen once, upfront — not scattered throughout execution.

Store answers: `execution_mode` = Q1 answer, `tdd_mode` = (Q4 = "Yes").

**Q0 — Success criteria:**
```
question: "How will we know this is done?"
header: "Done When [1/4]"
options:
  - label: "Tests pass"        , description: "All new + existing tests green (default for code changes)"
  - label: "Manual verify"     , description: "I'll check it myself after you push"
  - label: "Spec the criteria" , description: "I'll describe exactly what done looks like"
```
If "Spec the criteria": use AskUserQuestion with a free-text prompt to collect the criteria. Store as `success_criteria` for use in Phase 4 and Phase 5.
After receiving answer, immediately ask Q1.

**Q1 — Execution mode:**
```
question: "How should I implement this task?"
header: "Execution Mode [2/4]"
options:
  - label: "Direct"                      , description: "I implement it myself (fast, good for focused tasks)"
  - label: "Team"                        , description: "Spawn coordinated agents in parallel (better for complex multi-area work)"
  - label: "Direct with Phase isolation" , description: "I orchestrate sequential subagents, one per code layer — prevents context rot on large features"
```
After receiving answer, immediately ask Q2.

**Q2 — Worktree isolation:**
```
question: "Create an isolated git worktree for this task?"
header: "Isolation [3/4]"
options:
  - label: "Yes — worktree" , description: "Recommended: keeps the main branch clean while I work"
  - label: "No"             , description: "Work directly in the repo checkout"
```
After receiving answer, immediately ask Q3.

**Q3 — Pull request:**
```
question: "Open a draft PR on GitHub when done?"
header: "Pull Request [4/4]"
options:
  - label: "Yes — draft PR" , description: "Push branch and open a draft PR (you review and promote when ready)"
  - label: "No"             , description: "Just commit and push the branch"
```
After receiving answer:
- If Q1 = "Team": proceed to Phase 3 immediately.
- Otherwise: ask Q4.

**Q4 — Strict TDD** (only when Q1 ≠ "Team"):
```
question: "Enforce strict TDD? (RED→GREEN→Refactor hard gates per slice)"
header: "Strict TDD [5/5]"
options:
  - label: "No"  , description: "Advisory Red→Green→Refactor — current default behavior"
  - label: "Yes" , description: "Hard gates: test must FAIL before any implementation; PASS = stop and report"
```
After receiving answer, proceed to Phase 3 immediately — do not wait for further input.

---

## Phase 3: Setup

Print: `FSD engaged — driving autonomously from here.`

**If worktree = Yes:**
1. Generate a branch name from the task: lowercase kebab-case, prefix `feat/` or `fix/` based on task type (default to `feat/` if ambiguous). Max 50 chars total. Strip articles and filler words. Examples: "add user avatar upload" → `feat/user-avatar-upload`, "fix null pointer in auth flow" → `fix/null-ptr-auth-flow`. If the branch already exists locally or on the remote (`git show-ref refs/heads/{branch_name} refs/remotes/origin/{branch_name}`), append `-v2`, `-v3`, etc. — **loop** until a free name is found (check each candidate before using it).
2. Follow the worktree pattern in `.claude/docs/worktree-pattern.md`. Suffix: `fsd`. Ref: `origin/{default_branch}`. Use the branch name generated in step 1.
3. All subsequent git and file operations use absolute paths to `{worktree_path}`. Do NOT use `EnterWorktree` — it creates its own worktree and won't adopt this one.

**If worktree = No:**
- Confirm repo is on the default branch with a clean working tree. If not: stop and tell the user to clean up first (do not force-checkout or stash without asking).
- Create a new branch: `git -C {repo} checkout -b {branch_name} origin/{default_branch}`

---

## Phase 3.5: Research Gate (unfamiliar APIs/libraries only)

Before writing code, check if the task involves external APIs, libraries, or frameworks that are NOT already documented in the repo's KB file or `CLAUDE.md`.

1. **Scan** the task description ($ARGUMENTS) for library names, API references, SDK mentions, or framework-specific terms
2. **Cross-check** against the repo's KB file (loaded in Phase 1) and `CLAUDE.md` for existing coverage
3. **Decision**:
   - If all referenced APIs/libraries are already in KB or CLAUDE.md → **skip** (no overhead for familiar territory)
   - If task is purely internal code changes with no external dependencies → **skip**
   - If task references APIs/libraries NOT in KB → **research gate**:
     - Run WebSearch for official documentation of each unfamiliar API/library
     - WebFetch the most relevant doc page (API reference, getting started, or migration guide)
     - Extract: method signatures, required parameters, return types, common pitfalls
     - Hold this context for Phase 4 — do not write to KB yet (Phase 8b handles that)

**Track findings for KB:** After completing research, record a `research_gate_findings` summary. For direct mode, carry it in conversation context. For **team mode**, also write it to `workspace/tmp/fsd-research-{branch_name}.md` so Phase 8c can read it back after subagents complete (subagents don't inherit this session's context):
```
research_gate_findings:
  - {LibraryName}: key method signatures, required params, return types, pitfalls, doc URL
```
Record even when findings seem obvious — the goal is to prevent re-researching the same API next session.

This gate prevents hallucinated API contracts. Cost: ~30s for unfamiliar APIs. Cost for familiar tasks: zero (skipped).

---

## Phase 3.7: Task Decomposition (execution_mode = "Direct with Phase isolation" only)

**Skip entirely** if execution_mode ≠ "Direct with Phase isolation". Jump to Phase 4.

**Step 1 — Complexity precheck:**
Analyze task + KB context from Phase 1. Attempt to decompose into code-layer sub-phases. If the natural decomposition yields only 1 phase → skip isolation entirely, fall back to Direct mode, notify user: "Task is simple enough for direct implementation — phase isolation skipped." Proceed to Phase 4 as Direct.

**Step 2 — Decompose (if ≥2 phases):**
Decompose into 2–5 sequential sub-phases. Boundary rule: **code layer** (data model / API / test coverage / UI) — not file count or time estimate. Dependencies determine ordering (Phase B needs Phase A's output).

**Step 3 — Write state file:**
Create `workspace/tmp/fsd-phases-{branch_name}.md`:

```markdown
# FSD Phase Plan: {branch_name}
Created: {YYYY-MM-DD HH:MM}
Task: {task_description}
Repo: {repo_name} | Branch: {branch_name}
Build: {build_cmd} | Test: {test_cmd}
KB constraints: {3-5 line summary of key constraints}

## Phases
### Phase A: {name}
Goal: ...
Files expected: ...
Done when: ...
Status: pending

## Completion Log
(subagents append here on phase finish)
```

**Step 4 — Confirm loop:**
Show decomposition to user. Present 3 options via AskUserQuestion:
- **Proceed** → start subagent execution
- **Adjust** (describe changes) → Claude revises plan, shows again; loop until Proceed or Cancel
- **Cancel → Direct mode** → abort isolation, continue with standard Phase 4 as Direct

**Step 5 — Sequential subagent execution (after Proceed):**
For each phase, invoke `Agent` tool sequentially (wait for completion before next). Prompt template:

```
You are implementing Phase {X}: {phase_name} of a multi-phase feature.

Context file: workspace/tmp/fsd-phases-{branch_name}.md — read it for task context,
KB constraints, and what prior phases completed.

Goal: {phase_goal}
Repo path: {repo_path} (absolute)
Branch: {branch_name}
Build command: {build_cmd}
Test command: {test_cmd}

{tdd_block}

After all changes: run build{test_suffix}. If both pass: append a 3-5 line summary to
## Completion Log, then stop.
If build or tests fail after 3 attempts: append "FAILED: {phase_name} — {reason}" to
## Completion Log and stop — do not commit.
```

Where `{tdd_block}` (inject verbatim when tdd_mode = true):
```
TDD gates are MANDATORY per vertical slice:
RED: Write one test → run → must FAIL (assertion failure, not compile error). PASS = STOP.
GREEN: Minimum implementation → test GREEN → full suite zero new failures.
Refactor: Apply lead principles → re-run full suite → all green.
Exception: config/docs/infra → skip RED, mark [RED skip: non-testable].
```

Where `{test_suffix}` = ` + test` unless Q0 = "Manual verify" (subagents run build only).

**Step 6 — Verify:**
After all Agent calls complete, read the Completion Log. Every phase entry must be present and must not start with "FAILED".

**Error recovery:** Any FAILED entry or missing phase entry → stop. Report: "Phase {X} failed — state file preserved at `workspace/tmp/fsd-phases-{branch_name}.md`." Do NOT proceed to Phase 7 (commit). Preserve the state file for diagnosis.

**State file cleanup:** Delete `workspace/tmp/fsd-phases-{branch_name}.md` at Phase 9 (worktree removal) or at the start of Phase 10 (no-worktree flow).

---

## Phase 4: Implement (TDD — Red → Green → Refactor)

Read the repo's `CLAUDE.md` (if not already read) for coding standards and constraints. Read the relevant KB section on architecture so changes fit the existing design.

**Step 0 — Classify task type and pick your lead principles:**

| Context | Examples | Lead with |
|---------|----------|-----------|
| Architecture / requirements analysis | system redesign, new service, cross-cutting concern | First Principles → SOLID |
| New feature / incremental development | adding an endpoint, extending a handler, new config option | YAGNI → KISS |
| Small function / utility | helper, formatter, parser, extension method | KISS → DRY |
| Complex business component / OOP modelling | domain entity, stateful service, multi-class hierarchy | First Principles → SOLID → DRY |

Use the lead principles as the primary design lens. The others (DRY, YAGNI, KISS, SOLID) still apply but yield to the lead when they conflict.

**Complexity self-check (before writing any code):** Ask: "Would a senior engineer say this design is overcomplicated?" If yes — simplify first. Common signals: abstract class for a single implementor, config system for a single value, error handling for impossible scenarios, >3 layers of indirection for a straight-line operation.

**Step 1 — DRY scan (before writing any code):**
Grep for existing utilities, helpers, or patterns that overlap with the task. Reuse before creating. If a partial abstraction already exists, extend it rather than duplicating.

**If execution mode = Team:**
Invoke the `/team` skill with the task from $ARGUMENTS, including the classified task type and its principle order. **Each agent prompt MUST include the repo's build and test commands** (from KB or `CLAUDE.md`) and instruct the agent to verify its changes compile after editing. Wait for all agents to complete, then **immediately run a full build + test** before proceeding to Phase 5. If the build or tests fail, fix the issues (this counts as iteration 1 of Phase 5).

**If execution mode = Direct or "Direct with Phase isolation" — follow Red → Green → Refactor in vertical slices:**

**If tdd_mode = true (Q4=Yes) — strict TDD gates are MANDATORY, not advisory:**

| Gate | Requirement |
|------|-------------|
| **RED** | Run test after writing it. Must fail with assertion failure (not compile error). If it PASSES: STOP — report `"RED gate blocked: test '{test_name}' passed immediately. Behavior may already exist, or test doesn't exercise the right code path."` Do not proceed. |
| **GREEN** | After implementation: test must GREEN + full suite zero new failures. Full suite failures: fix before proceeding — no deferrals. |
| **Refactor** | Re-run full suite after each refactor pass. All green before Phase 5. |
| **Non-testable** | Config/docs/infra → skip RED gate. Mark `[RED skip: non-testable]` in progress notes and proceed directly to implementation. |

**Vertical-slice rule (do not violate):** one test → one implementation → repeat. Never write all tests up front and then all implementation. See `workspace/kb/general/system-design.md` § Vertical Slices (TDD) for the rationale (horizontal slicing produces tests of *imagined* behavior). The first cycle is a tracer bullet that proves the end-to-end path; subsequent cycles cover one behavior each.

For each behavior, do one full Red→Green cycle before starting the next:

1. **Red** — write ONE test for the next behavior (skip for non-testable tasks like configuration, documentation, or infrastructure files):
   - Scan existing test files to understand conventions (location, naming, assertion style, mocking patterns).
   - Write a single failing test that describes one observable behavior through the public interface (not implementation details — a test that would survive an internal refactor).
   - Run the test. Confirm it fails *for the right reason* (not a compile error — the behavior genuinely doesn't exist yet).

2. **Green** — implement the minimum to pass THIS test:
   - Apply the top-ranked principle from Step 0 as the primary design lens. Do not implement anything the current test doesn't require (YAGNI). Do not anticipate the next test's needs.
   - Write the smallest implementation that makes this single test pass.
   - Re-run the test. It must be green; no existing tests may regress.
   - Loop back to Red for the next behavior. Stop when all planned behaviors are covered.

3. **Refactor** — apply the lead principles from Step 0 once all Red→Green cycles are done:
   - Never refactor while RED. Get to GREEN first.
   - Walk the lead principles: does the code satisfy each? If not, refactor until it does before moving on.
   - Re-run the full test suite after each refactor pass to confirm nothing broke.

---

## Phase 5: Build & Test Loop (max 5 iterations)

Get build and test commands from the KB file or repo's `CLAUDE.md`.
Follow the build & test iteration loop in `.claude/docs/build-test-loop.md` (max 5 iterations).
On success: proceed to Phase 6.

---

## Phase 6: Simplify

Run `/simplify` on the changed files. If the skill is not available (not all Claude Code installations include it), perform a self-review of the changed files instead: check for unused imports, overly complex functions, duplicated code, and obvious simplifications. Apply any improvements before proceeding. If `/simplify` is available, apply any improvements it suggests — this catches code quality issues, unnecessary complexity, and missed reuse opportunities before the commit is permanent.

---

## Phase 7: Commit & Push

Follow the commit & push sequence in `.claude/docs/commit-push-pattern.md`.
Deviation: use `push -u origin {branch_name}` on first push (sets upstream tracking).

---

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–4) to discover the PR template, draft the description, align the title with the commit subject, and preserve co-authors (relevant in team mode).

Open a draft PR:
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

## Phase 8b: Effort Doc Update

If $ARGUMENTS contains a slug that matches a file in `workspace/efforts/{slug}.md`, update its lifecycle:

```bash
# Check if the specific effort doc exists for the inferred slug
ls workspace/efforts/{slug}.md 2>/dev/null
```

If the effort doc exists, check off the relevant lifecycle items and update the status:
- `- [ ] Implementation started` → `- [x] Implementation started — {YYYY-MM-DD}`
- `- [ ] PR opened` → `- [x] PR opened — {PR URL or branch_name}` (only if PR was created)
- Update frontmatter: `status: in-progress`

If the slug cannot be inferred from $ARGUMENTS (e.g., fsd was given a raw task, not a slug), skip silently — not every fsd invocation comes from a design doc.

## Phase 8c: KB Update

Two categories of knowledge to persist — handle both before cleanup:

**1. Research gate findings** (from Phase 3.5): if `research_gate_findings` is non-empty, write each library/API to the general KB:
- Target: `workspace/kb/general/{technology}.md` (e.g. `azure-service-bus.md`, `signalr.md`) — create if it doesn't exist
- Use standard `### YYYY-MM-DD — {topic}` entry format
- Add `**Tags:** api-contract` and `**Confidence:** medium` (web-sourced, not yet battle-tested in this repo)
- Include: key method signatures, required parameters, return types, common pitfalls; official doc URL in `**Links:**`
- If the file is new, register it in `workspace/kb/.domain-map.md` under `## General`

**2. Implementation discoveries**: if implementation revealed new patterns, architectural insights, or hard constraints specific to the target repo, invoke `/nase:kb-update [domain]` with a concise summary.

For **team mode**: read `workspace/tmp/fsd-research-{branch_name}.md` if it exists to recover research gate findings, then delete it after processing.

Don't defer either category to wrap-up — context is freshest immediately after the task.

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

Next: open the draft PR, review the diff, then promote to "ready for review".
```

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `fsd`).
Log: `{one-line task summary} → \`{branch_name}\` [{PR URL or "no PR"}]`

---

## Error Handling

<error_handling>

- **Autonomous after Phase 2** — never pause mid-execution for confirmation unless genuinely blocked (test failures after 5 attempts, unresolvable ambiguity in requirements). When invoking sub-skills that prompt for user input: for deterministic/mechanical prompts (file existence, yes/no confirmations, format choices already decided in Phase 2), answer autonomously. For design decisions, technology choices, or scope questions, use the preferences captured in Phase 2. If Phase 2 didn't cover a decision point, pause and ask the user via AskUserQuestion rather than guessing.
- **Protected branches** — never commit directly to `main`, `master`, `develop`, or `release/*`. FSD always works on a feature branch.
- **Worktree path** — always create it as a sibling to the repo (not inside it) to avoid git nesting issues.
- **Secrets** — if unsure about a file during the staging scan, stop and ask rather than committing and reverting later.
- **Test loop bound** — 5 iterations is a hard cap. Reporting an honest failure is better than an infinite loop.
- **PR is always draft** — FSD never opens a ready-for-review PR. Promotion is a human decision.

</error_handling>
