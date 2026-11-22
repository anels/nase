# Effort Drift and Reconciliation

How a stated effort status is reconciled against live PR and Jira state, what the
classifier gets wrong, and how a PR reference resolves. Loaded by the sync and audit
path only: `/nase:efforts` and `effort-doc-audit.md`. The vocabulary these rules
operate on is in `effort-model.md`.

## Contents

- Drift Auto-Sync
- Classifier Blind Spots
- Next actions
- PR Reference Resolution

Shared rules for `workspace/efforts/{slug}.md` and related `todo.md` entries.
Callers own inferring the slug; this doc owns how a stated status is reconciled
against live PR and Jira state.

All full-file writes use `.claude/docs/workspace-write-guard.md` and
`workspace-write-guard.py`. Auto-write modes only skip human confirmation; they
never skip final drift checks.

---

## Drift Auto-Sync

The deterministic lifecycle rule, applied by **both** `/nase:today` (Step 1, Live status sync)
and `/nase:efforts` (Step 3). Both callers keep delivery, report-only, and dependency
PR sets separate, use *PR Reference Resolution* only to normalize/query each set, then
pass the live delivery states to `effort-state.py`. The helper output is the executable
source of truth for the transition.

```bash
python3 .claude/scripts/effort-state.py \
  --file workspace/efforts/{slug}.md \
  --evaluate-transition \
  --delivery-pr-state MERGED \
  --jira-state done
```

Repeat `--delivery-pr-state` for multiple PRs; valid values are `OPEN`, `MERGED`,
`CLOSED`, and `UNREADABLE`. Jira state is `untracked`, `done`, `not-done`, or
`unreadable`. Add `--blocked-by-unresolved` when any blocker remains unresolved.
Use `transition.action` (`none`, `update`, or `move`) and `transition.status` exactly;
do not independently reinterpret the rules below. On `action: move` the helper also
returns `transition.destination_dir` - the move target per `effort-model.md →
Terminal Destination`.
Use that value; do not assume `done/`.

After the live reads, per active effort:

- Build the delivery PR set only from `pr`, `prs`, and `phase_*_pr` frontmatter
  plus checked canonical `PR opened` lifecycle lines. Other body PR references are
  context only. `blocked-by` PRs resolve dependencies but never count as delivery
  evidence. A transition requires at least one readable delivery PR; Jira-only and
  no-PR efforts remain active.
- Any unreadable delivery PR or tracked Jira referent → skip that effort's transition;
  it stays active and is reported as unresolved.
- Any unresolved `blocked-by` referent → no lifecycle transition.
- Any delivery PR still `OPEN` → no change.
- **Any undelivered `## Lifecycle` row → no change** (`reason: undelivered-lifecycle-rows`).
  A PR that was planned but never opened has no entry in the delivery set, so merged
  evidence alone would read "everything shipped" and archive live work. The classifier
  reports the offending rows in `undelivered`; the caller
  names them in its report so a stale plan row gets corrected rather than silently
  suppressing every future transition. See `effort-model.md → Multi-Deliverable
  Efforts`.
- With no open delivery PR, at least one `MERGED` delivery PR, and Jira (if tracked)
  `Done`, use the merged path; closed superseded siblings do not block it:
  - unchecked post-deploy validation or outcome rows do not count as undelivered
    PR work, but they block completion after `Deployed` is checked.
  - deploy validation incomplete -> set `status: awaiting-deploy` if needed and
    leave the file active.
  - canonical classifier reports checked `Deployed` evidence with no pending
    follow-up or post-deploy validation -> set `status: completed` and move to
    `transition.destination_dir`.
- If all readable delivery PRs are `CLOSED`-not-merged, set `status: wontfix` and
  move to `transition.destination_dir`.
