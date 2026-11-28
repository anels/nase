# Design Auto Mode - Human Input

Loaded from `.claude/docs/design-auto-mode.md` only when `human_input_queue` is non-empty. Auto mode talks to the user exactly once, at the end; this file owns that batch and the deferred-items table.

## Step 4.5: Resolve Human Input (the one interactive batch)

By now research, grill, and review have shrunk `human_input_queue` to only what genuinely needs a human - business or stakeholder calls, decisions with no codebase/KB/Jira/external signal. Ask them all here, together, before the final write.

1. Convert each queued item into an `AskUserQuestion` entry under the rules in *AskUserQuestion rules* below. The design-specific part: `question` is the concrete decision (not "clarify scope" but "Should the export endpoint support CSV only, or also Excel?"), and the recommended option is the default assumption the design already applied.
2. After each answer, apply the decision to the relevant design sections before moving on.
3. Anything the user skips or answers with "Other → defer" stays in `human_input_queue` for the deferred table below. Everything answered is removed from the queue.

This replaces the old "queue everything to the doc and tell the user to run `--review`" behavior: the user gets asked once, at the end, and the written doc already reflects their answers.

## AskUserQuestion rules

Design owns these rules here, so no design step needs the author-only skill-authoring doc at runtime. `design-grill-mode.md` and `design-review-mode.md` cite this section.

- Batch related questions into a single `AskUserQuestion` call (`questions` array). Multi-screen prompt sequences for the same decision are a token-burn anti-pattern.
- Show the concrete payload in the question prompt. Generic "should we proceed?" is not a gate.
- After the gate fires, act immediately on the answer. Do not wait for an additional confirmation turn.
- Recommendation first. The first option is the default the design already applied, with ` (Recommended)` appended and a `description` that gives the evidence or principle behind it. Remaining options state their trade-off. Never ask without an opinion. The harness adds "Other" as the free-form escape.
- Word each question so a plain yes accepts the recommended option. Do not phrase it as a negation ("Should we not ...") or as a challenge to the default, because then agreeing reads as saying no.- Record what the answer changed. A design whose answers alter its doc appends a `### Resolved Decisions` block with columns `#`, `Question`, `Decision`, `Applied to`, and keeps the table cumulative across runs, so a later reader can tell an auto-selected default from a human call.
- Order a large batch by load-bearingness: security, data-loss, irreversibility, and cross-team coordination first.

## Deferred items

Append `## Human Input Required` only if `human_input_queue` is still non-empty after Step 4.5 - i.e. the user deferred these at the end-of-run prompt. Most questions should be resolved by then; this section is the leftover. Place it AFTER `## Open Questions` and BEFORE `## Lifecycle`.

```markdown
## Human Input Required

You deferred these at the end-of-run prompt. Provide answers below, then run `/nase:design --review {slug}` before starting implementation.

| # | Question | Why it needs you | What was tried | Default assumption used | Affects |
|---|----------|-----------------|----------------|------------------------|---------|
| 1 | {question} | {business/stakeholder decision - no codebase signal} | {sources checked} | {conservative default} | {design section} |
```

Each row must be a concrete, actionable question - not "clarify scope" but "Should the export endpoint support CSV only, or also Excel? Default: CSV-only (matches existing download endpoints in `src/api/export.ts`)."
