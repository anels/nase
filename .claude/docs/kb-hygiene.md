# KB Hygiene

Used by `/nase:onboard` before reading or updating a project KB. The goal is to keep the KB useful for engineering work without deleting historical learning.

## Classification

Every hygiene finding must be classified before action:

| Class | Meaning | Default action |
|-------|---------|----------------|
| `verified` | Current KB claim still matches repo `HEAD` or a live source of truth | Leave unchanged |
| `auto-fix` | Low-risk source-verifiable fact is wrong or incomplete | Update the KB directly |
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

Historical notes are never silently deleted. Use one of these markers:

- `Correction YYYY-MM-DD: ...` when a prior claim was wrong.
- `Superseded by: ...` when a prior claim was true at the time but replaced by a later change.

If a section has more than three corrections or supersession markers, report it as a compaction candidate instead of adding another long correction chain.

## Required Preflight

Before using an existing project KB as context:

1. Run `.claude/scripts/kb-hygiene-scan.py --repo-root {repo} --kb-file {kb}`.
2. Read the report before trusting the KB.
3. Apply `auto-fix` items only when they are in the safe scope above.
4. Add `Correction` / `Superseded by` markers for stale historical claims.
5. Report all `needs-human` items in the `/nase:onboard` confirmation.

Use `--hygiene-report-only` to produce the report without KB edits.