- **Tick the `Merged` row the same run.** On the merged path the helper also returns
  `transition.stale_canonical_rows` when it has one: an unchecked canonical `Merged` row
  the live PR states have just proven merged. The key is absent when there is nothing to
  tick, so treat absent as none. Flip each named row to `- [x]`. Writing
  `status: awaiting-deploy` from this evidence while leaving the row saying "not merged"
  splits the doc against itself, and the split is self-perpetuating - the unticked row
  holds `stage` at `in_review` against an `awaiting-deploy` frontmatter, so
  `needs_live_verification` stays true and the next run re-reads the same PRs to
  re-report the same conflict.

  Keep the row's own words. Append `- {merge date} ({PR refs}, verified /nase:{skill}
  {run date})` only when the existing text is the bare label `Merged`
  (`transition.stale_canonical_rows[].bare_label` is `true`); a row that already carries
  prose gets its checkbox flipped and nothing else, because the author wrote that text
  about something the live PR read cannot see.

  The helper withholds the row wherever the assertion would not be provable: on any
  non-merged path, when a checked `Merged` row already exists, or when several unchecked
  ones do - those are per-PR ledgers in a multi-PR effort, and delivery states cannot say
  which row a given merge belongs to. A trailing outstanding clause
  (`Merged - PR-1 only`) also withholds it. `classify`'s own
  `unticked_canonical_rows` is a filtered candidate observation and authorizes nothing:
  it requires one unambiguous unchecked `Merged` row and excludes outstanding clauses.
  Only `transition.stale_canonical_rows` carries the merge proof.

**Write path.** These transitions qualify for the `.claude/docs/workspace-write-guard.md`
auto-accept path because their evidence and target are deterministic. Stage the
frontmatter change and any `transition.stale_canonical_rows` checkbox flip as one
proposed file under `workspace/tmp/`, so a single guarded write covers both and the doc
is never left half-updated. Use the normal guarded `apply` when the file
stays active. For terminal transitions, use the guard's `apply-move` operation with
`{destination_dir}/{slug}.md`; never run `apply` followed by `mv`. `apply-move` creates
the destination parent, so a first-of-year archive folder needs no separate `mkdir`. If
the source drifts or the destination file already exists, preserve the staged draft and
leave the source active. Log each applied transition, naming the destination.

Completed effort retention uses `workspace-write-guard.py move-existing` with the
60-day age gate. The operation refuses an existing archive destination and leaves
both files unchanged, so a same-name archive is never overwritten.

## Classifier Blind Spots

`effort-state.py` is the source of truth for the transition, but three things it reports
are silences rather than facts. Each has produced a confident wrong answer, so a caller
that reads the JSON and stops will repeat them. Run
`python3 .claude/scripts/effort-pr-sweep.py --check-reverts` before trusting a
sweep-wide read; it covers the first and the revert trap mechanically in one pass.

**1. The delivery set only sees canonically-labelled rows.** It is built from `pr:`/`prs:`
frontmatter plus rows whose label starts with `PR opened`. A row labelled `PR2 opened`,
`PR-3b`, `W8 PR opened` or `PR 2 — ` cites a real delivery PR and is invisible, so a
six-PR effort can classify and transition as a one-PR effort. Measured 2026-08-31: 14 of
52 active efforts had at least one invisible PR, and four had a materially wrong state as
a result. This - not a flaw in the rule - is why multi-PR initiatives appeared to
"misjudge": the rule was reading a one-PR document correctly.

Repair by keeping the canonical label and moving the effort's own number into the body:

```markdown
- [x] PR opened — **PR-2** — https://github.com/acme/platform/pull/102
```

Do **not** relabel every cited PR. Cherry-picks, withdrawn PRs, sibling-effort
dependencies, spikes, `Follow-up:` rows and "Phase N completed" summaries all name PRs
the delivery set should not carry, and pulling them in fires transitions on evidence that
is not this effort's delivery. The sweep hints and maps ownership; the caller classifies.

**`likely-delivery` is repaired automatically; the other hints are not.** That hint means
the row's own label calls the PR this effort's - `PR2 - <url>`, `PR-4 — <description>` -
and nothing marks it a dependency, spike, cherry-pick or withdrawal. No judgment is left
to add, so surfacing it as a question just parks a known-wrong document. Rewrite the
label, re-run the classifier, apply whatever transition it returns, and fix the
surrounding prose in the same pass - a doc whose rows say "opened" usually has a
delivery-notes line saying "all five are open" too, and leaving that trades one drift for
another. Every other hint stays a report line: there the row text and the live state
disagree about what the PR *is*, and firing a transition on someone else's evidence costs
far more than a doc that under-reports itself for another day.

**2. `pending_followups: 0` and an empty `undelivered` do not mean nothing is owed.**
Outstanding work written as prose *inside* a long row is invisible to both. `Deployed`
rows in particular accumulate hundreds of characters of ring evidence and then end with
the actual blocker - "what is still owed is a first-time deploy on a fresh cluster",
"the only live item left is the Repair v2". A truncated grep of the lifecycle section
shows the reassuring first half. Before reporting any effort as complete or closeable,
read the **full text** of every unchecked row (`sed -n '<N>p' <file>`, not a truncated
grep).

**3. The hold only scans `## Lifecycle`.** Unchecked implementation-plan checkboxes are
ignored by design, because authors leave them stale after the work lands. The cost is
that an effort whose remaining deliverable is recorded *only* there will auto-close the
moment its last Lifecycle row is ticked. When real outstanding work lives in the plan,
promote it to a Lifecycle row - that is the only place the gate can see it.

