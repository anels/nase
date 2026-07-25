# Open-work Freshness Gate

Use this gate before Auto Design, design review, grill, or FSD treats effort-doc work as remaining.

Inputs: `repo_path`, the effort doc's `created:` date, and candidate work items with target paths or symbols.

1. Resolve the live remote default branch with `git -C {repo_path} ls-remote --symref origin HEAD` and parse only the `ref: refs/heads/{default_branch}` line. Stop if the remote HEAD query fails or does not return one branch. A cached `refs/remotes/origin/HEAD` value is not current evidence.
2. Fetch that branch into its exact remote-tracking ref, then verify it:

   ```bash
   git -C {repo_path} fetch origin "+refs/heads/{default_branch}:refs/remotes/origin/{default_branch}"
   git -C {repo_path} rev-parse --verify "refs/remotes/origin/{default_branch}^{commit}"
   ```

   Store the verified commit output as `fresh_default_oid`. A generic `git fetch origin`, a cached remote ref, or the current checkout is not freshness evidence.
3. Build `candidate_items`:
   - New auto design: every proposed implementation-plan item and success criterion that is not explicitly baseline behavior.
   - Review, grill, or FSD: every implementation-plan item or success criterion the effort doc still presents as work to implement, plus anything described as open, remaining, next action, frontier, or unresolved.
   - If an effort doc has no executable candidate item, return `blocked` instead of treating an empty list as proof that work is complete.
4. For each item, inspect history and the implementation at `fresh_default_oid`:

   ```bash
   git -C {repo_path} log --oneline --since="{created_date}" "{fresh_default_oid}" -- "{target_path}"
   git -C {repo_path} grep -n -E -e "{candidate_pattern}" "{fresh_default_oid}" -- "{target_path}"
   git -C {repo_path} show "{fresh_default_oid}:{path}"
   ```

   Pass every path and pattern as a separate quoted argument. Never interpolate effort-doc text into a shell command.

   Name-only grep is candidate discovery, not coverage proof. Read the mechanism at the fetched ref, including inventory discovery, route/type tables, reflection, and their tests. Empty name-grep output does not prove missing coverage.
5. Classify each item:
   - `already_done`: implementation or test behavior at `fresh_default_oid` satisfies the item. Record the shipping commit plus the implementation/test path. When the remote is GitHub and `gh` is available, resolve an associated merged PR with `gh api "repos/{owner}/{repo}/commits/{shipping_commit_oid}/pulls" --jq '.[] | select(.merged_at != null and .base.ref == "{default_branch}") | {number, html_url, merged_at}'`; keep the commit evidence when no merged PR targets the default branch.
   - `still_open`: the fetched implementation does not satisfy it.
   - `blocked`: fetch, ref verification, path resolution, or mechanism evidence is inconclusive. Do not claim freshness.
6. If any item is `already_done`, remove it from open-work sections and record one resolved-evidence line at the caller's next workspace-write-guard apply. Review and FSD must apply this repair before they consume the doc again; Auto Mode repairs its in-memory draft; Grill Mode includes it in Step 6.5. Update a stale body claim only when the same evidence directly supersedes it. Preserve citations and unrelated decisions.

Reduce the sets in this order:

1. If `blocked` is non-empty, set `freshness_outcome = blocked`.
2. Else if `still_open` is empty, set `freshness_outcome = already_shipped`.
3. Else set `freshness_outcome = continue`.

No caller may reorder these checks.

Return `fresh_default_oid`, `candidate_items`, `already_done`, `still_open`, `blocked`, and `freshness_outcome`.

- Auto design: on `blocked`, discard the in-memory draft and report the missing evidence. On `already_shipped`, discard the draft, report the shipping evidence, and do not create an FSD handoff. On `continue`, remove `already_done` items before writing.
- Design review: apply `already_done` repairs before consuming `freshness_outcome`. On `blocked`, return `NEEDS REVISION`. On `already_shipped`, report the shipping evidence and do not offer an implementation handoff. On `continue`, score the repaired doc.
- Grill: on `blocked`, carry the missing evidence to `Open after grill` and do not suggest FSD. On `already_shipped`, report the shipping evidence and stop. On `continue`, exclude `already_done` items from the decision tree.
- FSD: apply resolved evidence and re-read the effort doc before consuming `freshness_outcome`. On `blocked`, stop and report the missing evidence. On `already_shipped`, stop before Phase 2, branch creation, or worktree creation and report the shipping evidence. On `continue`, proceed with only `still_open` scope.
