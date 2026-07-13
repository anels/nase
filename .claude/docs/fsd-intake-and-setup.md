# FSD Intake and Setup

Read this file only when /nase:fsd enters Phases 1-3.7. It owns context inference, topology, upfront options, worktree setup, and phase decomposition. Return the named state to the command entrypoint.

## Phase 1: Infer Context (do the homework before asking anything)

Research first; minimize questions. Read `workspace/context.md`, then `workspace/config.md → ## Language` for both `conversation:` (chat) and `output:` (PR/commit) languages (default English if missing) - see the Language preflight above.

**Effort-doc intake (design handoff):** before repo inference, scan `$ARGUMENTS` tokens for a slug matching `workspace/efforts/{slug}.md`. If found, read the effort doc and extract:
- `### Success Criteria` → store as `success_criteria_from_design`. Phase 2 drops Q0 and uses these as the done-definition.
- The latest `## Grill Session → ### Constraints for implementation` block (if any) → store as `design_constraints`. These are evidence-backed decisions - carry them into Phase 4 and every subagent prompt; do not re-litigate them silently.
- `### Implementation Plan` → store as `design_impl_plan` (per-step files/tests/done + dependency graph). Seed Phase 3.7 decomposition from these steps instead of re-deriving them; the design already marked which steps are parallel vs sequential.
- `### PR Plan` → store as `design_pr_plan`. Default to the design PR plan when deciding whether to keep one PR or split; do not create extra PRs just because the implementation has multiple phases.
- `## Topology` (if present) → seed Phase 1.5 with it instead of rebuilding; Phase 3 finalization re-verifies the listed paths still exist in `{work_root}`.
- Frontmatter `repo:` → store as `repo_hint_from_design`; use it as the target repo unless the user explicitly named a different one.

If no slug matches, continue normally - not every fsd run comes from a design doc.

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
options: one option per repo in context.md, plus "Other - I'll type the path"
```
After the answer, resume Phase 1 for that repo (path, KB, `fsd-preflight`), then proceed to Phase 1.5.

## Phase 1.5: Topology Map (before any code intent is locked in)

For non-trivial tasks, write the affected surface before code intent locks in.

**Skip topology silently when:**
- Single-file edit < 50 LoC delta - skip.
- Docs / comments / README only - skip.
- The repo is unfamiliar but the task is mechanical (rename, bump version, regenerate fixture) - skip.

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
    - {invariant - observable behavior, persistence shape, ordering, perf budget, etc.}
  open_questions:        # things the map could not resolve (ask before Phase 4 if material)
    - {question}
```

If topology exists, Phase 4 edits only `affected_files`; add files by re-entering Phase 3 finalization. If skipped, rely on Phase 4 greps.

**Early size signal:** if `affected_files` already exceeds ~15 files, say so now and name the natural split seams - cheaper to scope down before code intent locks in than at the Phase 5.5 diff measurement.

## Phase 2: Upfront Config - single batched AskUserQuestion, then execution

Ask all 5 config decisions in one `AskUserQuestion` `questions` array, then continue until done or blocked.

**If `success_criteria_from_design` exists** (Phase 1 effort-doc intake): drop Q0 from the batched call, set `success_criteria` = the design doc's Success Criteria, and say one line: `Done-definition taken from workspace/efforts/{slug}.md Success Criteria.` Ask only Q1–Q4.

