---
name: nase:fsd
description: Fully autonomous task execution from plan to merged-ready PR. Use whenever the user says "fsd", "full self-drive", "just do it", "run it autonomously", "fire and forget", or hands off a feature/fix task end-to-end. Also trigger when someone gives a task and clearly expects autonomous completion without babysitting.
---

Inspired by Tesla FSD: you describe the destination, buckle up, and it drives. Confirm execution options upfront (team mode, worktree, PR), then drive autonomously.

**Input:** $ARGUMENTS — the task description or implementation plan

---

## Phase 0: Input Guard

If $ARGUMENTS is empty: output `Usage: /nase:fsd <task description or plan>` and stop.

## Phase 1: Infer Context (do the homework before asking anything)

Research first — minimize questions to the user.

<parallel>
- Read `work/context.md` — list of repos and their purposes
- Read `work/kb/.domain-map.md` — repo → KB file mapping
</parallel>

From the task in $ARGUMENTS, infer the most likely target repo by matching keywords, domain area, and tech stack against the repo list. Read the candidate KB file (`work/kb/projects/{domain}.md`) — focus on: **Build & Run Commands**, **Architecture**, **Critical Constraints**.

Then check the repo's git state:
```bash
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

Print: `FSD engaged — driving autonomously from here. 🚗`

**If worktree = Yes:**
1. Generate a branch name from the task: lowercase kebab-case, prefix `feat/` or `fix/` based on task type (default to `feat/` if ambiguous). Max 50 chars total. Strip articles and filler words. Examples: "add user avatar upload" → `feat/user-avatar-upload`, "fix null pointer in auth flow" → `fix/null-ptr-auth-flow`. If the branch already exists locally or on the remote (`git show-ref refs/heads/{branch_name} refs/remotes/origin/{branch_name}`), append `-v2`, `-v3`, etc.
2. Determine worktree path: sibling directory to repo, e.g. `{repo_parent}/{repo_name}-fsd` (if that path already exists, append `-1`, `-2`, etc. until available).
3. Create the worktree:
   ```bash
   git -C {repo} worktree add {worktree_path} -b {branch_name} origin/{default_branch}
   ```
4. All subsequent git and file operations use absolute paths to `{worktree_path}`. Do NOT use `EnterWorktree` — it creates its own worktree and won't adopt this one.

**If worktree = No:**
- Confirm repo is on the default branch with a clean working tree. If not: stop and tell the user to clean up first (do not force-checkout or stash without asking).
- Create a new branch: `git -C {repo} checkout -b {branch_name} origin/{default_branch}`

---

## Phase 4: Implement

Read the repo's `CLAUDE.md` (if not already read) for coding standards and constraints. Read the relevant KB section on architecture so changes fit the existing design.

**If execution mode = Team:**
Invoke the `/team` skill with the task from $ARGUMENTS. Wait for all agents to complete before proceeding to Phase 5.

**If execution mode = Direct:**
Implement the task. Follow the repo's coding standards. Keep changes minimal and focused — do not refactor surrounding code unless directly required by the task. Aim for the smallest diff that correctly solves the problem.

---

## Phase 5: Build & Test Loop (max 5 iterations)

Get build and test commands from the KB file's **Build & Run Commands** section. If missing there, check: repo's `CLAUDE.md`, `package.json` scripts, `Makefile`, `*.sln` / `dotnet` conventions, or `.github/workflows/`. If no commands are found after checking all sources, stop and ask:
```
question: "What commands should I use to build and test this repo?"
header: "Build & Test Commands"
```

**For each iteration:**
1. Run the build command. If it fails: read the error, identify root cause, fix it. Do not retry the same fix twice — try a different approach.
2. Run the test command. If it fails: read the failure output, identify whether it's a test expectation issue or a logic bug. Fix production code — never modify tests to make them pass.
3. If both pass: proceed to Phase 6.

If still failing after 5 iterations: stop, print the last build/test output in full, and ask the user for guidance. Do not commit broken code.

---

## Phase 6: Simplify

Run `/simplify` on the changed files. If the skill is not available (not all Claude Code installations include it), skip this step and proceed to Phase 7. If available, apply any improvements it suggests — this catches code quality issues, unnecessary complexity, and missed reuse opportunities before the commit is permanent.

---

## Phase 7: Commit & Push

Stage files explicitly (never `git add -A` — avoid accidentally staging secrets or unrelated files):
```bash
git -C {worktree_or_repo} add {each changed file by name}
```

Verify staged diff looks correct with `git -C {worktree_or_repo} diff --cached --stat`.

Quick secrets scan: glance at changed files for hardcoded tokens, passwords, or personal info. If anything looks suspicious, stop and ask before committing.

Create an initial commit with a reasonable message, then run `/nase:improve-commit-message --auto-accept` to refine it without pausing for confirmation.

Push:
```bash
git -C {worktree_or_repo} push -u origin {branch_name}
```

---

## Phase 8: Pull Request (if PR = Yes)

Check for `.github/pull_request_template.md` in the repo — if it exists, use it as the PR body structure.

Write a concise PR description: what changed, why, and any testing notes. Do not include Claude/AI attribution anywhere in the PR.

Open a draft PR:
```bash
gh pr create \
  --draft \
  --title "{conventional_commit_subject_from_phase_7}" \
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

Append to `work/logs/{YYYY-MM-DD}.md`:
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
- **No AI attribution** — no "Co-Authored-By: Claude" lines in commits. No "Generated with Claude Code" in PR descriptions.

</error_handling>
