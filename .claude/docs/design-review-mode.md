# Review Mode (`/nase:design --review`)

Re-evaluate an existing design doc against the current codebase and KB. Verdict: APPROVED, Needs Revision, or Superseded.

## Activation

Trigger: `$ARGUMENTS` contains `--review` (anywhere in the args), OR auto-detected when a slug in `$ARGUMENTS` already exists as `workspace/efforts/{slug}.md`. Strip `--review` from `$ARGUMENTS` before parsing the rest. Skip the normal `/nase:design` Phase 1–5 flow and follow this algorithm instead.

## Step 1: Resolve Target Effort Doc

Resolve in priority order:

1. **Slug match** — if remaining `$ARGUMENTS` contains a token matching `workspace/efforts/{slug}.md`, that is the target.
2. **Empty args** — list `workspace/efforts/*.md` (recent first) via `AskUserQuestion` and let user pick.
3. If no effort docs exist: stop and tell user to run `/nase:design` first.

Read the resolved effort doc. Hold path as `effort_path`.

## Step 2: Gather Current State

Run in parallel:

- **Git log** — changes in the target repo since the effort doc's `created:` date:
  ```bash
  git -C {repo} log --oneline --since="{created-date}" -- {relevant paths}
  ```
- **KB delta** — re-read the domain KB file(s) relevant to this effort. Note any constraints added or changed since design was written.
- **Open questions** — scan the effort doc's `## Open Questions` section for unresolved items.
- **Grill sessions** — if `## Grill Session` blocks exist, read the latest constraints for implementation.

## Step 3: Evaluate Against Quality Criteria

Score every criterion from the Quality Criteria table (in `/nase:design`):

| Criterion | PASS / WEAK / FAIL |
|-----------|-------------------|
| Specificity | |
| Testability | |
| Grounding | |
| Scope clarity | |
| Risk coverage | |
| KB alignment | |

Also check for **staleness**: has the codebase or KB changed in ways that invalidate assumptions in the design?

## Step 4: Verdict

Determine one of three verdicts:

### APPROVED

All criteria PASS or at most 1 WEAK, and no staleness issues. The design holds.

Present the scorecard to the user, then ask via `AskUserQuestion`:

```
question: "Design looks good. What's next?"
header: "Next Step"
options:
  - label: "Start implementation"  , description: "Engage /nase:fsd {slug} for autonomous implementation"
  - label: "Another review round"  , description: "Re-run review after more grill sessions or manual edits"
  - label: "Park it"               , description: "Come back later — surfaces in /nase:today"
```

### Needs Revision

Any FAIL, or 2+ WEAK, or staleness detected. List specific issues:

```markdown
## Issues found

- **{criterion}**: {concrete gap — e.g., "Success criterion 2 says 'fast' with no metric"}
- **Staleness**: {what changed — e.g., "KB added caching constraint in auth domain, not reflected in design"}
```

Update the effort doc's `## Open Questions` with the issues. Set `status: needs-revision` in frontmatter. Tell the user to address the issues and re-run `/nase:design --review {slug}`.

### Superseded

Requirements changed enough to warrant a fresh design (e.g., the target repo was replaced, the feature scope is fundamentally different). Archive the old doc:

```bash
mv workspace/efforts/{slug}.md workspace/efforts/{slug}-v1.md
```

Tell the user the doc is archived and suggest running `/nase:design {new-idea}` to start fresh.

## Step 5: Daily Log

Append to `workspace/logs/YYYY-MM-DD.md`:

`reviewed {slug} — {verdict}: {1-line summary of key finding}`

## Notes

- The Hard Gate from `/nase:design` applies here too: no code edits, no PR, no Jira (unless verdict is APPROVED and user picks "Start implementation").
- If `--review` is combined with `--grill` in the same invocation, run review first, then grill the result if APPROVED.
