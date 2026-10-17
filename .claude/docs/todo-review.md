# Todo Review

Re-checks the open `## Independent` items in `workspace/tasks/todo.md` against live state, archives what is done, and walks the user through the rest one question per item. `/nase:today` Step 7 runs it. Effort-backed pointers are out of scope because the effort doc owns their status, `/nase:today` Step 1 reads their live PR state, and `check-effort-pointer-integrity.py` polices the rows.

## Triage

`/nase:today` Step 5 runs `python3 .claude/scripts/todo-staleness-scan.py` before it renders the closing card and puts the result in the plan as one prose line, because nothing may follow the card. The script owns the due rules (its docstring, shown by `--help`). Only its `due` lines enter this review. With none due, the review ends there, because re-checking an item verified yesterday costs agents and queries for no new information. Age only decides whether to look, never whether to close.

## Re-verify

Group the due items by repo or domain and give each group one `verifier`-role subagent (`.claude/roles.yaml`, read-only), in parallel. For items about code, the main thread resolves the repo path with `repo-resolution.md`, pins the ref once per repo with `open-work-freshness.md` steps 1-2, and puts `fresh_default_oid` in every brief, so the agents never fetch. Items about telemetry or cloud state have no ref, so their brief names the query window and the resource instead. Each brief states the goal, the item text, the verdict vocabulary below, and these constraints:

- For code claims, ground every claim on `fresh_default_oid` and name the ref beside each claim. A name-only grep is candidate discovery, so read the mechanism at that ref, and pass paths and patterns as separate quoted arguments (`open-work-freshness.md` step 4).
- Treat every number in the item as stale. Re-measure it over a fresh window, bin it by day, split it by cohort, and print the denominator beside each percentage. A zero is not evidence of absence until the dimension has been enumerated (`names`, `targets`, other event types).
- Find the KB file for the item's repo or domain through `workspace/kb/.domain-map.md`, and take query templates and resource names from that file and from `workspace/context.md`. `az rest` and `az devops invoke` run as reads only with no method flag or a GET or HEAD method in any case, and only with these flags spelled in full. `az rest` takes `--url`, `--uri`, `--resource`, `--uri-parameters`, and `--skip-authorization-header`. `az devops invoke` takes `--area`, `--resource`, `--route-parameters`, `--query-parameters`, `--api-version`, `--org`, `--organization`, `--detect`, and `--accept-media-type`. Any other flag, such as `--headers`, `--body`, `--in-file`, or an abbreviation like `--metho`, is blocked. `az keyvault secret list` (names only) and Data Factory run history (`pipeline-run` and `trigger-run` with a read verb such as `show`, `list`, or `query-by-*`) are reads. Other Data Factory commands, including `list` and `show` on the factory, are blocked because their definitions can hold credentials and `activity-run` output can hold fetched secrets.
- Slack, Jira, and ADO reads that need live connector context stay in the main thread.
- A read the agent cannot do (role-gated data plane, a subscription it cannot see) becomes a read-only command for the user to run with `!`, marked as not run by us.

The agent's answer is a claim. Before an item is closed or rewritten, the main thread re-reads the one decisive fact itself (the symbol at the pinned SHA, the query row, the log line). Agents are wrong often enough that a summary alone is not a basis for deleting an item.

## Verdicts

| Verdict | Meaning |
|---|---|
| STILL-OPEN | The problem is present at the pinned ref. |
| RESOLVED | A merged change or a re-measure shows it gone, with the symbol or number as proof. |
| SUPERSEDED | The premise no longer holds (target replaced, owner changed, claim was wrong). |
| PARTIAL | Part is done. Name the remaining part. |
| UNVERIFIABLE | The read was blocked. Say what is missing. |

A verdict needs a ref, a query row, or a log line, or it is UNVERIFIABLE. `STILL-OPEN`, `RESOLVED`, and `UNVERIFIABLE` are `still_open`, `already_done`, and `blocked` in `open-work-freshness.md`.

## Next step

For every item that stays open, list the candidate actions and recommend the cheapest one that changes what is known: re-measure, draft a handoff (Slack drafts only, `slack-draft-style.md` and `prose-lint.py`), `/nase:design` or `/nase:fsd`, a user-run command, park, or close. Park and close are always on the list, because the owner may have stopped working in that area.

The default by verdict: RESOLVED closes. SUPERSEDED closes, or is rewritten when part of the premise holds. PARTIAL is rewritten to the remaining part. STILL-OPEN and UNVERIFIABLE are kept or parked.

## Walkthrough

One `AskUserQuestion` per item, in file order, and the answers are applied together after the last one. This departs from `skill-contract.md` rule 4 (batch the questions) because the user reads one item's evidence at a time. It departs from `skill-authoring-contract.md` section 5 (act on each answer at once) because Apply writes `todo.md` once. `## Archived This Cleanup` in `todo.md` records each close and rewrite, in place of `### Resolved Decisions`.

- The question names the item and the verdict in one sentence.
- An `AskUserQuestion` takes 2 to 4 options. Offer the recommended action, then park and close (unless one of them is the recommendation), then at most one more candidate. The user can type anything else under Other.
- Each option description says what happens, what it costs, and what it leaves undone, in full sentences, so the user never backtracks to understand an option.
- The recommended option ends with ` (Recommended)` (`skill-authoring-contract.md`).
- Quote only the decisive numbers. The full evidence stays in the subagent output.

If the user stops early, apply the answers so far and leave the other items due.

## Apply

After the last answer, run the chosen actions, re-read `todo.md` and record its `st_mtime_ns` and sha256 (the review is long), then build the whole result and write once, passing the recorded values to `apply` as `--expected-mtime-ns` and `--expected-sha256` so an edit made meanwhile is rejected. `/nase:design` and `/nase:fsd` are handed off, not run: keep the item, note the handoff on its line, and tell the user the command. Per item:

1. **Chosen action.** Run read-only ones first, because their output can change the item's line. External writes follow `external-mutation-policy.md` and stop at a draft.
2. **Close.** Save the whole original item (the bullet and its indented lines) verbatim to `workspace/tasks/archive/todo-cleanup-{YYYY-MM-DD}.md`, delete it from the proposed `todo.md`, and add one line under `## Archived This Cleanup` with the date, what changed, and the evidence with its ref.
3. **Rewrite.** Archive the original and add the cleanup line as for Close. The new line states what is still true, what changed, and what was not checked, and ends with `(verified {YYYY-MM-DD})`. Treat a parked line as in Keep.
4. **Park.** Add `⏸` and `(recheck {YYYY-MM-DD})`, set to the day the blocker is expected to clear, or 14 days out when that is unknown. Replace any old `(recheck)` mark.
5. **Keep.** End the line with `(verified {YYYY-MM-DD})`, which resets its age for the scan. The scan ignores `(verified)` on a parked line that has a `(recheck)` mark, so there either set a new `(recheck)` date or, when the blocker has cleared, remove `⏸` and `(recheck)` and stamp `(verified)`. An UNVERIFIABLE item keeps its old marker, because no check happened, and is parked when the read cannot be done soon.
6. **Stale KB claim.** Fix it in the same pass under `kb-write-routing.md`.

Dates are the local day (`nase_time.local_today()`), the day the scan uses.

The answers are the gate, so the writes need no second prompt. Write the archive file first and `todo.md` second, so a failed write never loses the original, and finish the apply for one file before staging the next, because the stage metadata sits at one shared path (`workspace-write-guard.md`). If the dated archive file exists, read it and append. A new one starts with a `# Todo cleanup {YYYY-MM-DD}` heading. The counts per verdict go into the `/nase:today` Step 8 self-log line, not a second line.
