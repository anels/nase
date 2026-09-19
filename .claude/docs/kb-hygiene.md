# KB Hygiene

Used by `/nase:onboard` before reading or updating a project KB. The goal is to keep the KB useful for engineering work without deleting historical learning.

## Contents

- Classification
- Safe Auto-Fix Scope
- Historical Notes
- Curation (four outcomes, never curated, budget and recovery, reorganization, do not write it back)
- Required Preflight

## Classification

Every hygiene finding must be classified before action:

| Class | Meaning | Default action |
|-------|---------|----------------|
| `verified` | Current KB claim still matches repo `HEAD` or a live source of truth | Leave unchanged |
| `auto-fix` | Low-risk source-verifiable fact is wrong or incomplete | Reconcile through the Shared admission contract |
| `stale` | A current-state claim appears superseded but the right replacement needs judgment | Mark with evidence and report |
| `needs-human` | API auth, schema semantics, ownership, business intent, or cross-repo contract meaning may be wrong | Report with suggested patch; do not rewrite |

## Safe Auto-Fix Scope

`/nase:onboard` may auto-fix only facts that can be verified from repo `HEAD` without interpretation:

- Broken or moved source-file references when the replacement path is unambiguous.
- Discoverable placeholders such as Azure Pipeline `definitionId` when a deterministic source exists.
- Manifest, dependency, package-manager, build-command, and lockfile facts.
- Pipeline YAML metadata: trigger, parameters, stages, template refs, pinned versions.

Never auto-rewrite these without user confirmation:

- API authorization, route semantics, payload compatibility, rate limits, idempotency, or public/private exposure.
- Schema meaning, partition keys, data ownership, migration intent, retention, or backfill safety.
- Ownership, team focus, business intent, customer exposure, rollout policy, or incident responsibility.
- Cross-repo contract meaning, generated-client compatibility, event ownership, package-consumer expectations.

## Historical Notes

Reconcile current-state sections in place and remove superseded current wording.
Genuine historical notes are never silently deleted. Use one of these markers:

- `**Correction** (recorded YYYY-MM-DD, true since YYYY-MM-DD): ...` when a prior claim was wrong.
- `**Superseded by** <anchor> (recorded YYYY-MM-DD, true since YYYY-MM-DD)` when a prior claim was true at the time but replaced by a later change.

`.claude/docs/kb-lifecycle-layers.md → Two times, always` owns this syntax; both dates are MUST, not optional.

If a section has more than three corrections or supersession markers, report it as a compaction candidate instead of adding another long correction chain.

## Curation

Hygiene keeps existing claims true. Curation decides whether a claim still earns its place. `/nase:onboard` runs both on every refresh unless `--no-curate` is passed, because a KB that only ever grows stops being the fastest answer to a live question and becomes a changelog that `git log` already holds.

`.claude/scripts/kb-hygiene-scan.py` nominates candidates under `action: curate`; it never decides. Age nominates, content decides.

| Category | Signal | Decision to make |
|---|---|---|
| `curation_candidate` | Dated section older than `--curate-age-days` (default 90), not in a protected section | Refresh, fold, or delete |
| `merge_candidate` | Two or more dated, unprotected sections cover one topic | Reconcile into one current-state section |
| `reorganize_candidate` | Dated entries dominate the top-level sections | Regroup under `.claude/docs/kb-template.md -> Project KB Structure` |
| `oversized_kb` | Non-blank lines past `--max-kb-lines` (default 800) | Curate, or split by topic |

### The four outcomes

Every candidate resolves to exactly one, in this order:

1. **Refresh** - the claim is still load-bearing but no longer matches `HEAD`. Rewrite it in the current-state section under the Safe Auto-Fix Scope above; risky classes still go to `needs-human`.
2. **Merge** - several dated entries describe one subject. Write the end state once, in the topical section, and keep only the dated entries that record a decision or an incident.
3. **Delete** - nothing durable survives extraction. A section that only records what one PR changed is recoverable from `git log`; the KB pays for it on every read.
4. **Keep** - the section records why something is the way it is. Age is not a reason to touch it.

**Fold before delete.** A block is removable only once its durable fact is already present in a current-state section, or is written there in the same staged diff. Extract first, delete second; never the reverse. The durable half is usually a constraint, a non-obvious default, a gotcha, or a boundary - the PR number and the change narrative are the disposable half.

### Never curated

The scanner exempts sections whose heading path names an incident, postmortem, outage, sev level, decision, ADR, rationale, constraint, invariant, gotcha, footgun, ownership, alumni, security, credential, secret, runbook, or cross-validation topic, and any heading carrying a `verified YYYY-MM-DD` marker. The same exemption covers deletion and merge alike, so an incident record is never nominated as one half of a merge either. Treat that list as a floor, not a ceiling - if a section answers "why is it like this", keep it whatever the scanner says.

An undated heading is also never nominated. A heading with no date is a topical current-state section, and both the age test and the merge grouping read a date as the marker of a log entry.

### Budget and recovery

`workspace/` is git-ignored, so a wrong deletion is recoverable only from the last workspace backup. Two limits follow:

- One refresh removes at most 30% of a file's non-blank lines (`curation.budget_lines`). When `curation.over_budget` is true, take the oldest candidates up to the budget and report the remainder as still-pending; a file that accreted for a year converges over several runs, each one reviewable.
- Every run appends one daily-log line naming the file, the removed section titles, the merged groups, and the timestamp of the most recent backup, so a recovery is targeted rather than a whole-workspace restore.

Deletion still goes through the staged full-file diff and `workspace-write-guard.py` like any other KB write. Never delete a file; curation edits sections.

### Reorganization

When `reorganize_candidate` fires, regroup the file so the durable knowledge sits under the canonical headings in `.claude/docs/kb-template.md -> Project KB Structure`, and what remains dated sits in one trailing section. Reorganization moves and merges text; it does not invent claims. Do the refresh, merge, and delete work first, then regroup what is left, and report the four counts separately so the diff can be read as four intents rather than one rewrite.

### Do not write it back

Curation is wasted if the same refresh re-adds what it removed. A refresh does not create a section keyed by a PR number or a date unless that section records a decision, an incident, or a constraint. The durable fact belongs in the topical current-state section, with the PR link inline as evidence rather than as the heading.

Re-run the scanner against the staged file before applying. A refresh that raises `curation.dated_top_sections` above the pre-refresh count is rejected, and the new knowledge is re-routed into a topical section instead.

## Required Preflight

Before `/nase:onboard` uses an existing project KB as the base for a refresh:

1. Run `.claude/scripts/kb-hygiene-scan.py --repo-root {repo} --kb-file {kb}`.
2. Read the report before trusting the KB.
3. Apply `auto-fix` items only when they are in the safe scope above and pass `.claude/docs/kb-write-routing.md -> Shared admission contract`.
4. Add `Correction` / `Superseded by` markers for stale historical claims.
5. Resolve every `curate` item through *Curation* above, inside the line budget, and re-run the scanner against the staged file before applying.
6. Report all `needs-human` items in the `/nase:onboard` confirmation.

Use `--hygiene-report-only` to produce the report without KB edits.

Ordinary KB consumers do not run a full hygiene scan on every read. They follow
`.claude/docs/repo-resolution.md`: use the KB as context, then validate actionable
current claims against the relevant source of truth.