**Ancestry cannot see a revert.** A reverted PR's merge commit stays an ancestor of every
ring forever, so `--is-ancestor`, `--contains` and the compare API all report it as
shipped. `--check-reverts` finds the revert commit by PR number; confirm by grepping a
symbol the PR *added* at the ring commit, because that is the only check that
distinguishes "in history" from "in the build". Resolve merge SHAs with
`gh pr view <n> --json mergeCommit` and never `git log --grep='(#N)'`, which matches the
revert's own subject and cherry-pick backports.

## Next actions

After the Drift Auto-Sync transition, `/nase:efforts` acts on each effort in this order: close what is provably closable, validate what a read can validate, propose what can advance, then ask the user about the rest. `effort-state.py` decides; the skill carries it out.

```bash
python3 .claude/scripts/effort-pr-sweep.py --check-reverts --merge-details --json-out workspace/tmp/effort-sweep-{date}.json
python3 .claude/scripts/effort-state.py --file workspace/efforts/{slug}.md --evaluate-transition \
  --delivery-pr-state {live state per delivery PR} --jira-state {live Jira state} \
  --live-json workspace/tmp/effort-sweep-{date}.json
```

`--live-json` is the sweep's JSON. `--merge-details` adds `files`, `files_truncated` and `merge_checks` to merged delivery PRs of efforts awaiting deploy, or whose every delivery PR is merged. Jira and blocker flags are the Drift Auto-Sync ones. An effort with `jira:` in its frontmatter and no live `--jira-state` (or `untracked`) is `delivery-state-unresolved`, never closable. With no `--live-json`, no delivery PR reads as merged, so nothing closes. A value of the wrong type in the file is dropped, so it fails closed too. Reuse each effort's `next_action` from this run; re-run the helper only for an effort edited since. When `--json-out` cannot be written the sweep prints the payload on stdout and exits 1, so a caller gating on the exit code must read stdout, or re-run after fixing the path.

`next_action` is `{kind, reason, command, evidence, context}`, plus `edit` on `close`, `rows` (`line`, `command`, `expect`) on `validate`, and `blocking` (the count of distinct reasons blocking a close) on `ask`.

| kind | meaning | who acts |
|---|---|---|
| `close` | tests, CI and docs only; nothing is deployed | the skill ticks the row, then applies the `completed` transition |
| `validate` | pending post-deploy rows with a read-only command | the skill runs `rows[].command`, ticks passing rows |
| `advance` | a PR can start or merge; `command` is the skill to run | the user, from the printed command |
| `ask` | a candidate that is not closable or validatable; `reason` says why | the user, through the ask pass |
| `none` | nothing to do | nobody |

**Auto-close evidence rule.** All of these hold, or the kind is `ask` with the first failing reason:

