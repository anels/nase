# ETA Estimation

Shared estimation contract for `/nase:estimate-eta` (standalone estimate) and `/nase:design` (an `### ETA Estimate` section appended to the effort doc). Both turn a subtask/step breakdown into time numbers; this doc owns the principles and the confidence-range format so the two stay aligned instead of drifting into different shapes.

## Estimation Principles
- Estimates improve with familiarity — explore the codebase before committing to numbers.
- Unknowns dominate: one unclear dependency can triple the timeline.
- Compare against similar past tasks in `workspace/tasks/lessons.md` and the relevant project KB (`workspace/kb/projects/`) — pattern-matching beats guessing.
- The pessimistic estimate is usually the realistic one. Use ranges, not false precision; if the work is too vague to estimate, say so and ask rather than guess.

## Confidence Range
Roll the per-subtask estimates into three numbers, and be honest about the spread:
- **Optimistic** — everything is understood, no surprises.
- **Realistic** — the number you'd commit to; accounts for the usual friction. This is the calibration anchor.
- **Pessimistic** — a key unknown bites or a dependency slips.

Factor in complexity, unknowns, testing, review, and integration — not just happy-path coding time. The gap between optimistic and pessimistic *is* the risk signal: a wide spread means the design still carries unresolved unknowns worth naming as risks.

## Calibration Anchor (optional)
A consumer that wants `/nase:wrap-up` to compare estimate vs actual appends one line to `workspace/logs/{YYYY-MM-DD}.md`:
```
- ETA estimate: {task name} — {realistic estimate} ({scope})
```
`/nase:wrap-up` later diffs this against actual completion time and writes a calibration note to `workspace/tasks/lessons.md` on significant divergence — see `.claude/docs/lessons-format.md`.
