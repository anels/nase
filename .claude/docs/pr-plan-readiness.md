# PR Plan Readiness

Shared by `/nase:design` (writes the `### PR Plan`) and `/nase:fsd` (reads it to pick what to build). One schema, one rule, so the design says which PRs can start now and fsd does not re-guess.

## Contents

- PR Plan schema
- The fsd-ready rule
- Stacking
- Parallel-safety (file overlap)
- Reading a plan without the schema

## PR Plan schema

Write one row per planned PR, including when `Target PR count: 1`.

```markdown
### PR Plan
Target PR count: 4

| PR | Scope | Depends on | External blockers | Touches | fsd-ready |
|---|---|---|---|---|---|
| PR1 | add the cache interface | none | none | `src/cache/*` | yes |
| PR2 | wire the health probe | none | none | `src/health/*` | yes |
| PR3 | switch callers to the cache | PR1 | none | `src/api/*` | yes - stacks on PR1 |
| PR4 | cut traffic over after PR3 is deployed | PR3 | PR3 deployed to prod | `infra/*` | no - waits on the PR3 deploy |
```

- `Depends on`: `none`, or PR ids whose code this PR builds on. Whether that forces a wait is decided by the rule below, not by this column.
- `External blockers`: `none`, or each thing outside this plan that must happen first, named with an owner or link.
- `Touches`: the paths the PR is expected to edit, from the design's topology. Directory globs are fine. When the plan spans repos, prefix each path with its repo (`repo-a:src/cache/*`) so identical relative paths in different repos are not read as an overlap.
- `fsd-ready`: `yes`, `yes - stacks on {PR}`, or `no - {reason}` naming the PR or blocker. It is derived by the rule below, never set by hand.

State the evidence for each `none` in a short note under the table or in the row's `Scope` cell. The cell keeps the value; the note keeps the claim checkable.

## The fsd-ready rule

A PR is ready (`yes` or `yes - stacks on {PR}`) only when **both** hold:

1. `Depends on` is `none`, or every dependency is stackable (see *Stacking*). A dependency that is only "this code builds on that code" does not make a PR wait, because fsd opens it on top of the other PR's branch.
2. `External blockers` is `none`.

What counts as an external blocker. Any of these makes the PR `no`:

- another team's change, API, or release that must land first
- a decision, approval, or open question that a human has not answered
- access, credentials, a provisioned resource, or a feature flag that does not exist yet
- an upstream package publish or a deploy the PR's code or tests need
- data or schema migration that has to run before the code is exercised

The evidence standard is the design's own: ground each `none` in the code, the KB, or a linked ticket the way the design grounds any other claim. A blocker you did not look for is not `none`.

When either field is unknown rather than proven `none`, the row is `no - evidence missing`. Do not guess `yes`; `/nase:fsd` asks once about rows that are unproven only because a legacy plan is silent (`.claude/docs/fsd-parallel-prs.md`).

A PR the design splits off because of a rollout or release boundary is usually `no`, because the boundary is an external blocker (a deploy must happen between the two merges). Say so in the row.

## Stacking

A stack is a chain of PRs in one repo where each PR targets the branch of the PR below it, and the bottom PR targets the default branch. PRs merge bottom-up. With a native stack, GitHub rebases and retargets the rest when the bottom PR merges. With a plain base chain GitHub does not rebase after a squash merge, so each child needs `git rebase --onto origin/{default_branch} {old_parent_head}` before it merges. `/nase:prep-merge` does not do that yet. Each reviewer sees only the diff of their own layer.

A PR is **stackable** on a parent when all of these hold:

- Every `Depends on` PR is in this plan and in the same repo as this PR. A stack cannot cross repos or forks.
- The dependencies form one chain. The parent is the nearest PR, and every other dependency is something the parent itself depends on, directly or transitively. Two independent parents (a diamond) cannot both be a base.
- The parent is ready (`yes` or `yes - stacks on`), or its PR is already open and fsd opened it (its `## Lifecycle` row is ticked). A parent that is `no`, or whose PR was closed unmerged, makes this PR `no - waits on {parent}`.
- `External blockers` is `none` for this PR and for every PR below it in the chain, because the stack ships bottom-up.

A dependency that fails any of these is not stackable. The row is `no - waits on {PR} to merge`, and the human merge is the dependency.

Prefer a chain the reviewer can read layer by layer. When a dependency is only a type or an interface the upper PR uses, stacking is cheap. When two PRs would be read together anyway, merge them instead (see *Parallel-safety*).

## Parallel-safety (file overlap)

Two ready PRs that share a `Touches` path in the same repo will conflict when the second merges, unless one is stacked on the other (directly or through a chain). The upper PR of a stack is built on the lower one, so their overlap is expected. Resolve any other overlap in the design, in this order:

1. Merge the two PRs if one reviewer would read them together anyway.
2. Otherwise make the later one depend on the earlier one, which turns it into `yes - stacks on {PR}`.
3. Keep both ready and unstacked only when the overlap is a generated file or a one-line registry entry. Say which in the `Touches` cell.

Two PRs stacked on the same parent are siblings, not a chain. They conflict with each other when they share a path, so apply the same steps.

`/nase:fsd` re-checks the overlap and defers the later PR when the design left one unresolved. See `.claude/docs/fsd-parallel-prs.md`.

## Reading a plan without the schema

Older effort docs have a `### PR Plan` in prose or an SE/phase table with no readiness columns. Derive conservatively and state the result so it can be corrected:

- `Depends on` comes from the stated dependency order. A PR with no stated predecessor is `none`. A stated predecessor is stackable only when the *Stacking* conditions are provable from the doc; otherwise the row is `no - waits on {PR} to merge`.
- `External blockers` comes from open questions, `Dependency & Discovery Fields` frontmatter, and anything the doc names as waiting on someone else. When the doc is silent, the PR is **not** ready: unknown is not `none`.
- Say `derived from prose, not from the schema` next to the result.
