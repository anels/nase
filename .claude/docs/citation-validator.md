# Citation Validator

Report-like skills often cite Jira tickets, GitHub PRs, Confluence pages, and
source files. Before a saved artifact is treated as done, validate the cited
references against real tools. A fabricated ID in a recap or audit is worse
than no citation because it looks trustworthy.

## When to run

Run after the artifact is assembled and before the skill marks itself complete,
updates the daily log, or presents the artifact as trusted. If the artifact is
shown in chat, validate first unless the command explicitly marks the output as
an unvalidated draft.

## What to validate

Validate these reference types:

1. Jira ticket IDs: `[A-Z][A-Z0-9]{1,9}-[0-9]+`
2. GitHub PR URLs: `https://github.com/{org}/{repo}/pull/{number}`
3. Confluence URLs, when the artifact claims a page exists or was updated
4. Source file paths, when the artifact cites local repo files

## How to validate

Jira:

```bash
grep -Eo '[A-Z][A-Z0-9]{1,9}-[0-9]+' "$ARTIFACT" | sort -u > /tmp/tickets.txt
while IFS= read -r ticket; do
  acli jira issue view "$ticket" --json >/dev/null 2>&1 \
    || echo "BROKEN: $ticket"
done < /tmp/tickets.txt
```

Fallback: use the Atlassian MCP `getJiraIssue` tool for each ticket.

GitHub PRs:

```bash
grep -Eo 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' "$ARTIFACT" | sort -u > /tmp/prs.txt
while IFS= read -r url; do
  gh pr view "$url" --json number,title >/dev/null 2>&1 \
    || echo "BROKEN: $url"
done < /tmp/prs.txt
```

Source files:

```bash
grep -Eo '`[^`]+\.(ts|tsx|js|jsx|py|go|md|yml|yaml|cs|sql|sh)`' "$ARTIFACT" \
  | tr -d '`' | sort -u | while IFS= read -r p; do
    [ -e "$REPO_ROOT/$p" ] || echo "BROKEN: $p"
  done
```

Confluence:

- If the artifact cites a Confluence page URL, fetch the page with the
  Atlassian MCP when available.
- If MCP is unavailable, mark Confluence validation as skipped rather than
  inventing page metadata.

## Failure behavior

On any `BROKEN:` finding:

1. Do not update the daily log yet.
2. Do not mark the skill complete.
3. Show the broken references and ask the user what to do:
   - fix and re-validate
   - save/display with an unvalidated-reference banner
   - abort
4. If the user accepts broken references anyway, record that in
   `workspace/metrics.md` under `## Citation Accuracy`.

## Claim-faithfulness check

Existence is not enough for externally shared reports. When a report says a PR
was merged, a Jira ticket was resolved, or a person did specific work, the cited
reference must support that claim.

Use the deeper check when the output is likely to be shared outside the local
workspace:

- Fetch each unique Jira ticket or PR once.
- Compare status, assignee/author, title/summary, and updated/merged dates
  against the claim sentence.
- If the reference exists but does not support the claim, treat it like a
  validation failure and gate with the same failure behavior.

## Skills that should call this

- `/nase:recap` for saved weekly/monthly recaps
- `/nase:tech-debt-audit` when citing tickets, PRs, or files
- `/nase:onboard` when citing source file paths in repo KB
- workspace/reporting skills that produce shared artifacts

Chat-only exploratory output may cite live tool results without this full pass,
but should still avoid invented IDs and URLs.