- stage `awaiting_deploy`; every delivery PR `MERGED`; no open delivery PR; no unresolved blocker
- no undelivered Lifecycle row except `Deployed`; no pending `Follow-up:` or post-deploy row
- Jira `done`, or no `jira:` in the frontmatter
- every merge commit's `merge_checks` is `success`, meaning every check run concluded `success`, `neutral` or `skipped`, and the PR merged at least 15 minutes ago (`MERGE_CHECKS_SETTLE_SECONDS` in `effort-pr-sweep.py`: later workflows may not be queued yet, so a younger merge reads `pending` and a missing `mergedAt` reads `unknown`). `none`, `pending`, `unknown`, `failure` and any other conclusion all fail.
- every changed path of every delivery PR, both sides of a rename, matches `NON_DEPLOYED_PATH_PATTERNS` and none matches `NON_DEPLOYED_DENY_PATTERNS` in `effort-state.py`, which own the exact patterns. In words: docs, tests and CI only; anything that ships is denied, even under a test or docs name. `.github/` is an allow-list (workflows named `ci`, `test`, `lint`, `check`, `validate`, `pr` or `verify`, optionally with one platform or suite qualifier, plus `CODEOWNERS` and issue and PR templates), so any other workflow or script is denied, and `e2e/` is not a test directory. A truncated, empty or unread file list fails.
- an unchecked heavy suite under `## Validation` does not block the close: for a tests/CI/docs-only effort the merge commit's green checks are the evidence that stands in for it. A heavy post-deploy row still blocks (`validation-heavy-not-run`).
- exactly one unchecked `Deployed` row, and it is the bare label, optionally with `(if applicable)`, `(n/a)` or `(optional)`. A row that carries prose may hold the real blocker (Classifier Blind Spots, point 2), so it is never auto-ticked.

**Known limits.** `docs/**/*.md` and root `*.md` count as not deployed, so a repo that publishes docs or ships a README inside a package needs its `Deployed` row ticked by a human; the allow list cannot see that. An effort with any path outside the allow list never auto-closes, but docs and root markdown are inside it. A command with an env prefix (`GH_HOST=x gh ...`) is never auto-run, because env can change tool behaviour.

`close` returns `edit.old` and `edit.new`. Apply it as one exact-string edit: `- [x] Deployed - n/a, tests/CI/docs only ({evidence})`. Then re-run the classifier and apply the `completed` transition and move it returns, as in the `likely-delivery` repair.

**Read-only allowlist** for a post-deploy row's command. A command is the single backtick span that starts with a known tool. It runs only if it is exactly one invocation with no operator, redirect or substitution outside quotes and no control character (newline included) anywhere, and is one of:

- `gh api` where every method flag (`-X V`, `-XV`, `--method V`, `--method=V`) agrees on exactly one `GET`; with no method flag, no `-f`, `-F`, `--field` or `--raw-field`. Never `--input`, a method-override header, or an endpoint that is or ends with `graphql`.
- `gh pr|run|release view|list|checks`, without `--web` or `--watch`
- `az monitor log-analytics query`, `az monitor app-insights query`, `az monitor metrics list`, `az monitor activity-log list`; any other `az` command refuses
- `git grep|log|show`, optionally after `--no-pager` and `-C <path>`, and only with flags on that subcommand's positive list in `GIT_FLAG_SPECS`. An unknown flag refuses (`-O*`, `--open-files-in-pager`, `--output`, `-c`, `--exec-path`, `--config-env`).

Anything else is `validation-not-readonly`. Heavy local suites, matched on the command head only (`dotnet test|build`, `npm|pnpm|yarn test|build`, `vitest`, `jest`, `pytest`, `node --test`, `cargo`, `go test`, `bash tests/`), in a post-deploy row or an unchecked row under `## Validation` are `validation-heavy-not-run` and never run here.

**Validate.** Run only after `Deployed` is ticked; with `Deployed` unchecked the kind is `ask` with `deployed-needs-ring-evidence`. Each row carries `expect`, the backtick span after `expect`, `expects` or `expected` in the row, or null. A run passes only when the exit code is 0, the output is not empty (not whitespace, `[]`, `{}`, `null`, `0` or a table with no data rows), and the output contains `expect` when there is one. A passing run ticks the row and appends ` - validated {YYYY-MM-DD HH:MM}: {command} -> passed; output: {first 80 characters}`. A non-zero exit, or non-empty output that lacks `expect`, is `validation-failed`. Exit 0 with empty or zero-row output is `validation-inconclusive`. Neither is ticked.

