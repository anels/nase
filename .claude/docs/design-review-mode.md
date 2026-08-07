# Review Mode (`/nase:design --review`)

## Contents

- Activation
- Step 1: Resolve Target Effort Doc
- Step 1b: Resolve Human Input (if present)
- Step 1.5: Resolve Target Repo
- Step 2: Gather Current State
- Step 2.5: Walk the Unresolved Human-Input Items
- Step 3: Evaluate Against Quality Criteria
- Step 3.5: Doc Hygiene Pass (auto-cleanup)
- Step 4: Verdict
- Issues found
- Step 5: Daily Log
- Notes

Re-evaluate an existing design doc against the current codebase and KB. Verdict: ALREADY SHIPPED, APPROVED, Needs Revision, or Superseded.

## Activation

Trigger: `$ARGUMENTS` contains `--review` (anywhere in the args), OR auto-detected when a slug in `$ARGUMENTS` already exists as `workspace/efforts/{slug}.md`. Strip `--review` from `$ARGUMENTS` before parsing the rest. Skip the base interactive workflow and follow this algorithm instead.

## Step 1: Resolve Target Effort Doc

Resolve in priority order:

1. **Slug match** — if remaining `$ARGUMENTS` contains a token matching `workspace/efforts/{slug}.md`, that is the target.
2. **Empty args** — list `workspace/efforts/*.md` (recent first) via `AskUserQuestion` and let user pick.
3. If no effort docs exist: stop and tell user to run `/nase:design` first.

Read the resolved effort doc. Hold path as `effort_path`.

## Step 1b: Resolve Human Input (if present)

Before scoring against quality criteria, look for a `## Human Input Required` section in the effort doc (typically populated by Auto Mode — `design-auto-mode.md` Step 5b).

If the section exists and has at least one row, put every row to the user via `AskUserQuestion`, batched per `.claude/docs/skill-authoring-contract.md` → §5: up to 4 rows per call, each row its own single-decision question. Batching is not just a token economy — a user who sees the whole set at once can spot that two rows are really one decision, which they cannot do when the questions arrive one screen at a time.

For each H-row, build one entry in the `questions` array from the row data:

- **`question`** — copy the `Question` cell verbatim, prefixed with the row id (e.g. "H1 — Should PR-D1 also add ...").
- **`header`** — short label (≤12 chars) derived from the row id + topic (e.g. "H1 LANG CI", "H2 Sequencing").
- **`options`** — 2–4 mutually exclusive choices.
  - **First option** = the `Default assumption used` cell, appended with " (Recommended)". `description` explains *why* the default is recommended — quote the reasoning the design doc captured during the grill pass.
  - **Subsequent options** = the explicit alternative(s) implied by the question. If the question is binary (the most common case), there are two options. If the question lists 3+ branches, surface up to 4 (`AskUserQuestion` max).
  - For each non-default option, `description` states the trade-off so the user can choose against the recommendation with full information.
- **`multiSelect: false`** — H-rows are decisions, not multi-choice.

After each batch returns:

1. Apply the decision to the relevant design sections (Scope, Design, Decomposition, Risks, Success Criteria — use the `Affects` cell as the routing hint).
2. Remove the H-row from `## Human Input Required`.
3. Append a row to a new `### Resolved Decisions` block immediately above (or below) the now-empty `## Human Input Required` section, with columns: `#`, `Question` (one-line summary), `Decision`, `Applied to`. Keep the table cumulative — past resolutions stay visible as decision audit trail.

When every H-row is resolved:

- Delete the empty `## Human Input Required` heading entirely (leave only `### Resolved Decisions`).
- Update frontmatter: add `human_input_resolved: {YYYY-MM-DD}` and, if `status: needs-revision`, flip to `status: ready`.
- Add a `Lifecycle` entry: `- [x] Human Input resolved — {YYYY-MM-DD} ({short summary of each H decision})`.

Then proceed to Step 2. If the section is absent or empty, skip this step entirely.

## Step 1.5: Resolve Target Repo

Read the effort doc's frontmatter `repo:` field and resolve it through `.claude/docs/repo-resolution.md` Part 1. If it is absent or `multiple`, ask the user to choose from `workspace/context.md`. Hold the absolute path as `repo_path`; stop if it is not a Git repository.

