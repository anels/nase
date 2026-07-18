# Effort Lifecycle

Shared rules for `workspace/efforts/{slug}.md` and related `todo.md` entries.
Callers own inferring the slug; this doc owns status names and lifecycle edits.

All full-file writes use `.claude/docs/workspace-write-guard.md` and
`workspace-write-guard.py`. Auto-write modes only skip human confirmation; they
never skip final drift checks.

## Stage Classifier

`/nase:today` and `/nase:efforts` classify an active effort through:

```bash
python3 .claude/scripts/effort-state.py --file workspace/efforts/{slug}.md
```

The JSON result is the only stage contract. It scans the whole document for checked
canonical labels in monotonic order: `Implementation started`, `PR opened`,
`Merged`, then `Deployed`. It ignores unrelated plan and grill checkboxes, falls
back to frontmatter only when no canonical label is checked, and flags frontmatter
conflicts with `needs_live_verification`. A deployed effort with pending
`Follow-up:` checkboxes is `follow_up_only`.

## Status Vocabulary

Frontmatter `status:` for `workspace/efforts/{slug}.md`. This is the authoritative
list; `/nase:kb-review` Step 4d validates against it.

**Active** (file lives directly in `workspace/efforts/`):

| status | meaning |
|---|---|
| `planned` | design approved, implementation not started |
| `in-progress` | implementation underway (set by `/nase:fsd`) |
| `needs-revision` | PR open but review/CI sent it back for changes |
| `blocked` | progress halted on an external dependency |
| `merge-ready` | review passed, awaiting human merge (set by `/nase:prep-merge`) |
| `awaiting-deploy` | PR merged; awaiting deploy + post-deploy validation before close |
| `tracked` | tracking-only effort someone else implements |
| `ready` | reserved alias for `merge-ready`/`planned`-complete states |

**Done** (file moved to `workspace/efforts/done/`):

| status | meaning |
|---|---|
| `completed` | shipped and verified |
| `wontfix` | closed without shipping |

`awaiting-deploy` is set by the Drift Auto-Sync rule below when delivery PRs merge,
or by hand when needed, paired with `- [x] Merged` in the Lifecycle block. The
effort moves to `done/` + `completed` only after deploy validation passes.

## Drift Auto-Sync

The deterministic lifecycle rule, applied by **both** `/nase:today` (Step 1b-v)
and `/nase:efforts` (Step 3). Both callers keep delivery, report-only, and dependency
PR sets separate, use *PR Reference Resolution* only to normalize/query each set, then
pass the live delivery states to `effort-state.py`. The helper output is the executable
source of truth for the transition.

```bash
python3 .claude/scripts/effort-state.py \
  --file workspace/efforts/{slug}.md \
  --evaluate-transition \
  --delivery-pr-state MERGED \
  --jira-state done
```

Repeat `--delivery-pr-state` for multiple PRs; valid values are `OPEN`, `MERGED`,
`CLOSED`, and `UNREADABLE`. Jira state is `untracked`, `done`, `not-done`, or
`unreadable`. Add `--blocked-by-unresolved` when any blocker remains unresolved.
Use `transition.action` (`none`, `update`, or `move`) and `transition.status` exactly;
do not independently reinterpret the rules below.

After the live reads, per active effort:

- Build the delivery PR set only from `pr`, `prs`, and `phase_*_pr` frontmatter
  plus checked canonical `PR opened` lifecycle lines. Other body PR references are
  context only. `blocked-by` PRs resolve dependencies but never count as delivery
  evidence. A transition requires at least one readable delivery PR; Jira-only and
  no-PR efforts remain active.
- Any unreadable delivery PR or tracked Jira referent → skip that effort's transition;
  it stays active and is reported as unresolved.
- Any unresolved `blocked-by` referent → no lifecycle transition.
- Any delivery PR still `OPEN` → no change.
- With no open delivery PR, at least one `MERGED` delivery PR, and Jira (if tracked)
  `Done`, use the merged path; closed superseded siblings do not block it:
  - deploy validation incomplete → set `status: awaiting-deploy` if needed and
    leave the file active.
  - canonical classifier reports checked `Deployed` evidence with no pending
    follow-up → set `status: completed` and move to `workspace/efforts/done/`.
