---
name: nase:design
description: "Research and write an implementation design without coding. Use for design, brainstorm, plan feature, kickoff, grill plan, or review a design."
argument-hint: "<feature/request> [--auto|--interactive|--grill|--review]"
pattern: pipeline
category: Design & implementation
sub-patterns: [fan-out]
---

Turn a request into a concrete, tracked, junior-implementable design. This command never edits product code.

Follow `.claude/docs/workspace-write-guard.md`, `.claude/docs/effort-lifecycle.md`, and `.claude/docs/external-mutation-policy.md`. Use `python3 .claude/scripts/workspace-write-guard.py stage` for effort writes; auto mode may skip the prompt, never staging, preview, or drift checks.

## Core contract

1. Run `.claude/docs/language-config.md` first. Use `conversation:` for chat and `output:` for the effort doc.
2. Apply `.claude/docs/design-principles.md`. Choose the simplest high-quality long-term shape. Development cost informs ETA, not design selection.
3. Default to one PR. Split into multiple PRs only when a repo, compatibility/rollout, mechanical-noise, 1500-line review, or distinct-owner boundary makes one PR harder to review safely.
4. Record `Target PR count`, dependency order for a split, `Reviewability`, and `Validation - how to get the real number`.
5. Ask only questions that code, KB, docs, history, telemetry, or official sources cannot answer. Batch genuine human decisions.

## Mode routing

Strip the first matching flag and route in this order:

- `--grill`: read `.claude/docs/design-grill-mode.md`.
- `--review`, or an existing effort slug: read `.claude/docs/design-review-mode.md`.
- `--interactive`: follow the workflow below with one approach-choice checkpoint.
- `--auto`, or no flag: read `.claude/docs/design-auto-mode.md`.

If `$ARGUMENTS` is empty, ask for the request. Resolve repo and KB context before asking anything else.

## Interactive workflow

Read `.claude/docs/design-research.md` for external research, plan gates, and implementation readiness. Read `.claude/docs/eta-estimation.md` for the ETA section.

For non-trivial work, run read-only `nase-context-kb-researcher`, `nase-repo-state-scanner`, and `nase-workspace-state-scanner` in parallel. The main thread owns design synthesis and workspace writes. Reconcile conflicting evidence before presenting options.

1. Resolve the repo with `.claude/docs/repo-resolution.md`. Load relevant KB, repo `CLAUDE.md`/README/docs, code paths, callers, tests, history, active efforts, and primary external sources.
2. Prove applicable reproduction, root cause, scale/usage, coverage, rollout, and observability assumptions. Mark missing evidence as a gap that cannot support another claim.
3. Map entry points, changed functions/types, downstream callers, tests, and operational surfaces. Do not invent paths.
4. Present 2-3 materially distinct options together with principle alignment, operational tradeoffs, KB/source citations, PR shape, and a recommendation. Quick fixes may use two one-line options.
5. Produce the design with: context; goals/non-goals; scope; exact files/interfaces/data contracts; success criteria; runnable validation; risks; ordered implementation steps with tests/done conditions; ETA; PR plan; open questions.
6. Self-review up to three times against the quality criteria below. Research fixable gaps before asking the user.
7. Stage the complete effort doc, show the diff, and apply with recorded mtime/hash/staged hash. Follow `.claude/docs/effort-lifecycle.md` for frontmatter and initial state.
8. Optional Jira creation uses a fresh payload-bound token and a concrete approval immediately before the write.
9. Stop after saving. Chat returns the file path and a short decision summary.

## Quality criteria

- Specificity: measurable values replace vague adjectives.
- Testability: success criteria are observable and have runnable checks.
- Grounding: load-bearing claims cite paths, commands, telemetry, or primary sources.
- Scope: goals and non-goals define clear boundaries.
- Root cause: bug designs include reproduction evidence and fix the originating cause.
- Risk: failure, migration, rollout, security, observability, and recovery paths are addressed where applicable.
- Elegance: few moving parts, clear ownership, existing patterns, no speculative layer.
- Reviewability: one PR by default; justified splits include order and independent value.
- Readiness: a junior can implement without making another design decision.
- ETA: derived from the implementation steps with an honest confidence range.

## Lifecycle

This command creates or updates the effort design. `/nase:fsd`, `/nase:prep-merge`, and `/nase:wrap-up` own later lifecycle transitions through `.claude/docs/effort-lifecycle.md`.

Scale depth to the task: a quick fix gets a compact design; an initiative gets full decomposition. The durable artifact is the effort doc, not the chat transcript.
