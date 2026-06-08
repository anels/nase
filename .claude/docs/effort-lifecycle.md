# Effort Lifecycle

Shared rules for `workspace/efforts/{slug}.md` and related `todo.md` entries.
Callers own inferring the slug; this doc owns status names and lifecycle edits.

All full-file writes use `.claude/docs/workspace-write-guard.md` and
`workspace-write-guard.py`. Auto-write modes only skip human confirmation; they
never skip final drift checks.

## Design Creation

Used by `/nase:design` Phase 5.

Create `workspace/efforts/{slug}.md` with:

```yaml
---
status: planned
created: {YYYY-MM-DD}
scope: {quick-fix|feature|initiative|exploration}
repo: {repo-name or "multiple"}
---
```

Initial lifecycle:

```markdown
## Lifecycle
- [x] Design approved — {YYYY-MM-DD}
- [ ] Implementation started
- [ ] PR opened
- [ ] Review passed
- [ ] Merged
- [ ] Deployed (if applicable)
```

Append a matching pending task to `workspace/tasks/todo.md`:

```markdown
- [ ] **{Title}** — {one-line summary} -> `workspace/efforts/{slug}.md`
```

## FSD Update

Used by `/nase:fsd` Phase 8b when `$ARGUMENTS` contains a slug matching
`workspace/efforts/{slug}.md`.

- `- [ ] Implementation started` -> `- [x] Implementation started — {YYYY-MM-DD}`
- `- [ ] PR opened` -> `- [x] PR opened — {PR URL or branch_name}` when a PR or branch exists
- Frontmatter `status:` -> `in-progress`

Skip silently if no slug can be inferred.

## Prep-Merge Update

Used by `/nase:prep-merge` after the PR branch is prepared and reviewer comments
are resolved.

- `- [ ] Review passed` -> `- [x] Review passed — {YYYY-MM-DD}`
- Frontmatter `status:` -> `merge-ready`

Do not mark `Merged`; actual merge is a human action on GitHub.

## Wrap-Up Read Path

`/nase:wrap-up` may summarize active efforts but should not invent lifecycle
state. If it needs to fix stale lifecycle fields, it follows this doc and the
workspace write guard.