**Advance.** Parse the `### PR Plan` table from `pr-plan-readiness.md`. A row is startable when its own PR has no delivery PR, every `Depends on` PR is `MERGED` in the live read or is the row's stack parent still `OPEN` (its `fsd-ready` cell reads `yes - stacks on {PR}`), and `External blockers` is `none`. A delivery PR maps to a plan row only when the lines that cite it name exactly one plan id (`PR2`, `PR-2`); any unmapped delivery PR turns the whole plan to `none` (`plan-prs-unattributed`) because it could be a row already opened. A prose plan has no columns and is never advanceable. Also: a `planned` effort with no PR and no blocker proposes `/nase:fsd {slug}`; `merge-ready` with an open PR proposes `/nase:prep-merge {pr_url}`.

**`ask` reason codes** (closed set): `deployed-needs-ring-evidence`, `jira-not-done`, `files-outside-tests-ci-docs`, `files-unverified`, `merge-checks-failing`, `merge-checks-unknown`, `validation-not-readonly`, `validation-heavy-not-run`, `validation-failed`, `validation-inconclusive`, `undelivered-row-stale`, `delivery-state-unresolved`, `delivery-pr-not-merged`, `plan-rows-pending`, `pending-followups`, `stalled`. The helper never emits `validation-failed` or `validation-inconclusive`; the skill sets them after a run. `plan-rows-pending` is a parsed PR Plan with a row whose own PR is not merged. `stalled` is no delivery PR and an untouched doc for 14 days. When a heavy suite is owed, `validation-heavy-not-run` leads an ask over the file-evidence reasons.

**Other reason codes** (closed set): `close` is `tests-ci-docs-only`; `validate` is `read-only-validation`; `advance` is `merge-ready-open-pr`, `planned-unblocked` or `plan-row-startable`; `none` is `blocked`, `no-plan-table`, `plan-prs-unattributed`, `no-startable-pr` or `deployed-checked` (Deployed is ticked and the transition decides the rest).

**Ask pass.** Batching follows `skill-contract.md`. `AskUserQuestion` allows at most 4 options per question and 4 questions per call, so group asks by reason code and split each group into chunks of at most 4 efforts, one chunk per question, at most 4 questions per call. The question names the reason, the state, the evidence and what is missing, then the suggested action marked `(Recommended)`. Its options are the chunk's efforts; a selected effort gets the suggested action, an unselected one stays open. Ask about at most the top 12 items per run by the ranking below. The rest stay in the report under Needs your decision as open. `--no-ask` skips the pass and lists every ask and advance as open.

**Top ranking.** The `Top:` chat line and the ask cap use one order: a close blocked by exactly one reason (`blocking` is 1), then `validation-failed` and `validation-inconclusive`, then `advance`, then every other ask. Ties break by slug.

**Boundary.** The skill edits effort docs, its own report and its log line, through the workspace write guard. It never runs a Jira transition or any PR write. When the user approves one in the ask pass, the skill prints the exact command or owning skill (`/nase:prep-merge`, `/nase:fsd`, the Jira transition) for the user to run. Only a read-only command that passed the allowlist is ever executed.

## PR Reference Resolution

The classifier's delivery and dependency sets include only structured lifecycle inputs;
report-only body references are context, never transition evidence. Within those inputs,
effort docs cite PRs three ways, and older docs lean on the shorthand:

1. **Full URL** - `https://github.com/{owner}/{repo}/pull/{n}` - in `pr`, `prs`,
   `phase_*_pr`, `blocked-by`, or a checked canonical `PR opened` lifecycle row.
2. **Qualified shorthand** - `{owner}/{repo}#{n}` (e.g. `acme/widget#4640`) - in
   those same structured locations.
3. **Bare number** - `#{n}` (e.g. `#4640`) - only in those structured frontmatter
   fields or a checked canonical `PR opened` lifecycle row. Resolve its repo from the
   nearest qualified/full reference in the doc, else from explicit `repo: {owner}/{repo}`
   frontmatter. Only the first token of that value is the identifier, so an annotated key
   (`repo: acme/widget (live; was greenfield)`) still resolves. A bare repo name has no
   owner context and is reported as `no-repo-context`.
   Quote a bare frontmatter value, for example `pr: "#4640"` or `- "#4640"`, because YAML
   otherwise treats the number as a comment.
   Do **not** treat bare `#{n}` in prose as a PR - bodies
   are full of non-PR `#{n}` (CHANGELOG entries, `grill #3`, `Codex Q10`, RFC markers), so a
   greedy bare-`#` sweep produces false PRs.

