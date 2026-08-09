# Citation Validator

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
- When `BROKEN` and `UNKNOWN` coexist, exit `1` and retain both in JSON.

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

## Claim-faithfulness remains manual

Existence does not prove scope, attribution, status, or impact. For an artifact
likely to be shared externally, compare the helper's bounded PR/Jira metadata
with each claim sentence. A reference that exists but does not support the claim
uses the same failure gate as `BROKEN`.

## Callers

- `/nase:recap` for saved weekly or monthly recaps
- `/nase:tech-debt-audit` when citing tickets, PRs, or files
- reporting skills that produce shared artifacts
- `/nase:onboard` only for new Jira, PR, or Confluence references not already
  covered by its existing live local-path checks

Chat-only exploratory output may cite live tool results without this full pass,
but must not invent identifiers or URLs.
