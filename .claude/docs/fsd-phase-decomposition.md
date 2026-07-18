# FSD Phase Decomposition — "Direct with Phase isolation" Algorithm

## Contents

- Phases
- Completion Log

Full algorithm for Phase 3.7. Only applies when `execution_mode = "Direct with Phase isolation"`.

`/nase:fsd` Phase 3 provides `{branch_name}` plus path-safe `{branch_slug}`.
Use `{branch_name}` for git refs and user-facing branch text; use `{branch_slug}`
for filenames under `workspace/tmp/`.

---

**Step 1 — Complexity precheck:**
Analyze task + KB context from Phase 1. Attempt to decompose into code-layer sub-phases. If the natural decomposition yields only 1 phase → skip isolation entirely, fall back to Direct mode, notify user: "Task is simple enough for direct implementation — phase isolation skipped." Proceed to Phase 4 as Direct.

**Step 2 — Decompose (if ≥2 phases):**
Decompose into 2–5 sequential sub-phases. Boundary rule: **code layer** (data model / API / test coverage / UI) — not file count or time estimate. Dependencies determine ordering (Phase B needs Phase A's output).

Sizing sanity check (per `workspace/kb/general/engineering-heuristics.md → Planning`): the code-layer split is the primary axis, but a sub-phase that still touches many subsystems or ~8+ files is under-decomposed — split it further along the next natural seam. Order risk-first within the dependency constraints: schedule the most uncertain sub-phase as early as its blockers allow so it fails fast.

Wide-refactor exception (per `workspace/kb/general/workflow.md 2026-07-10 → to-tickets`): a mechanical change with codebase-wide blast radius (rename, signature/type change, dep swap) does not fit the code-layer model — it cuts horizontally across every layer at once. Sequence it **expand → migrate → contract** instead: add the new form beside the old, migrate call sites in blast-radius batches (per package/dir, each keeping gates green), delete the old form last. Model these as sequential sub-phases with the contract phase depending on all migrate phases.

**Step 3 — Write state file:**
Create `workspace/tmp/fsd-phases-{branch_slug}.md`:

```markdown
# FSD Phase Plan: {branch_name}
Created: {YYYY-MM-DD HH:MM}
Task: {task_description}
Repo: {repo_name} | Branch: {branch_name}
Configured gates:
- Build: {build_cmd or "not configured — evidence"}
- Lint: {lint_cmd or "not configured — evidence"}
- Typecheck: {typecheck_cmd or "not configured — evidence"}
- Test: {test_cmd or "not configured — evidence"}
KB constraints: {3-5 line summary of key constraints}
Research gate findings:
{research_gate_findings from fsd Phase 3.5, or "skipped — no unfamiliar external APIs/libraries"}
Implementation preflight:
- Task type: {task_type from fsd Phase 3.6}
- Principle order: {principle_order from fsd Phase 3.6}
- Reuse findings: {reuse_findings from fsd Phase 3.6}
- Pre-implementation greps: {pre_impl_grep_findings from fsd Phase 3.6, or "skipped — {reason}"}
Module inventory:
{finalized module_inventory from fsd Phase 3}
Topology:
{finalized topology block from fsd Phase 3, or "skipped — {skip reason}"}

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

Context file: workspace/tmp/fsd-phases-{branch_slug}.md — read it for task context, gates, research/preflight, inventory/topology, KB constraints, and prior phases.

Goal: {phase_goal}
Repo path: {work_root} (absolute)
Branch: {branch_name}
Configured gates:
- Build: {build_cmd or "not configured"}
- Lint: {lint_cmd or "not configured"}
- Typecheck: {typecheck_cmd or "not configured"}
- Test: {test_cmd or "not configured"}

Use Phase 3.6 preflight: apply `task_type` / `principle_order`, reuse `reuse_findings`, and preserve `pre_impl_grep_findings` constraints.

Before new helpers/wrappers/utilities, grep `module_inventory`; new abstractions need 3+ usage justification.

If topology exists, touch only `affected_files`; stop before expanding scope.

{tdd_block}

After changes: run every configured gate. If green, append a 3-5 line summary to ## Completion Log and stop. If any gate still fails after 3 attempts, append "FAILED: {phase_name} — {reason}" and stop — do not commit.
```

Where `{tdd_block}` (inject verbatim when tdd_mode = true):
```
TDD gates are MANDATORY per vertical slice:
RED: Write one test → run → must FAIL (assertion failure, not compile error). PASS = STOP.
GREEN: Minimum implementation → test GREEN → full suite zero new failures.
Refactor: Apply lead principles → re-run full suite → all green.
Exception: config/docs/infra → skip RED, mark [RED skip: non-testable].
```

When Q0 = "Manual verify", still run configured compile/static gates; tests may be skipped only with reason in Completion Log.

**Step 6 — Verify:**
Read the Completion Log. Every phase entry must exist and not start with "FAILED".

On success, return to `/nase:fsd` Phase 5. Phase isolation already implemented the code; do not run `/nase:fsd` Phase 4 again.

**Error recovery:** Any FAILED entry or missing phase entry → stop. Report: "Phase {X} failed — state file preserved at `workspace/tmp/fsd-phases-{branch_slug}.md`." Do NOT continue `/nase:fsd`. Preserve the state file for diagnosis.

**State file cleanup:** Delete `workspace/tmp/fsd-phases-{branch_slug}.md` at
the start of Phase 10 for a no-worktree flow. Preserve it with a claimed
worktree or when cleanup returns `2`.
