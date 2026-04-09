---
name: nase:fsd
description: Fully autonomous task execution from plan to merged-ready PR. Use whenever the user says "fsd", "full self-develop", "full self-drive", "just do it", "run it autonomously", "fire and forget", or hands off a feature/fix task end-to-end. Also trigger when someone gives a task and clearly expects autonomous completion without babysitting.
---

Inspired by Tesla FSD: you describe the destination, buckle up, and it drives. Confirm execution options upfront (team mode, worktree, PR), then drive autonomously.

**Input:** $ARGUMENTS — the task description or implementation plan

---

## Setup

Use `ToolSearch` to fetch `AskUserQuestion` before starting — it's a deferred tool needed for the three upfront configuration questions in Phase 2. Fetch it once here so it's available when needed.

## Phase 0: Input Guard

If $ARGUMENTS is empty: output `Usage: /nase:fsd <task description or plan>` and stop.

## Phase 1: Infer Context (do the homework before asking anything)

Research first — minimize questions to the user.

Read `workspace/context.md` — list of repos and their purposes.

Read `workspace/config.md` and extract the `output:` language (for PR title, description, commit messages, and all GitHub-facing content). Default to English if the file is missing or has no `## Language` section.

From the task in $ARGUMENTS, infer the most likely target repo by matching keywords, domain area, and tech stack against the repo list. Follow `.claude/docs/repo-resolution.md`:
- **Part 1** (Repo Resolution): resolve the local path from the inferred repo name. If not found in `.local-paths`, use AskUserQuestion to ask the user, then append to `.local-paths`.
- **Part 2** (KB File Loading): load the KB file — focus on **Build & Run Commands**, **Architecture**, **Critical Constraints**.

Then fetch latest and check the repo's git state:
```bash
git -C {repo} fetch origin
git -C {repo} symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||'
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

## Phase 2: Upfront Config — 3 questions, front-loaded, then autonomous

Ask all 3 questions before touching any code. After the last answer, drive to completion without pausing. The value of FSD is that decisions happen once, upfront — not scattered throughout execution.

**Q1 — Execution mode:**
```
question: "How should I implement this task?"
header: "Execution Mode [1/3]"
options:
  - label: "Direct"  , description: "I implement it myself (fast, good for focused tasks)"
  - label: "Team"    , description: "Spawn coordinated agents in parallel (better for complex multi-area work)"
```
After receiving answer, immediately ask Q2.

**Q2 — Worktree isolation:**
```
question: "Create an isolated git worktree for this task?"
header: "Isolation [2/3]"
options:
  - label: "Yes — worktree" , description: "Recommended: keeps the main branch clean while I work"
  - label: "No"             , description: "Work directly in the repo checkout"
```
After receiving answer, immediately ask Q3.

**Q3 — Pull request:**
```
question: "Open a draft PR on GitHub when done?"
header: "Pull Request [3/3]"
options:
  - label: "Yes — draft PR" , description: "Push branch and open a draft PR (you review and promote when ready)"
  - label: "No"             , description: "Just commit and push the branch"
```
After receiving answer, proceed to Phase 3 immediately — do not wait for further input.

---

## Phase 3: Setup

Print: `FSD engaged — driving autonomously from here.`

**If worktree = Yes:**
1. Generate a branch name from the task: lowercase kebab-case, prefix `feat/` or `fix/` based on task type (default to `feat/` if ambiguous). Max 50 chars total. Strip articles and filler words. Examples: "add user avatar upload" → `feat/user-avatar-upload`, "fix null pointer in auth flow" → `fix/null-ptr-auth-flow`. If the branch already exists locally or on the remote (`git show-ref refs/heads/{branch_name} refs/remotes/origin/{branch_name}`), append `-v2`, `-v3`, etc.
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

**Step 1 — DRY scan (before writing any code):**
Grep for existing utilities, helpers, or patterns that overlap with the task. Reuse before creating. If a partial abstraction already exists, extend it rather than duplicating.

**If execution mode = Team:**
Invoke the `/team` skill with the task from $ARGUMENTS, including the classified task type and its principle order. **Each agent prompt MUST include the repo's build and test commands** (from KB or `CLAUDE.md`) and instruct the agent to verify its changes compile after editing. Wait for all agents to complete, then **immediately run a full build + test** before proceeding to Phase 5. If the build or tests fail, fix the issues (this counts as iteration 1 of Phase 5).

**If execution mode = Direct — follow Red → Green → Refactor:**

1. **Red** — write tests first (skip for non-testable tasks like configuration, documentation, or infrastructure files):
   - Scan existing test files to understand conventions (location, naming, assertion style, mocking patterns).
   - Write failing tests that describe the expected behavior. Keep tests minimal and specific — one concern per test.
   - Run the tests. Confirm they fail *for the right reason* (not a compile error — the feature genuinely doesn't exist yet).

2. **Green** — implement the minimum to pass:
   - Apply the top-ranked principle from Step 0 as the primary design lens. Do not implement anything the tests don't require (YAGNI).
   - Write the smallest implementation that makes the tests pass.
   - Re-run the tests. All new tests must be green; no existing tests may regress.

3. **Refactor** — apply the lead principles from Step 0:
   - Walk the lead principles: does the code satisfy each? If not, refactor until it does before moving on.
   - Re-run tests after each refactor pass to confirm nothing broke.

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

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–5) to discover the PR template, draft the description, align the title with the commit subject, preserve co-authors (relevant in team mode), and exclude AI attribution.

Open a draft PR:
```bash
gh pr create \
  --draft \
  --title "{commit_subject_line}" \
  --body "$(cat <<'EOF'
{pr_body}
EOF
)" \
  --base {default_branch} \
  --head {branch_name} \
  -R {repo_owner}/{repo_name}
```

Report the PR URL.

---

## Phase 8b: Effort Doc Update

If $ARGUMENTS contains a slug that matches a file in `workspace/tasks/efforts/{slug}.md`, update its lifecycle:

```bash
# Check if effort doc exists
ls workspace/tasks/efforts/ 2>/dev/null
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

Append to `workspace/logs/{YYYY-MM-DD}.md`:
```
- FSD: {one-line task summary} → `{branch_name}` [{PR URL or "no PR"}]
```

---

## Error Handling

<error_handling>

- **Autonomous after Phase 2** — never pause mid-execution for confirmation unless genuinely blocked (test failures after 5 attempts, unresolvable ambiguity in requirements). When invoking sub-skills that prompt for user input (e.g. AskUserQuestion), use your best judgement to answer on behalf of the user based on the task context. FSD should drive through interactive prompts, not avoid them.
- **Protected branches** — never commit directly to `main`, `master`, `develop`, or `release/*`. FSD always works on a feature branch.
- **Worktree path** — always create it as a sibling to the repo (not inside it) to avoid git nesting issues.
- **Secrets** — if unsure about a file during the staging scan, stop and ask rather than committing and reverting later.
- **Test loop bound** — 5 iterations is a hard cap. Reporting an honest failure is better than an infinite loop.
- **PR is always draft** — FSD never opens a ready-for-review PR. Promotion is a human decision.

</error_handling>
