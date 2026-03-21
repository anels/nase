---
name: nase:estimate-eta
description: Estimate the effort and ETA for a given task or feature request. Use whenever someone asks "how long will this take?", "when can we ship X?", "estimate this", or before committing to a timeline.
---

**Task to estimate:** $ARGUMENTS

## Input Guard
If $ARGUMENTS is empty or blank:
- Output: `Usage: /estimate-eta <task description>  (e.g. /estimate-eta Add caching to the alerts API)`
- Stop immediately — do not proceed.

## Estimation Principles
- Estimates improve with familiarity — explore the codebase before committing to numbers
- Unknowns dominate: one unclear dependency can triple the timeline
- Compare against similar past tasks in `work/tasks/lessons.md` — pattern-matching beats guessing
- The pessimistic estimate is usually the realistic one

## Steps

<workflow>

1. Parse the task description from $ARGUMENTS carefully
2. Explore the codebase to understand:
   - Relevant existing files and components that would be touched
   - Current complexity and test coverage
   - Any dependencies or integrations involved
3. Read `work/tasks/lessons.md` if it exists — look for similar past tasks and how long they took
   - Also check the relevant project KB (`work/kb/projects/`) for historical velocity data and known complexity patterns
4. Read `work/tasks/todo.md` to understand current workload and what's in flight
5. Break the task into concrete subtasks with individual estimates
6. Factor in: complexity, unknowns, testing, review, and integration work

7. Persist the estimate — append to `work/logs/{YYYY-MM-DD}.md`:
   ```
   - ETA estimate: {task name} — {realistic estimate} ({scope})
   ```
   This ensures future sessions can reference historical estimates for calibration.

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

Ready to implement? Consider `/nase:fsd` for autonomous execution.

</workflow>