**Do not hand-roll the extraction.** `effort-state.py` returns the two sets the
transition depends on, already normalized and deduped, in every classify call:

```json
"pr_references": {
  "delivery":   [{"owner": "acme", "repo": "widget", "number": 4918,
                  "source": "frontmatter", "line": 7}],
  "dependency": [{"owner": "acme", "repo": "widget", "number": 4884,
                  "source": "frontmatter", "line": 12}],
  "discarded_bare": [{"number": 5, "line": 184, "reason": "denied-in-row"}],
  "validation_errors": []
}
```

`delivery` is the structured set defined above (`pr`, `prs`, `phase_*_pr`, plus checked
canonical `PR opened` rows); `dependency` comes from `blocked-by`. Report-only body
references stay the caller's job.

**A malformed structured key stops the transition.** `validation_errors` names the key
that cannot be read as written, and any entry makes `--evaluate-transition` return
`action: none` with `reason: invalid-pr-reference`. That is fail-closed on purpose: a key
the helper cannot parse might name the delivery PR that decides the transition, so
guessing past it would archive on partial evidence. The errors and their repairs:

| error | shape that produces it | repair |
|---|---|---|
| `invalid-{key}` | the same `pr`, `prs`, `phase_*_pr`, `blocked-by`, or `repo` key twice | keep one |
| `invalid-prs` | `prs` carrying its value inline, or empty with no `- ` items under it | give it a block list of `- ` items |
| `invalid-blocked-by` | `blocked-by` with an empty value and no list items | put the blocker inline or list it |
| `invalid-repo` | a `repo` identifier holding `/` that is not `{owner}/{repo}` | write `{owner}/{repo}` |
| `unresolved-{key}` | a singular `pr`/`phase_*_pr` naming zero or several PRs | one PR per key |
| `unresolved-prs` | a `prs` item with no resolvable PR | qualify it or drop it |

A scalar `blocked-by` is a legal shape per `effort-model.md → Dependency & Discovery
Fields`, including
short free text with no PR in it: that reports as blocked, never as a reference error.

**A row may disclaim its own numbers.** Effort docs label query, finding and step
numbers as `#5`, and they document past mis-resolutions by name
(`` a bare-`#` sweep resolved `#5` to the unrelated CLOSED `acme/widget-monitoring#5` ``).
On a row carrying such a denial the helper keeps only full URLs and drops the shorthand
and bare forms into `discarded_bare` - the shorthand there is the mistake being
described, not the delivery PR. Nobody writes a full URL by accident while denying it,
so form 1 survives. Read `discarded_bare` when a delivery set looks short; and note the
cost of the carve-out: a row whose only citation of its real PR is shorthand *and* that
also trips a denial phrase loses that PR, which reads as `no-delivery-pr` and leaves the
effort active. That direction is deliberate - a missing delivery PR stalls a transition,
a phantom one archives live work.

`source: "lifecycle:PR opened"` covers only rows whose label *starts* with the canonical
`PR opened` - a row written `- [x] W8 PR opened - <url>` is not canonical and contributes
neither stage evidence nor a delivery PR. Give such a PR a `phase_*_pr:` frontmatter
pointer, which is the supported way to name a per-phase delivery PR.

Form 3 additionally needs the row to sit under a `## Lifecycle` heading, which is what
makes `#{n}` definitionally a PR there. A canonical row outside any such section keeps
its full and qualified citations and reports its bare ones as
`reason: "outside-lifecycle"` - the number is not dropped quietly, because the effort
would otherwise read `no-delivery-pr` with nothing pointing at the row that holds it.

Verify each entry read-only with
`gh pr view {n} --repo {owner}/{repo} --json state,reviewDecision,statusCheckRollup,mergedAt`.

**Why this matters:** frontmatter `status:` drifts; PR state is the ground truth that
corrects it. URL-only extraction misses shorthand and can mis-bucket shipped work as
planning, hiding the drift this check exists to catch.

