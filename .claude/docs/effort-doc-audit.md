# Effort Doc Audit

## Contents

- Part 1: Drift taxonomy
  - Repair without asking
  - Report for a human
  - Structural defects
- Part 2: Closed-effort pass (`/nase:efforts --closed`)
  - Why terminal docs need their own pass
  - Step 1: Sweep
  - Step 2: Classify each finding
  - Step 3: Apply the repairs
  - Step 4: Report and log
  - What this pass does not do

Read with `.claude/docs/effort-lifecycle.md`. That doc owns the status vocabulary, the
transition rules and the classifier blind spots; this one owns the `partial_delivery`
frontmatter contract and what to do about a doc that has drifted away from either.

Callers: `/nase:efforts` Step 3 (active efforts) and Part 2 (`--closed`);
`/nase:design --review` Step 3.5 (the doc it is reviewing).

## Part 1: Drift taxonomy

The dividing line between repairing and reporting is not how risky the edit is. It is
**whether the live reads determined the repair, or someone still has to decide what the
row means.** Guessing the second kind from prose is the failure this taxonomy exists to
prevent; parking the first kind as a question is the failure it exists to prevent in the
other direction, because a known-wrong doc that nobody edits stays wrong through every
future run.

### Repair without asking

- **`transition.stale_canonical_rows`** - an unchecked canonical `Merged` row the live PR
  states just proved merged. Flip it in the same write as the frontmatter change, per
  `effort-lifecycle.md → Drift Auto-Sync`.
- **A `likely-delivery` invisible PR** - the row's own label calls the PR this effort's and
  nothing marks it a dependency, spike, cherry-pick or withdrawal. Rewrite the label to
  canonical `PR opened` keeping the row's own number in the body, fix the prose the merge
  falsified (delivery notes still reading "all five are open"), re-run `effort-state.py`,
  apply whatever transition it returns.
- **Structural defects** below, whose repair is derivable from the doc's own content.

Check `delivery_owners` from the sweep before repairing any invisible PR. When another
effort's structured delivery set already claims that PR the sweep reports the hint as
`sibling-delivery`, and relabelling the row would transition this effort on another
effort's evidence. Measured on this workspace: two rows the text hints called
`likely-delivery` were a sibling's delivery PRs, and one of them was a grill drift-check
note that never claimed to be a delivery at all.

### Report for a human

These need a person because the repair is not derivable from live state. Name the exact
line and the suggested edit - an effort name alone makes the reader re-derive the finding.

- **`needs_live_verification` still true** after the live reads with no
  `stale_canonical_rows` offered: the checked rows and frontmatter disagree for a reason
  the PR states did not settle.
- **Non-empty `pr_references.validation_errors`**, surfacing as transition
  `reason: invalid-pr-reference` and blocking every write for that effort. Name the
  offending key and its repair per `effort-lifecycle.md → PR Reference Resolution`. Never
  report the effort as having no delivery PR - the helper never got to read one.
- **Non-empty `pr_references.discarded_bare`**, except `reason: denied-in-row` - there the
  row itself says the number is not a PR, so the classifier is right and there is nothing
  to repair. For `no-repo-context` use `owner/repo#n` or add `repo:`; for
  `outside-lifecycle` move the row under a `## Lifecycle` heading or qualify the number.
- **Real outstanding work that lives only in the Implementation Plan.** The hold scans
  `## Lifecycle` only, so such an effort auto-closes the moment its last Lifecycle row is
  ticked. The repair is to promote that deliverable to a Lifecycle row.
- **A `blocked-by` reading `none`/`n/a`** - free text with no resolver, so it reports as
  blocked. Recommend deleting the key rather than treating the placeholder as unblocked.
- **Every other invisible-PR hint** (`likely-cherry-pick`, `likely-withdrawn`,
  `likely-sibling-dependency`, `likely-spike`, `likely-phase-summary`, `likely-follow-up`,
  `sibling-delivery`). Classify, do not bulk-relabel.

### Structural defects

`effort-state.py` reports these in `structure`. They are offline-provable and their repair
comes from the doc's own content, so they are repairable without asking - but they are
easy to miss because **nothing else surfaces them**: a doc with no canonical rows falls
back to frontmatter, and that fallback is silent. No row can contradict the status, so
`needs_live_verification` never fires and the doc reads as authoritative.

| `structure` signal | defect | repair |
|---|---|---|
| `has_lifecycle_section: false`, `umbrella: false` | `no-lifecycle-section` | add a `## Lifecycle` block recording what happened |
| `partial_delivery_valid: false` | `invalid-partial-delivery` | one key, narrow `true`/`false` |
| `method: frontmatter` with a `## Lifecycle` heading present | none - report it | the section is prose with no canonical checkbox, so it carries no evidence |

An umbrella parent (`children:` in frontmatter) indexes child efforts and delivers nothing
itself, so it is exempt from `no-lifecycle-section` rather than repaired into having a
lifecycle it does not have.

## Part 2: Closed-effort pass (`/nase:efforts --closed`)

### Why terminal docs need their own pass

`/nase:efforts` counts terminal efforts without opening them, so a doc that closed with
a wrong or incomplete record keeps it forever - nothing re-reads it. Two consequences
compound:

- **The delivery record silently undercounts.** `/nase:effort-rollup` excludes
  `status: wontfix` from both the list and the headline count, which is right for an
  effort that shipped nothing. An effort whose *code* merged and deployed but whose
  verdict, activation or measurement was dropped is filed exactly the same way, so real
  shipped work disappears from the impact report. Measured on this workspace at the first
  run: four efforts, eleven merged PRs, several of them content-probe confirmed in prod.