Store answers: `success_criteria` = Q0 answer (or the design doc's criteria), `execution_mode` = Q1 answer, `worktree` = (Q2 = "Yes - worktree"), `open_pr` = (Q3 = "Yes - draft PR"), `tdd_mode` = (Q4 = "Yes").

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
      - label: "Direct with Phase isolation" , description: "I orchestrate sequential subagents, one per code layer - prevents context rot on large features"
  - question: "Create an isolated git worktree for this task?"
    header: "Isolation"
    multiSelect: false
    options:
      - label: "Yes - worktree" , description: "Recommended: keeps the main branch clean while I work"
      - label: "No"             , description: "Work directly in the repo checkout"
  - question: "Open a draft PR on GitHub when done?"
    header: "Pull Request"
    multiSelect: false
    options:
      - label: "Yes - draft PR" , description: "Push branch and open a draft PR (you review and promote when ready)"
      - label: "No"             , description: "Just commit and push the branch"
  - question: "Enforce strict TDD? (RED→GREEN→Refactor hard gates per slice)"
    header: "Strict TDD"
    multiSelect: false
    options:
      - label: "No"  , description: "Advisory Red→Green→Refactor - current default behavior"
      - label: "Yes" , description: "Hard gates: test must FAIL before any implementation; PASS = stop and report"
```

**Post-answer handling:**
- If Q0 = "Spec the criteria": after the batched call returns, do a single follow-up `AskUserQuestion` with a free-text prompt to collect the criteria. Store as `success_criteria`.
- If Q1 = "Team": ignore the Q4 (Strict TDD) answer - TDD gating is per-direct-mode only.
- Proceed to Phase 3 immediately; do not pause for more input.

---

## Phase 3: Setup

Print: `FSD options captured - starting implementation.`

Generate `{branch_name}` before the worktree decision: lowercase kebab-case, `feat/` or `fix/` prefix, max 50 chars, strip filler words. If `git show-ref refs/heads/{branch_name} refs/remotes/origin/{branch_name}` finds it, append `-v2`, `-v3`, etc. until free.

Derive `{branch_slug}` only for local artifact paths: replace `/` and other characters outside `[A-Za-z0-9._-]` with `-`, trim leading/trailing `-`, and fall back to `branch` if empty. Never use `{branch_slug}` for git refs.

**If worktree = Yes:**
1. Follow the worktree pattern in `.claude/docs/worktree-pattern.md`. Suffix: `fsd`. Ref: `origin/{default_branch}`. Use the branch name generated above.
2. All subsequent git and file operations use absolute paths to `{worktree_path}`. Do NOT use `EnterWorktree` - it creates its own worktree and won't adopt this one.

**If worktree = No:**
- Confirm repo is on the default branch with a clean working tree. If not: stop and tell the user to clean up first (do not force-checkout or stash without asking).
- Create a new branch: `git -C {repo} checkout -b {branch_name} origin/{default_branch}`

Set `{work_root}` = `{worktree_path}` if worktree = Yes, else `{repo}`.

**Finalize `module_inventory`:** keep `moduleInventory` from `$TMPDIR/fsd-preflight.json`; grep inside `{work_root}` only if the helper found too little for this task. Carry into subagent prompts.

**Finalize topology (if `topology = needs-work-root`):** grep/glob inside `{work_root}` only, ≤25 lines. If this came from `/nase:design`, stage and append it to `workspace/efforts/{slug}.md` under `## Topology` using the workspace write guard; otherwise keep it in conversation context for Phase 4.

**KB mentions preflight:** start with `kbMentionCandidates` from `$TMPDIR/fsd-preflight.json`. Once touched paths are known from topology, run `bash .claude/scripts/kb-search.sh mentions:<path> --max-entry-lines 8` only for the expected touched source/config paths (cap at 10; skip generated files unless they are the primary edit target). Store hits as `kb_path_constraints`; if no hits, write `none found`. Carry this into Phase 4 prompts and the implementation constraints.

---

## Phase 3.7: Task Decomposition (execution_mode = "Direct with Phase isolation" only)

**Skip entirely** if execution_mode ≠ "Direct with Phase isolation". Jump to Phase 4.

Follow `.claude/docs/fsd-phase-decomposition.md`, passing Phase 3.5 research and Phase 3.6 preflight into the state file and every subagent prompt.

If phase isolation falls back to Direct mode, continue to Phase 4 as Direct. If phase isolation completes successfully, proceed directly to Phase 5; the subagents already implemented the changes, so do not run Phase 4 again.
---