## Step 2: Gather Current State

First follow `.claude/docs/open-work-freshness.md`. It resolves and fetches `default_branch`, reads implementation and tests at the verified remote ref, repairs `already_done` scope through the workspace write guard, and returns `freshness_outcome`. On `blocked`, skip scoring and continue to **Needs Revision**. On `already_shipped`, skip scoring and continue to **ALREADY SHIPPED**. On `continue`, score the repaired effort doc.

Run in parallel:

- **Git log** — changes in the target repo since the effort doc's `created:` date:
  ```bash
  git -C {repo_path} log --oneline --since="{created_date}" "{fresh_default_oid}" -- "{relevant_path}"
  ```
- **KB delta** — re-read the domain KB file(s) relevant to this effort. Note any constraints added or changed since design was written.
- **Open questions** — scan the effort doc's `## Open Questions` section for unresolved items.
- **Grill sessions** — if `## Grill Session` blocks exist, read the latest constraints for implementation.
- **Preconditions** — re-verify the design's load-bearing premises, not just its code anchors. Git freshness only covers claims about the repo; a design usually also rests on state that lives outside it — a deploy having landed or not, a flag's value in an environment, an alert existing, a dependency still being slow, a sibling effort's status, a ticket still being open. Those flip without a commit, so `freshness_outcome = continue` is not evidence that they still hold.

  Build the list from the claims the design would collapse without: whatever the latest grill recorded as its grounded premise, plus anything a Success Criterion, Risk mitigation, or scope decision cites as *currently true*. Re-run the same query or command that established each one, and compare against the recorded value rather than re-deriving a fresh conclusion. Two failure modes matter: a premise that flipped (the design is now built on something false) and a premise that can no longer be checked (the command errors, the resource is gone, access was lost) — the second is not a pass. A flipped or uncheckable premise is a **Staleness** issue in Step 4, and if the design's core approach rests on it, that is a `Superseded` verdict rather than `Needs Revision`. Preconditions confirmed unchanged get one line in the report with the value and the timestamp, so the next review can diff against it instead of re-deriving.

## Step 2.5: Walk the Unresolved Human-Input Items

Step 1b covers `## Human Input Required`, which only Auto Mode writes. Most docs carry their unresolved decisions somewhere else — `## Open Questions`, the latest grill's `### Open after grill`, leftover `[NEEDS CLARIFICATION: …]` markers — and those have historically been read, scored, and written back without ever being put to the user. A question that has sat in a doc through three reviews is not "tracked", it is stuck; the point of this step is that a review either resolves an open item or says out loud why it cannot be resolved yet.

This runs after Step 2 on purpose. Half of what looks like an open question is already answered by the code, the freshness result, or the KB delta you just gathered, and asking the user something the evidence settles is the failure this whole skill exists to prevent.

1. **Collect** every unresolved item from the three sources above into one list. Deduplicate — the same question often appears in both `## Open Questions` and `### Open after grill`.

2. **Try to close each one from evidence first**, using what Step 2 already gathered plus a targeted lookup where it is cheap. Anything the evidence answers is recorded as resolved with its citation and never reaches the user.

