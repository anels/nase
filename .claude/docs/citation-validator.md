# Citation Validator

## Contents

- Run the executable gate
- Result and exit semantics
- Failure gates
- Persist the receipt
- Claim-faithfulness remains manual
- Callers

Report-like skills often cite Jira tickets, GitHub PRs, Confluence pages, and
source files. Validate those references before treating an artifact as trusted.

## Run the executable gate

Run after assembling the artifact and before marking the workflow complete,
updating the daily log, or promoting a saved report:

```bash
python3 .claude/scripts/citation-validator.py "$ARTIFACT" \
  --root nase="$NASE_ROOT" \
  --repo-root repo-alias="$REPO_ROOT" \
  --format json
```

Repeat `--repo-root ALIAS=PATH` for each available checkout. New report
producers MUST emit repo-qualified source citations such as
`repo-alias:src/service.py:42`. Legacy `src/service.py:42` citations pass only
when exactly one supplied root contains the file.

The helper validates four authority classes independently:

1. canonical GitHub PR URLs through `gh pr view`
2. Jira keys through `acli jira workitem view` when `acli` is available
3. Confluence URLs as `UNKNOWN mcp-required`
4. backticked source citations that end in a positive line number

It never executes artifact text, performs anonymous Confluence reads, or emits
supplied absolute root paths.

## Result and exit semantics

- Exit `0`: every discovered reference is `OK`, or no eligible references exist.
- Exit `1`: at least one reference is `BROKEN`.
- Exit `2`: no reference is `BROKEN`, but at least one is `UNKNOWN`.
- Exit `3`: the validator did not run, so nothing was checked. Bad arguments, an
  unreadable or out-of-root artifact, a root that is not a real directory, a
  duplicate root alias, or a non-positive timeout.
- Exit `4`: the validator ran but withheld its output because the payload carries
  sensitive data.
- When `BROKEN` and `UNKNOWN` coexist, exit `1` and retain both in JSON.

Exit `2` and exit `3` are opposite instructions and must never be collapsed. Exit
`2` means every reference was checked and some authority was unreachable, so the
*Failure gates* below let the artifact through behind an explicit banner. Exit `3`
means no reference was checked at all, so there is nothing to put a banner on. A
caller that reads any non-zero, non-one code as "some unknowns" will promote a
report whose citations were never validated.

`BROKEN` means the named authority proved a missing or invalid target, including
not-found PRs or tickets, path escape, symlink escape, missing files, or a line
past EOF. `UNKNOWN` means authority was unavailable or ambiguous, including
missing CLI, auth, network, timeout, rate limit, unavailable root, ambiguous
legacy path, or Confluence MCP required.

## Failure gates

For any `BROKEN` result:

1. Do not update the daily log or promote the artifact.
2. Show the broken references.
3. Ask the user to choose fix and revalidate, retain an explicit
   unvalidated-reference banner, or abort.
4. If the user accepts broken references, record that decision under
   `workspace/metrics.md` `## Citation Accuracy`.

For `UNKNOWN`, retry with the matching read-only MCP authority when available.
Otherwise abort or continue only with an explicit unverified banner. A real MCP
page read is a separate timestamped authority record. It never mutates or
overwrites the base validator JSON.

For exit `3` there is no banner to write and no receipt to persist, because no
reference was examined. Read the `ERROR:` line on stderr, correct the artifact
path, root, alias or timeout it names, and run the gate again. Do not promote the
artifact, do not update the daily log, and do not record a citation-accuracy
decision: there is no finding to accept.

For exit `4` the run completed but the payload is unsafe to write down. Do not
persist the receipt and do not paste the output into chat or a draft. Redact the
offending value at its source in the artifact, then rerun.

## Persist the receipt

For a report being **promoted** to a durable path under `workspace/recaps/`
(not for chat-only exploratory output), keep the `--format json` payload the
gate already produced instead of letting it drop with the terminal output.
Capture it when you run the gate, then, right after the artifact lands at its
final promoted path, write that same payload next to it as
`{promoted-artifact-path}.receipt.json` — e.g.
`workspace/recaps/tech-debt-insights-2026-09-21.md.receipt.json`.

Write it atomically so a crash mid-write never leaves a half-written receipt
next to a trusted report:

```bash
tmp=$(mktemp "${target%.receipt.json}.receipt.json.XXXXXXXX")
printf '%s' "$VALIDATOR_JSON" > "$tmp"
mv "$tmp" "$target"
```

This is the validator's already-computed payload, persisted as-is - never
re-run the gate just to produce the receipt. If the user accepted `BROKEN` or
`UNKNOWN` findings under *Failure gates* above, the persisted receipt still
carries those statuses; it is a record of what was actually checked, not a
claim that everything passed.

## Claim-faithfulness remains manual

Existence does not prove scope, attribution, status, or impact. For an artifact
likely to be shared externally, compare the helper's bounded PR/Jira metadata
with each claim sentence. A reference that exists but does not support the claim
uses the same failure gate as `BROKEN`.

## Callers

- `/nase:recap` for saved weekly or monthly recaps
- `/nase:tech-debt-audit` when citing tickets, PRs, or files
- `/nase:effort-rollup` per `.claude/docs/effort-rollup-integrity.md → Render and validate`
- reporting skills that produce shared artifacts
- `/nase:onboard` only for new Jira, PR, or Confluence references not already
  covered by its existing live local-path checks
- `/nase:discuss-pr` per `.claude/docs/discuss-pr-output.md`
- `/nase:design` auto mode per `.claude/docs/design-auto-mode.md → 5a`

Every caller above that promotes its artifact to `workspace/recaps/` also
follows *Persist the receipt*. `/nase:onboard` does not promote a recap-style
artifact, so it has nothing to persist a receipt next to.

Chat-only exploratory output may cite live tool results without this full pass,
but must not invent identifiers or URLs.