- **A doc with no canonical rows is unfalsifiable.** `effort-state.py` falls back to
  frontmatter when nothing is checked, and that fallback is silent: no row can contradict
  the status, so `needs_live_verification` never fires and the doc reads as authoritative.

### Step 1: Sweep

```bash
python3 .claude/scripts/effort-pr-sweep.py --closed --format json
```

One pass: reads every terminal doc's structured delivery set, live-reads those PRs, and
looks for a revert commit naming each merge. `--closed` implies revert checking - the
whole output is "this merged, so record it as delivered", and a reverted merge would turn
that into a false delivery claim.

The `--closed` result carries `findings[]`, `reverts[]` and `counts` only - not the
active-mode per-effort audits or the live PR map, which would be two orders of magnitude
more output than this pass reads. Each finding carries `effort`, `path`, `defect`, and its
own `standing` and `reverted` PR lists. Only delivery PRs are live-read, so the run is a
fraction of the full sweep despite covering far more docs.

The invisible-PR audit does not run under `--closed`: it asks whether a doc would
transition on evidence that is not its own, and a terminal doc has no transition left to
fire. Run the default sweep for that.

### Step 2: Classify each finding

| `defect` | what it means | who acts |
|---|---|---|
| `partial-delivery-unrecorded` | `wontfix`, but the named delivery PRs merged and no revert names them | repair in place |
| `reverted-delivery-no-repair` | every merge was reverted; `wontfix` is the honest label | nobody - report only |
| `partial-delivery-unverified-revert-scan` | the merges stand as far as `gh` can tell, but no local clone was available to look for a revert | verify by content first |
| `no-lifecycle-section` | no `## Lifecycle` heading and no `children:` (umbrella parents are exempt) | repair in place |
| `invalid-partial-delivery` | the key is duplicated or not the narrow `true`/`false` shape | repair in place |

`partial-delivery-unverified-revert-scan` is not a weaker version of the first row - it is
the merge state with the revert question unanswered. Grep a symbol the PR *added* at the
ring commit before recording delivery, per `effort-lifecycle.md → Classifier Blind Spots`.
If the repo is gone (a torn-down service, an archived fork), say the check is unavailable
and leave the doc alone rather than recording delivery on ancestry.

### Step 3: Apply the repairs

Both repairs are deterministic once the finding is classified, so they take the
`.claude/docs/workspace-write-guard.md` auto-accept path. Stage each doc once.

**`partial-delivery-unrecorded`** - add to the frontmatter:

```yaml
partial_delivery: true
partial_delivery_prs:
  - https://github.com/acme/platform/pull/4892
  - https://github.com/acme/platform/pull/4936
```

Leave `status: wontfix` alone. The status describes the *effort*, which really did close
without completing, and flipping it to `completed` would assert a deploy validation that
never happened. `partial_delivery` describes the *code*, which shipped. Keeping the two
separate is the whole point: one field is not made to carry both facts.

Where the doc has no `closed_reason`, `closure`, `resolution` or `superseded_by` and the
closure rationale exists only as body prose, lift one sentence of it into `closed_reason`
in the same write. A shipped-but-wontfix doc is the case where a reader most needs to know
why, and prose no tool reads is where that answer goes to die.

**`no-lifecycle-section`** - add a `## Lifecycle` block recording what actually happened,
with delivery rows marked `(n/a - wontfix)` where nothing shipped, matching the shape
already used across the corpus. Do not invent dates: use what the body and frontmatter
record, and leave a row out rather than guessing at it.

### Step 4: Report and log

Write the report to `workspace/stats/closed-effort-audit-{YYYY-MM-DD}.md` (re-run
overwrites). Sections, omitting any that is empty:

```markdown
# Closed-Effort Audit - {YYYY-MM-DD}

## Counts
| Defect | Count |   + terminal totals (done/, archive/*/), repaired, report-only

## Repaired
- {effort} - {defect}: {what was added}

## Report only
- {effort} - {defect}: {why no repair is derivable}

## Delivery record impact
- {effort} - {N} merged PRs now visible to /nase:effort-rollup
```

Chat reply is pointer plus bounded summary per `.claude/docs/skill-contract.md`:

```
Closed-effort audit → workspace/stats/closed-effort-audit-{YYYY-MM-DD}.md
Terminal: {M} done/ · {A} archive/ · Defects: {D} ({R} repaired, {P} report-only)
Delivery record: {N} PRs across {E} efforts recovered for /nase:effort-rollup
```

Append one line to `workspace/logs/{YYYY-MM-DD}.md` per
`.claude/docs/daily-log-format.md`:

```
- {HH:MM} | efforts --closed: {T} terminal docs, {D} defects, {R} repaired, {N} PRs recovered for the delivery record
```

### What this pass does not do

- **It does not reopen efforts.** A terminal doc stays terminal; the repairs make its
  record accurate, they do not move it back into `workspace/efforts/`.
- **It does not read prose delivery claims.** The finding is built from the structured
  delivery set only, so an effort whose shipped PRs are named only in a `re-scope:` note
  or a body paragraph will not be flagged. That is fail-closed on purpose - prose PR
  citations are how a sibling effort's delivery gets mistaken for this one's - but it
  means a clean run is not proof that every closed effort is recorded correctly.
- **It does not judge whether `wontfix` was the right call.** An effort that delivered a
  verdict rather than code (`scope: exploration`, a diagnosis that concluded "no fix
  warranted") is correctly `wontfix` under the status vocabulary, and has no delivery PR
  to trip the check. Do not flip those to `completed`: `completed` means shipped and
  verified, and claiming it for an investigation asserts a delivery that never existed.