- If all readable delivery PRs are `CLOSED`-not-merged, set `status: wontfix` and
  move to `workspace/efforts/done/`.

**Write path.** These transitions qualify for the `.claude/docs/workspace-write-guard.md`
auto-accept path because their evidence and target are deterministic. Stage the
frontmatter change under `workspace/tmp/`. Use the normal guarded `apply` when the file
stays active. For terminal transitions, use the guard's `apply-move` operation; never
run `apply` followed by `mv`. If the source drifts or `done/{slug}.md` already exists,
preserve the staged draft and leave the source active. Log each applied transition.

Completed effort retention uses `workspace-write-guard.py move-existing` with the
60-day age gate. The operation refuses an existing archive destination and leaves
both files unchanged, so a same-name archive is never overwritten.

## Dependency & Discovery Fields

Two optional frontmatter keys make dependencies first-class instead of prose buried
in the body, so `/nase:efforts` can compute an unblocked-work view without parsing
each doc body. Both are optional — omit when not applicable.

| field | value | meaning |
|---|---|---|
| `blocked-by` | effort slug, PR reference, Jira key, or short free text | this effort cannot proceed until the referent clears |
| `discovered-from` | effort slug, PR reference, or incident/ticket ref | this effort was spun off while working the referent (captures work that would otherwise be noticed and lost) |

`blocked-by` may be a single value or a YAML list. Clearing the blocker: remove the
key (or set `status:` off `blocked`). A blocker counts resolved when an effort slug is
in `done/`, a PR is merged, or a Jira issue is Done. Short free text has no resolver,
so it stays unresolved until removed.

**Computed "unblocked" view** (read-only, no stored field): an active effort is
*unblocked* when `status:` is not `blocked` **and** it has no unresolved `blocked-by`.
This is distinct from the `ready` status token above (which is a manual alias). Callers
must compute unblocked from `status` + `blocked-by`, never store it.

## PR Reference Resolution

Any skill that live-checks an effort's PRs (drift check, stage classification, deploy
state) must find **every** PR the doc names — not just the ones written as full URLs.
Effort docs cite PRs three ways, and older docs lean on the shorthand:

1. **Full URL** — `https://github.com/{owner}/{repo}/pull/{n}` — anywhere in the body.
2. **Qualified shorthand** — `{owner}/{repo}#{n}` (e.g. `UiPath/Insights#4640`) — anywhere.
3. **Bare number** — `#{n}` (e.g. `#4640`) — resolve **only** inside the `## Lifecycle`
   section and `blocked-by`, where a `#{n}` is definitionally a PR. Resolve its repo from
   the nearest qualified/full reference in the doc, else from the `repo:` frontmatter under
   the `UiPath` org (`UiPath/{repo}`). Do **not** treat bare `#{n}` in prose as a PR — bodies
   are full of non-PR `#{n}` (CHANGELOG entries, `grill #3`, `Codex Q10`, RFC markers), so a
   greedy bare-`#` sweep produces false PRs.

Normalize each hit to `{owner}/{repo}` + number and verify read-only with
`gh pr view {n} --repo {owner}/{repo} --json state,reviewDecision,statusCheckRollup,mergedAt`.
Dedupe across the three forms (the same PR often appears as both a URL and a `#{n}`).

**Why this matters:** frontmatter `status:` drifts; PR state is the ground truth that
corrects it. URL-only extraction misses shorthand and can mis-bucket shipped work as
planning, hiding the drift this check exists to catch.

## Single-File Invariant

One effort = one file: `workspace/efforts/{slug}.md`. Do **not** spawn per-phase
sidecar files (`{slug}-phase-2.md`, `{slug}-plan-v3.md`, etc.) — that is the failure
mode that decays into hundreds of orphan plan files. All phase progress appends to the
single doc: check the `## Lifecycle` boxes, add `phase_*_pr:` frontmatter pointers for
per-phase PRs, and append notes in-place. A restarting agent re-reads the one doc rather
than reconstructing intent from a pile of stale siblings.

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