3. **Classify what survives:**
   - **decidable-now** — the user can settle it in this session. Scope boundaries between two live efforts, whether to park or pursue an item, which of two valid targets to commit to, ordering, ownership. These are the ones worth asking.
   - **externally-blocked** — only a named third party can answer (another team's inventory, an owner's approval, a vendor's behavior). Do **not** ask the question itself; the user cannot answer it either, and asking converts a real blocker into noise. Ask the *meta* decision only when it changes what happens next: chase it now, proceed under a stated default, or park the effort as blocked. When the doc already records a conservative default and nothing in Step 2 changed, ask nothing — report that it remains blocked on the named party and move on.
   - **evidence-answered** — closed in step 2 above.

4. **Ask** the decidable-now items plus any live meta decisions, batched per `.claude/docs/skill-authoring-contract.md` → §5: up to 4 per `AskUserQuestion` call, each a single decision, recommendation first with the reasoning the doc already captured. Cap the whole step at 8 questions; carry the rest and say so, because a review that turns into a twenty-question interrogation gets abandoned halfway and resolves nothing.

5. **Apply and record.** Route each answer into the design sections it affects, delete the item from its source section, and append a row to `### Resolved Decisions` (`#`, `Question`, `Decision`, `Applied to`). Keep the table cumulative. Items left externally-blocked stay where they are, with the named party and what unblocks them.

6. Score Step 3 against the **updated** doc. Resolving an item here can legitimately turn a `Needs Revision` into `APPROVED` — that is the point, not an accident to be avoided.

Skip this step only when all three sources are empty.

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
| Elegance | |
| Reviewability | |

Also check for **unresolved staleness**: after the Step 2 repair, does the codebase or KB still invalidate an assumption in the design? A repaired already-shipped item remains in the audit evidence but is not reopened.

## Step 3.5: Doc Hygiene Pass (auto-cleanup)

A doc reaching review has usually been through several edit rounds and carries cruft — duplicated claims across sections, session-process artifacts, wording superseded by a prior grill, value drifts (two lines stating different numbers for the same thing). Clean it before rendering the verdict so the verdict scores the durable spec, not the accretion. This runs regardless of verdict (an APPROVED doc still benefits). It edits only the design doc (within review mode's allowed scope) and goes through the workspace-write-guard diff, so it is reviewable.

Apply the **same policy as `design-grill-mode.md` → Step 6.5** (auto-remove superseded wording / exact duplicates / session artifacts / dead-duplicate links / resolved `[NEEDS CLARIFICATION]`; list-only for judgment calls; never touch a MUST/constraint/SC/Risk/citation; flag value drifts rather than silently picking). Freshness repairs from Step 2 stay resolved. A separate stale claim with no evidence-backed replacement is a Step 4 issue, not cleanup.

Record the count in the Step 5 daily-log line and, if any judgment-call collapses were flagged, list them in the Step 4 output so the user can act on them.

## Step 4: Verdict

Determine one of four verdicts:

### ALREADY SHIPPED

Report the pinned default-branch OID, shipping commit, merged PR, and path-level implementation evidence for each requirement. Do not offer **Start implementation** or suggest FSD. Stop.

### APPROVED

All criteria PASS or at most 1 WEAK, and no unresolved staleness or freshness blocker remains. The design holds.

Present the scorecard to the user, then ask via `AskUserQuestion`:

```
question: "Design looks good. What's next?"
header: "Next Step"
options:
  - label: "Start implementation"  , description: "Run /nase:fsd {slug} for the implementation workflow"
  - label: "Another review round"  , description: "Re-run review after more grill sessions or manual edits"
  - label: "Park it"               , description: "Come back later — surfaces in /nase:today"
```

### Needs Revision

Any FAIL, 2+ WEAK, unresolved staleness, or freshness blocker. List specific issues:

```markdown
## Issues found

- **{criterion}**: {concrete gap — e.g., "Success criterion 2 says 'fast' with no metric"}
- **Staleness**: {what changed — e.g., "KB added caching constraint in auth domain, not reflected in design"}
```

Update the effort doc's `## Open Questions` with the issues. Set `status: needs-revision` in frontmatter. Tell the user to address the issues and re-run `/nase:design --review {slug}`.

An issue that is itself a user decision — an ownership boundary, a scope call, a park-or-pursue — should have been put to the user in Step 2.5 rather than written down and deferred. Only file an issue here when it needs work the user cannot do at the prompt: a design rewrite, evidence that has to be gathered, or an answer that is genuinely someone else's.

### Superseded

Requirements changed enough to warrant a fresh design (e.g., the target repo was replaced, the feature scope is fundamentally different). Archive the old doc:

```bash
mv workspace/efforts/{slug}.md workspace/efforts/{slug}-v1.md
```

Tell the user the doc is archived and suggest running `/nase:design {new-idea}` to start fresh.

## Step 5: Daily Log

Append to `workspace/logs/YYYY-MM-DD.md`:

`reviewed {slug} — {verdict}: {1-line summary of key finding} (preconditions: {N confirmed, M flipped}; human items: {A resolved, B still blocked}; hygiene: {N auto-removed, M flagged})`

## Notes

- The Hard Gate from `/nase:design` applies here too: no code edits, no PR, no Jira (unless verdict is APPROVED and user picks "Start implementation").
- If `--review` is combined with `--grill` in the same invocation, run review first, then grill the result if APPROVED.
