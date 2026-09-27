# Confluence Publish - Target Resolution and Confirmation

> Steps 4 and 5 of `/nase:publish-confluence`: work the ladder to find where the page goes, then
> present one batched confirmation. That command owns the input guard, conversion, publish, and
> cleanup. Every Confluence write still goes through `.claude/docs/external-mutation-policy.md`.
>
> Tool names are the current generation: `getConfluenceContent`, `createConfluenceContent`,
> `updateConfluenceContent`, `searchConfluence`. The `*Page` and `searchConfluenceUsingCql` names
> belong to the older server and fail at the MCP call, not at the gate.

## Part 1 - Find the target (before asking anything)

When the caller passed `--space KEY` (and optionally `--parent ID`), the destination is pinned: skip rungs 3-6, still run rung 1 for the
create-or-update verdict and rung 2 for the cloudId, and present that space as the only candidate.

Otherwise work this ladder to completion - an early hit does not stop it, because the confirm ranks every candidate and shows the runner-up - then ask once:

1. **Ledger** - `python3 .claude/scripts/confluence-publish.py ledger-lookup --source "{source}" --pages {N}`. Per-page `create`/`update`, `orphans`, and the prior month's page family.
2. **cloudId** - `workspace/config.md` `## Jira → cloudId` (same site), confirmed with `getAccessibleAtlassianResources`.
3. **KB** - resolve a Confluence-map file through `workspace/kb/.domain-map.md` for a topical parent. Skip silently if the domain map has no such entry; this rung is an optimisation, not a requirement.
4. **CQL by title** - `title ~ "{stem}" AND type = page`. Also pre-empts the title conflict in Step 6.
5. **CQL by author** - `creator = currentUser() AND type = page ORDER BY lastmodified DESC`, limit 10.
6. **Spaces** - the fallback list. There is no primary space-listing tool; resolve the operation through `discover` ("list Confluence spaces") and run the name it returns with `executeRead`. Never guess an operation name.

For every `update` candidate, fetch `getConfluenceContent(contentFormat:"html")` and compare against the ledger's `published_body_sha256`.

## Part 2 - One confirmation

A single batched `AskUserQuestion` presenting a decision-ready brief - never the draft body:

| Question | Content |
|---|---|
| Target | ranked candidates as `{space key} · {space name}` so the audience is explicit; recommended first with its evidence |
| Create or update | for an update, quote the page id, title and `lastModified`. If the page is **not** in the ledger, or its body hash differs, say *this replaces content this skill did not publish* |
| Page structure | measured byte counts. When the ledger holds one page and this run splits, add *content moves to {M} children, so inbound links land on page 1 of N* |
| Visuals | `{K}` charts → PNG + placeholders. When `split_differs_without_visuals` is set, state the page count each answer produces. `adjust selectors` re-runs the command's Step 3 and re-shows this confirm |

State that space permissions were **not** verified - the MCP exposes no permission field - and that the secret scan is partial. The audience call stays with the user.

