# KB Write Routing — `/nase:learn` vs `/nase:kb-update`

> Shared decision rule. Referenced from `/nase:learn` and `/nase:kb-update`. Edit here, not in the skills.

## The question

You have a new piece of knowledge to persist. Which skill writes it?

## Decision tree

1. **Is the insight tied to a specific codebase's internals** — an API contract, a build constraint, a naming rule, a migration gotcha, an architecture decision that only makes sense inside that repo?
   - **Yes** → `/nase:kb-update` → `workspace/kb/projects/{repo}.md` (or `decisions/`, `tech-debt/`)
   - No → continue.

2. **Is the insight a general programming pattern, stack idiom, or web-sourced article** that could plausibly apply across repos, or beyond your current stack?
   - **Yes** → `/nase:learn` → `workspace/kb/general/{domain}.md`
   - No → continue.

3. **Does the insight span two or more repos** (e.g. a cross-service contract, a shared deployment pattern)?
   - **Yes** → `/nase:kb-update` writing to `workspace/kb/cross-project/{topic}.md`
   - No → continue.

4. **Is the insight an ops / runbook / incident pattern** tied to an environment rather than to source code?
   - **Yes** → `/nase:kb-update` writing to `workspace/kb/ops/{deployment-type}.md`
   - No → reconsider whether it clears the notability bar (`kb-template.md → Writing Conventions`). If it's a generic best-practice platitude, skip the write entirely — silence is acceptable.

## Quick lookup

| If the insight is about… | Use | Target |
|---|---|---|
| A repo's API endpoint shape, auth model, internal naming | `/nase:kb-update` | `projects/<repo>.md` |
| A repo's build/test gotcha, migration constraint | `/nase:kb-update` | `projects/<repo>.md` |
| A general language feature, library idiom, framework pattern | `/nase:learn` | `general/<domain>.md` |
| An article URL, blog post, conference talk | `/nase:learn` | `general/<domain>.md` |
| A GitHub repo URL worth studying | `/nase:learn` | `general/<domain>.md` or `general/<technique>.md` |
| A cross-service contract or shared infra pattern | `/nase:kb-update` | `cross-project/<topic>.md` |
| A runbook, incident pattern, alert tuning rule | `/nase:kb-update` | `ops/<env>.md` |
| A teammate's role / org info | `/nase:kb-update` | `general/people.md` |
| A recurring mistake worth a permanent rule | `/nase:reflect` → promoted later by `/nase:kb-review` | `tasks/lessons.md` → KB |

## Reciprocal cross-link

When the same topic has both a general and a project-specific facet, write to **both** files. Each entry should:
- Frame the content for that file's scope (general = the pattern; project = the constraint).
- End with `> See also: [<other-file>](<relative-path>)` so they stay reciprocally linked.

`/nase:kb-review` checks reciprocal links under *Deep review -> Content and relationships* - if you skip one direction, it flags the gap.
