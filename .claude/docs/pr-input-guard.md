# PR Input Guard — Shared Reference

Standard input validation for skills that operate on a single GitHub PR URL.

---

## Algorithm

1. If `$ARGUMENTS` is empty or does not contain a GitHub PR URL: output `Usage: /{skill-name} <PR-URL>` and stop.
2. Extract `owner`, `repo`, and `pr_number` from the URL.
   - Pattern: `https://github.com/{owner}/{repo}/pull/{pr_number}`
   - Also accept short forms like `owner/repo#123` — normalize to the three components.
