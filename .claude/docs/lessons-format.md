# lessons.md - format and write policy

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

Pick the closest match. Do not invent new categories - extend this list instead.

## Body

```
**When:** {situation this applies to}
**Do:** {concrete action or rule}
```

`calibration` entries use a different body - see `/nase:wrap-up` Step 6.

## Writers

| Skill | Category | Trigger |
|-------|----------|---------|
| `/nase:reflect` | any | After a task, on surprise / mistake / discovery |
| `/nase:wrap-up` Step 6 | `calibration` | When ETA divergence ≥ 30% |
| `/nase:wrap-up` Step 9 | `style` | When approved style deltas update `workspace/communication-style.md` |
| `/nase:address-comments` Phase 10 | any but `style`, `calibration` | Every run decides (see § Writing a lesson from a run) |
| `/nase:extract-skills` | any | When a hard-won lesson surfaces during skill extraction |
| `/nase:fsd` Phase 10 | any but `style`, `calibration` | Only if the run produced a surprise or near-miss (see § Writing a lesson from a run) |

## Readers

`.claude/scripts/lessons-lookup.py` prints the best few entries for a task. It skips `calibration` and `style` entries, entries whose title carries `-> applied to` because a doc already holds that rule, and entries whose title carries `-> rejected`. It reads only `## {category} -- {date} -- {title}` entries, so the one-line `- {date} ...` archive bullets are never returned.

| Skill | Where it runs |
|-------|---------------|
| `/nase:address-comments` | Phase 3, Step 3-0 |
| `/nase:fsd` | Phase 3, Lessons preflight |

## Writing a lesson from a run

A candidate comes from the run and is verified in it. It is a rule a reviewer or user surfaced that the code did not already follow, a guard, hook, or tool behavior that blocked or surprised you, a documented step that failed as written, or a repo constraint you confirmed in code.

- A constraint that belongs to one repo goes through `/nase:kb-update {repo}`, which applies `.claude/docs/kb-write-routing.md -> Shared admission contract`.
- A rule that holds across repos goes to this file, staged through `.claude/docs/workspace-write-guard.md`. Pick the closest category and search the file for the same rule first.

Write without asking, except a wording correction on an external draft, which follows `.claude/docs/style-delta-capture.md`. Name the skill, the tool, or the file path where the trap lives in the `When:` line, because `lessons-lookup.py` matches on those words.

## Signal-to-noise

Downstream skill-optimization tooling mines this file for skill changes. Routine no-surprise wins dilute the signal. Skip the write when:

- The task completed cleanly with no surprises, no corrections, no retries.
- The lesson is already captured (search the file before appending).
- The "rule" is generic engineering advice with no concrete trigger.

Silence is acceptable. Notability bar applies - same as KB writes.

## Promotion

`/nase:kb-review` identifies mature lesson-promotion candidates under *Deep review -> Content and relationships*. After an approved promotion to `workspace/kb/general/` or `workspace/kb/projects/`, append a `> Promoted -> {kb-file}` line to the lesson entry but keep the entry in place.
