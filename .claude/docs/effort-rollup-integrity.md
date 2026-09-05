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
its canonical URL, and new file citations are repo-qualified. Both gates read
`exact` as the whole token, so `Delivered efforts: 4` is not satisfied by a
report showing `40`, nor `.../pull/1` by a link to `.../pull/12`.

```bash
python3 .claude/scripts/citation-validator.py "$BUNDLE/report.fresh.md" \
  --root nase=. "${AVAILABLE_REPO_ROOT_ARGS[@]}" --format json
python3 .claude/scripts/effort-rollup-evidence.py validate \
  --root . --month "$MONTH" --manifest "$BUNDLE/evidence.json" \
  --markdown "$BUNDLE/report.fresh.md" --html "$BUNDLE/report.fresh.html" \
  --format json
```

Pass `--html` on every run that renders one. It holds the HTML edition to the
same token contract as the Markdown, matched against reader-visible text with
whitespace collapsed, so a wrapped line still passes and a string that survives
only inside `<style>` does not count. A counted PR URL matches an `<a href>`
target or visible text, so a link a reader can neither see nor click - one left
in a comment or a `data-*` attribute - does not satisfy it either. It also fails
any text a table holds outside a `<td>`/`<th>`: `confluence-publish.py` drops
that text on publish, so a headline count in a malformed row disappears from the
published page while the local file still shows something. Findings land in
`validation.json` under `missing_html_contract`.

Reading the source is not a substitute for either check. When browser tooling is
unavailable, name the visual checks that stayed unverified rather than implying
the artifact was inspected.

The HTML therefore repeats the Markdown's evidence footer verbatim - `Evidence
SHA:`, `Measurement basis:`, `Coverage:`, `Delivered efforts:`, `Merged delivery
PRs in month:`. A number stated in only one edition is how the two drift apart
unnoticed.

## Publishing and sharing

Publishing the HTML edition goes through `/nase:publish-confluence`. Pass
`--rasterize-only` naming the paired-bar container: the default heuristic
rasterizes every `display: grid` class, which images the incident, feature, and
theme blocks too, and an imaged block loses the clickable PR and Jira links the
report exists to be navigated by. `plan` reports a captured block that holds no
chart primitive - treat that warning as the scope being wrong, not as noise.

For any shareable link, use an approved destination for that session and scrub
credentials and audience-restricted data from **both** artifacts first -
subscription GUIDs, resource IDs, customer/tenant/resource names, internal URLs,
tokens - keeping stable redacted labels where identity continuity matters.

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
