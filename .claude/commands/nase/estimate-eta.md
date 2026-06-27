---
name: nase:estimate-eta
description: Estimate the effort and ETA for a given task or feature request. Use whenever someone asks "how long will this take?", "when can we ship X?", "estimate this", or before committing to a timeline.
argument-hint: "<task-or-feature>"
when_to_use: "Estimate the effort and ETA for a given task or feature request. Use whenever someone asks \"how long will this take?\", \"when can we ship X?\", \"estimate this\", or before committing to a timeline."
pattern: utility
category: Reporting
---

**Task to estimate:** $ARGUMENTS

**Step 0 — Language preflight (MUST run first):** follow `.claude/docs/language-config.md` → Minimum Step 0 block.

## Input Guard
If $ARGUMENTS is empty or blank:
- Output: `Usage: /nase:estimate-eta <task description>  (e.g. /nase:estimate-eta Add caching to the alerts API)`
- Stop immediately — do not proceed.

## Estimation Principles
Apply the principles and confidence-range format in `.claude/docs/eta-estimation.md`.

## Steps

<workflow>

1. Parse the task description from $ARGUMENTS carefully
2. Read `workspace/context.md` to identify the relevant repo(s). Follow `.claude/docs/repo-resolution.md` Part 1 + Part 2 to resolve the path and load the KB file. If the task could span multiple repos and the target is ambiguous, ask the user which repo to focus on. Then explore the codebase to understand:
   - Relevant existing files and components that would be touched
   - Current complexity and test coverage
   - Any dependencies or integrations involved
3. Read `workspace/tasks/lessons.md` if it exists — look for similar past tasks and how long they took
   - Also check the relevant project KB (`workspace/kb/projects/`) for historical velocity data and known complexity patterns
4. Read `workspace/tasks/todo.md` to understand current workload and what's in flight
5. Break the task into concrete subtasks with individual estimates
6. Factor in: complexity, unknowns, testing, review, and integration work

7. Persist the estimate — append to `workspace/logs/{YYYY-MM-DD}.md`:
   ```
   - ETA estimate: {task name} — {realistic estimate} ({scope})
   ```
   This line is the calibration anchor: `/nase:wrap-up` will later compare it against actual completion time and write a calibration note to `workspace/tasks/lessons.md` if the divergence is significant. See `.claude/docs/lessons-format.md` for the format.

</workflow>

## Output Format

---
**ETA Estimate — {task name}**

**Understanding of the Task**
- What needs to be built/changed (in plain terms)
- Scope: [Small / Medium / Large / XL]

**Subtask Breakdown**
| Subtask | Estimate | Notes |
|---------|----------|-------|
| ... | Xh | ... |
| ... | Xh | ... |

**Total Estimate**
- Optimistic: X hours / days
- Realistic: X hours / days
- Pessimistic: X hours / days

**Key Risks & Unknowns**
- List anything that could blow up the estimate

**Dependencies**
- What needs to be done/decided first

**Suggested Approach**
- Brief recommended implementation plan
---

Be honest about uncertainty. Use ranges, not false precision. If the task is too vague to estimate, ask for clarification before guessing.

Ready to implement? Consider `/nase:fsd` for the end-to-end implementation workflow.
