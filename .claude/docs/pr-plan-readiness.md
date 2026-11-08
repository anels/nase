# PR Plan Readiness

Shared by `/nase:design` (writes the `### PR Plan`) and `/nase:fsd` (reads it to pick what to build). One schema, one rule, so the design says which PRs can start now and fsd does not re-guess.

## Contents

- PR Plan schema
- The fsd-ready rule
- Parallel-safety (file overlap)
- Reading a plan without the schema

## PR Plan schema

Write one row per planned PR, including when `Target PR count: 1`.

```markdown
### PR Plan
Target PR count: 3

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|
| PR1 | add the cache interface | none | none | `src/cache/*` | yes |
| PR2 | wire the health probe | none | none | `src/health/*` | yes |
| PR3 | switch callers to the cache | PR1 | none | `src/api/*` | no - waits on PR1 |
```

- `Depends on`: `none`, or PR ids that must **merge** before this PR can be built or reviewed on its own.
- `External blockers`: `none`, or each thing outside this plan that must happen first, named with an owner or link.
- `Touches`: the paths the PR is expected to edit, from the design's topology. Directory globs are fine. When the plan spans repos, prefix each path with its repo (`repo-a:src/cache/*`) so identical relative paths in different repos are not read as an overlap.
- `fsd-ready`: `yes`, or `no - {reason}` naming the PR or blocker. It is derived by the rule below, never set by hand.

State the evidence for each `none` in a short note under the table or in the row's `Scope` cell. The cell keeps the value; the note keeps the claim checkable.

## The fsd-ready rule

A PR is `yes` only when **both** hold:

1. `Depends on` is `none`. Waiting on another PR to merge is a dependency, even when the code would compile against the other PR's branch.
2. `External blockers` is `none`.

What counts as an external blocker. Any of these makes the PR `no`:

- another team's change, API, or release that must land first
- a decision, approval, or open question that a human has not answered
- access, credentials, a provisioned resource, or a feature flag that does not exist yet
- an upstream package publish or a deploy the PR's code or tests need
- data or schema migration that has to run before the code is exercised

The evidence standard is the design's own: ground each `none` in the code, the KB, or a linked ticket the way the design grounds any other claim. A blocker you did not look for is not `none`.

When either field is unknown rather than proven `none`, the row is `no - evidence missing`. Do not guess `yes`; `/nase:fsd` asks once about rows that are unproven only because a legacy plan is silent (`.claude/docs/fsd-parallel-prs.md`).

A PR the design splits off because of a rollout or release boundary is usually `no`, because the boundary is the dependency. Say so in the row.

## Parallel-safety (file overlap)

Two `fsd-ready: yes` PRs that share a `Touches` path in the same repo will conflict when the second merges. Resolve it in the design, in this order:

1. Merge the two PRs if one reviewer would read them together anyway.
2. Otherwise make the later one depend on the earlier one, which turns it into `no - waits on {PR}`.
3. Keep both ready only when the overlap is a generated file or a one-line registry entry. Say which in the `Touches` cell.

`/nase:fsd` re-checks the overlap and defers the later PR when the design left one unresolved. See `.claude/docs/fsd-parallel-prs.md`.

## Reading a plan without the schema

Older effort docs have a `### PR Plan` in prose or an SE/phase table with no readiness columns. Derive conservatively and state the result so it can be corrected:

- `Depends on` comes from the stated dependency order. A PR with no stated predecessor is `none`.
- `External blockers` comes from open questions, `Dependency & Discovery Fields` frontmatter, and anything the doc names as waiting on someone else. When the doc is silent, the PR is **not** ready: unknown is not `none`.
- Say `derived from prose, not from the schema` next to the result.
