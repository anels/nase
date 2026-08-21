# Effort Rollup Integrity

This contract owns count-critical collection and promotion for
`/nase:effort-rollup`.

## Inputs and collection

Accept only `<YYYY-MM>`, one optional `--repo <context-alias>`, and `--md-only`.
Reject `--scope` and every unknown argument. Create a new empty transient bundle
under `workspace/tmp/effort-rollup-{YYYY-MM}-{run-id}/`. Never reuse a prior
bundle or prior report values as fresh input.

Run the collector before synthesis:

```bash
python3 .claude/scripts/effort-rollup-evidence.py collect \
  --root . --month "$MONTH" --bundle "$BUNDLE" "${REPO_FILTER_ARGS[@]}" --format json
python3 .claude/scripts/effort-rollup-evidence.py validate \
  --root . --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
```

The helper owns expected repo scope, live GitHub captures, delivery roles,
buckets, countability, exclusion reasons, and critical totals. Narrative
synthesis consumes `evidence.json` and may not override those fields. Optional
Jira or telemetry bytes belong under `$BUNDLE/supplemental/`; they may support
narrative claims but never change canonical roles or totals.

## Render and validate

Render `$BUNDLE/report.fresh.md` and, unless `--md-only`,
`$BUNDLE/report.fresh.html`. Both artifacts MUST show the exact `Evidence SHA`,
`Measurement basis: effort-rollup-v2`, coverage label, and critical totals.
Every counted effort cites its `effort:{slug}` record ID, every counted PR uses
its canonical URL, and new file citations are repo-qualified.

```bash
python3 .claude/scripts/citation-validator.py "$BUNDLE/report.fresh.md" \
  --root nase=. "${AVAILABLE_REPO_ROOT_ARGS[@]}" --format json
python3 .claude/scripts/effort-rollup-evidence.py validate \
  --root . --month "$MONTH" --manifest "$BUNDLE/evidence.json" \
  --markdown "$BUNDLE/report.fresh.md" --format json
```

Verify the HTML repeats the same evidence SHA, basis, coverage, critical totals,
canonical counted PR URLs, and metric IDs.

## Promotion

Promote the fresh Markdown and HTML to `workspace/recaps/` only after
deterministic validation, citation validation, and required visual checks pass.
Never overwrite an existing valid recap on failure. `coverage=partial` requires
a visible gap list and explicit user acceptance before promotion.

Use `complete-for-declared-sources` only when every declared repo/account search
and candidate PR view completed within the recorded cap and retry contract. It
does not claim GitHub search-index exhaustiveness. Historical comparison requires
the same `Measurement basis`; otherwise label the prior period `legacy basis`
and do not present its delta as comparable.
