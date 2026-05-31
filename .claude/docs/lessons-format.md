# lessons.md — format and write policy

Canonical structure for `workspace/tasks/lessons.md`. Every skill that appends to this file follows this contract.

## Entry header

```
## {category} -- {YYYY-MM-DD} -- {rule or pattern title}
```

- Separator is `--` (double-hyphen), not em-dash.
- Date is the day the lesson was captured (not when the underlying event happened).
- Title is a one-line description of the rule, not the situation.

## Categories

| Category | Use for |
|----------|---------|
| `workflow` | Process / multi-step procedure improvements |
| `code` | General coding patterns, gotchas, language-specific rules |
| `debugging` | Bug-find techniques, root-cause patterns |
| `ops` | Operational / deployment / oncall lessons |
| `infra` | Infrastructure, CI, build system |
| `style` | Communication-style rules captured from user corrections |
| `calibration` | ETA accuracy or daily-score calibration (written by `/nase:wrap-up`) |

Pick the closest match. Do not invent new categories — extend this list instead.

## Body

```
**When:** {situation this applies to}
**Do:** {concrete action or rule}
```

`calibration` entries use a different body — see `/nase:wrap-up` Step 4b.

## Writers

| Skill | Category | Trigger |
|-------|----------|---------|
| `/nase:reflect` | any | After a task, on surprise / mistake / discovery |
| `/nase:wrap-up` Step 4b | `calibration` | When ETA divergence ≥ 30% |
| `/nase:wrap-up` Step 4e | `style` | When approved style deltas update `workspace/communication-style.md` |
| `/nase:address-comments` Phase 10 | `code` | When a reviewer surfaced a non-obvious coding rule |
| `/nase:extract-skills` | any | When a hard-won lesson surfaces during skill extraction |
| `/nase:fsd` Phase 9 | any | Only if the run produced a surprise or near-miss (see § Signal-to-noise) |

## Signal-to-noise

Downstream skill-optimization tooling mines this file for skill changes. Routine no-surprise wins dilute the signal. Skip the write when:

- The task completed cleanly with no surprises, no corrections, no retries.
- The lesson is already captured (search the file before appending).
- The "rule" is generic engineering advice with no concrete trigger.

Silence is acceptable. Notability bar applies — same as KB writes.

## Promotion

`/nase:kb-review` Step 6 promotes mature lessons to KB files (`workspace/kb/general/` or `workspace/kb/projects/`). When promoted, append a `> Promoted → {kb-file}` line to the lesson entry but keep the entry in place.
