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
- Compare against similar past tasks in `workspace/tasks/lessons.md` — pattern-matching beats guessing
- The pessimistic estimate is usually the realistic one

## Steps

<workflow>

1. Parse the task description from $ARGUMENTS carefully
2. Read `workspace/context.md` and `workspace/kb/.domain-map.md` to identify the relevant repo(s). If the task could span multiple repos and the target is ambiguous, ask the user which repo to focus on. Then explore the codebase to understand:
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
   This line is the calibration anchor: `/nase:wrap-up` will later compare it against actual completion time and write a calibration note to `workspace/tasks/lessons.md` if the divergence is significant.

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

Ready to implement? Consider `/nase:fsd` for autonomous execution.
