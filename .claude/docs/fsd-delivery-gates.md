# FSD Delivery Gates

This reference owns the conditional delivery controls used by `/nase:fsd`. It preserves the complete execution contract while keeping the command workflow concise. Load only the phase required for the current run.

## Contents

- [Phase 6.4: Candidate Review](#phase-64-candidate-review)
- [Phase 8: Pull Request](#phase-8-pull-request-if-pr--yes)
- [Phase 8.5: Verification Matrix](#phase-85-verification-matrix)
- [Phase 8c: KB Update](#phase-8c-kb-update)
- [Phase 10: Report](#phase-10-report)

## Phase 6.4: Candidate Review

One review covers both code quality and spec conformance, and its verdict is applied rather than re-litigated.

Run this after simplification, formatters, focused tests, canonical tests, flake checks, and the final size guard. Do not retain or reuse an earlier verdict.

Because the pass happens once, an `AUTOFIX` repair applied after it is never reviewed: the deterministic gates re-run and catch a build or test regression, but nothing re-examines design, naming, or test quality in the repaired lines. That is why `AUTOFIX` sets `disclose_unreviewed_repair` and Phase 10 must name the repaired files. Silently shipping an unreviewed repair is the one outcome this design must not produce.

An `INVALID` result or a `CONTEXT` request does not consume the pass, because neither says anything about the candidate - one is a reviewer format slip, the other a blob the bundle should have carried. Each is allowed once. Past that it is not a quality signal but a terminal state the Actions table names: `blocked-infrastructure` for a second `INVALID`, `blocked-evidence` for a second `CONTEXT`.

**The review is a gate on quality, not a gate on delivery.** A reviewer that cannot produce a usable result says nothing about the candidate, so `blocked-infrastructure` does not stop the run: set `review_outcome = not-run` and continue to Phase 7. This is the one terminal state that yields, because it is the only one whose cause lies entirely outside the candidate. `blocked-evidence` still stops, because a bundle that failed to carry what the reviewer asked for is a defect in our own payload and proceeding past it means never fixing it. `NEEDS_HUMAN` still stops, because its taxonomy covers product decisions, secret uncertainty and irreversible actions - things that are unsafe to decide by default.

Treat that yield as a real cost, not a formality. In practice a flaky reviewer means the gate is skipped most of the time, so a silent skip would quietly convert "reviewed" into "assumed fine" across a whole series of PRs. That is why `review_outcome = not-run` is stated in both places a reader arrives from: the PR body at Phase 8 and the Phase 10 report. Someone reading the PR months later should not have to reconstruct whether anyone looked at it.

### Generate the contract

```bash
python3 .claude/scripts/fsd-review-gate.py contract --kind combined \
  > "{nase_workspace}/workspace/tmp/fsd-review-contract.json"
```

### Operator preflight - run before every reducer call

Validate locally first; only call `reduce` once these hold:

- **Inventory shape**: `ref` values are `REQ-001`, `REQ-002`, ... in exact order, `id` values unique, every `summary` non-empty.
- **Result shape**: parses as one JSON object; `artifact` echoes the four identity fields verbatim; `requirements` has exactly the inventory refs in order; every non-`SATISFIED` requirement has one matching `requirement_exceptions` entry; every `FAIL` axis or lens has a linked finding.
- **Bundle binding**: `expected-bundle-sha256` equals `shasum -a 256` of the bundle you are passing, and the result's `bundle_sha256` equals it too.

A local check that fails is fixed and re-requested from the provider without calling `reduce`. Cap those pre-reducer retries at 3, then set `review_outcome = not-run` and continue.

A reviewer that returns nothing at all - an empty turn, an idle signal, no JSON - never reaches `reduce`, so it is this cap that catches it rather than the reducer. Re-request once with the missing-output problem named explicitly, because an empty turn is often a reviewer declining the task shape rather than failing at it, and a second attempt with the four input paths restated frequently succeeds. Do not record an empty turn as a passing review; there is no verdict to record.

### Run the reviewer

Gate per `.claude/docs/codex-review.md → Prerequisite`. If the Codex MCP is unavailable, skip cleanly past only that invocation and spawn one fresh-context read-only reviewer.

**Route it through the `verifier` role in `.claude/roles.yaml`**, which already encodes what this reviewer needs: `tools: [Read, Grep, Glob, Bash]` with no Edit/Write, and a `prompt_prefix` that asks for faithful reporting rather than a soft pass. Naming the role matters because the tool shape alone does not identify a usable agent. A search-oriented agent whose own definition says it locates code and does not review or audit it will accept the spawn and then return an empty turn - which reads exactly like an infrastructure failure and consumes the retry budget for a reason that is really agent selection. If a project-level or plugin reviewer agent is available and is review-capable, it is a fine substitute, but check its tool whitelist: an agent with Edit/Write is read-only only by instruction, which is weaker than the role's whitelist, and the Phase 10 report should say which of the two guarantees applied.

Give the reviewer exactly four things:

1. the generated contract
2. the trusted artifact identity JSON written with the bundle, to copy verbatim into `result.artifact`
3. the candidate bundle from Phase 6.1
4. **the requirement inventory as its own file**

`codex-verify-bundle.py` binds the inventory by hash but does not render it into the bundle, so a reviewer told the inventory is "in the bundle" will correctly report it cannot enumerate the requirements. Name the inventory file in the reviewer's read-list.

Do not include implementation reasoning, a proposed verdict, or prior reviewer text. Persist the returned bytes as the round result. Missing or malformed output is a reducer input failure, not a product decision.

### Review depth

Apply the full `discuss-pr` lens set: problem fit, correctness, simple-design search, architecture boundaries, security/privacy, reliability/data integrity, concurrency, compatibility/migration, performance, UI/accessibility, deployment/operability, testability, and comment quality.

A conditional axis that passes proves it was looked at with one short evidence string; the three required axes and anything that is not `PASS` carry a full reason, because those are the ones a human acts on.

`findings` holds only `P0` and `P1` - things that must change before this ships. Everything else worth mentioning goes in `deferred` as a one-line string with `path:line`, carrying no severity, no repair fields, and no blocker.

The `test_quality` axis is blocking. It must judge observable behavioral contracts, plausible failure power or a mutation seam, risk-appropriate positive/negative/boundary/error paths, regression fidelity, concrete assertions over values/state/side effects/absence, isolation of nondeterministic inputs, mock fidelity, retry/order/concurrency/locale/timezone determinism, and whether parameterized cases add distinct behavior. Source-text grep, incidental snapshots, test count, and line coverage cannot alone prove behavior.

The `comment_quality` lens scores necessity and concision as well as truth, against `.claude/docs/code-comment-policy.md` - an accurate comment that the policy says never earns its place is still a finding. When a comment and the code disagree, the policy's *Existing comments* rule decides which one is wrong; if the code is wrong, the finding belongs on `correctness` at its own severity, not here.

Since a `deferred` note is never repaired, use it only for things you are content to ship. A comment you actually want gone is a `P1` whose `smallest_fix` is the deletion; cluster every occurrence into that one finding, anchored at the first with the siblings in `evidence`.

For bug fixes, reuse strict-TDD RED evidence or the original reproduction. Without that evidence, the reviewer must name the smallest plausible mutation the test would reject. Mutation, property, and fuzz tools may run only when already configured in the target repository and clearly relevant. Never install them for FSD.

The reviewer also audits the canonical task and design criteria against the inventory through `inventory_assessment`. A criterion the inventory omits is `INCOMPLETE` and blocks even when every submitted requirement is satisfied.

### Deterministic reduction

```bash
python3 .claude/scripts/fsd-review-gate.py reduce \
  --kind combined --round "{qa_round}" \
  --repo "{worktree_or_repo}" \
  --inventory "{inventory_json}" \
  --bundle "{bundle_path}" \
  --expected-bundle-sha256 "{captured_bundle_sha256}" \
  --expected-base-oid "$BASE" \
  --result "{result_json}" \
  --state "{nase_workspace}/workspace/tmp/fsd-qa-{branch_slug}-state.json" \
  > "{decision_json}"
```

The reducer rejects unknown keys, invalid enum values, contradictory axis/finding states, unsafe paths, stale artifact identity, a bundle that differs from the SHA-256 captured before review, and a result that does not echo that exact hash. Required axes are `correctness`, `test_quality`, and `verification_evidence`. Conditional axes must be assessed or explicitly marked `NOT_APPLICABLE` with a reason.

### Actions

| Action | FSD behavior |
|---|---|
| `PROCEED` | Set `approved_candidate_tree_oid` and continue to Phase 7. |
| `AUTOFIX` | Apply every bounded finding, missing requirement, and scope repair. Do not ask the user and do not report them as blockers. Re-run the Phase 6.1 deterministic gates over the repaired tree, refreeze the candidate, then continue to Phase 7 - there is no second review. Carry `disclose_unreviewed_repair` into Phase 10. |
| `CONTEXT` | Rebuild the bundle with `--context-request-file "{decision_json}"`, increment the round, and re-run the reviewer once. A second `CONTEXT` is `blocked-evidence`. |
| `NEEDS_HUMAN` | Stop for the allowed blocker the reducer named. |
| `INVALID` or `STALE` | Re-request a fresh result from the provider at the same round, once. A second one sets `review_outcome = not-run` and continues to Phase 7. |

Ordinary quality or spec failure is never an `AskUserQuestion`. Existing external mutation gates, the >1500-line scope decision, and secret uncertainty remain explicit human checkpoints.

### When the review did not run

`review_outcome = not-run` means no verdict exists for this candidate. Three things follow, and they are what keep the skipped gate from becoming invisible:

- **Phase 7 binds `tested_candidate_tree_oid`** rather than `approved_candidate_tree_oid`, which no action set. The tree assertions still run and still have to match exactly; what is missing is a review of that tree, not the guarantee that the tree which shipped is the tree the gates ran against.
- **`closure_state` cannot be `done`.** Its definition requires a `PROCEED` verdict for the final candidate, so the best available outcome is `conditional`, with "candidate review did not run" as the named waiver reason. A run whose review never happened has not met the bar `done` describes, and printing `done` for it would make the ledger unreadable as a signal.
- **The candidate artifacts are retained and named.** The bundle, requirement inventory, evidence and reviewer identity are already bound to the candidate tree by hash, so the review can still be run later against exactly this candidate without redoing the work. Say where they are, so that is a real option rather than a theoretical one.

Report what actually failed, in one line: which provider was tried, how many attempts, and what came back. "Two attempts returned an idle signal with no output" tells the next reader something; "review unavailable" does not, and it hides the agent-selection cause described above.

Any code edit, test edit, formatter write, staging mismatch, or commit-tree mismatch after the review invalidates it. The only sanctioned post-review edit is the `AUTOFIX` repair itself.

### Human blocker taxonomy

The only reducer-approved human blockers are `PRODUCT_DECISION`, `CONTRACT_CONFLICT`, `CREDENTIAL_OR_PERMISSION`, `EXTERNAL_OR_CROSS_OWNER`, `DESTRUCTIVE_OR_IRREVERSIBLE`, `SECRET_UNCERTAINTY`, and `TEST_ORACLE_AMBIGUITY`.

After a human resolves one, record the decision, discard the terminal state and the prior result, create a fresh QA state, and restart Phase 6 at `qa_round=1`. The cumulative five-iteration build/test budget does not reset.

---

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–4) to discover the PR template, draft the description with `surface=github-pr-body`, align the title with the commit subject, and preserve co-authors (relevant in team mode).

Then apply `.claude/docs/pr-gates-consumption.md` §3 with the Phase 1 `gate_profile`: ensure a required ticket key sits in the documented PR-title position, every required PR-body section exists at its minimum length, and - if the diff crossed a `gate_profile.size` threshold that mandates it - `## How to Review` is filled. Never invent a ticket key; keep the placeholder and flag it if unknown.

If `review_outcome = not-run`, the PR body states it in whichever section carries verification for this repo's template, alongside the deterministic gates that did pass. The reviewer on the PR is the person who most needs to know that nothing independent has looked at it yet, and they are the one reader who cannot find that out from the Phase 10 report.

Before the GitHub actions below, run the GitHub auth account guard snippet from `.claude/docs/external-mutation-policy.md → GitHub auth account guard`. Every `gh` mutation below is the exact argv passed to `external-write-action.py`; never run a raw mutating `gh` command.

Draft the exact PR payload and show it to the user. Gate creation via `AskUserQuestion` immediately before the mutation:

```
question: "Create this draft PR?"
header: "Draft PR"
options:
  - label: "Create draft PR"
    description: "Run gh pr create with the title, body, base, and head shown above"
  - label: "Skip PR create"
    description: "Leave the pushed branch without opening a PR"
```

If skipped, do not prepare an action; report the pushed branch and the command the user can run later.

If approved, run the auth guard, write the already-shown body to a private file, then prepare, show, authorize, and execute this exact action:
```bash
PR_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fsd-pr-body.XXXXXXXX.md")
chmod 600 "$PR_BODY_FILE"
trap 'rm -f "$PR_BODY_FILE"' EXIT
cat > "$PR_BODY_FILE" <<'EOF'
{pr_body_from_template}
EOF
MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
  --system github --summary "create draft PR {repo_owner}/{repo_name}" -- \
  gh pr create --draft --title "{commit_subject_line}" --body-file "$PR_BODY_FILE" \
  --base {default_branch} --head {branch_name} -R {repo_owner}/{repo_name} | jq -r .manifest)
jq . "$MANIFEST"
# AskUserQuestion approved this exact manifest. Then:
python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
```

Report the PR URL.

---

## Phase 8.5: Verification Matrix

Build a verification matrix so the reviewer knows what to run before promoting the draft PR.

Follow `.claude/docs/verification-matrix.md` §1, §2, §3, §5. Skip §4 because fsd is producing the plan. Phase 6.1 final canonical test evidence becomes the Unit `✅ done` row.

**Execute before rendering:** a matrix fsd only writes is a promise; a matrix fsd partially ran is evidence. Before rendering:
- Attempt every `required` row whose `command` runs locally inside `{work_root}`: local builds, env-var-switched `dotnet run`/`npm start` smoke checks, dry-run commands.
- When `claudeRunSkills.recipes` exists and the change affects runtime behavior, include `/verify` as a required behavioral row and run it before manual smoke rows that duplicate the same coverage.
- Attempt the 🔥 critical row above all when it can run locally.
- Record outcomes as `✅ done` with the actual output as evidence.
- Skip rows needing deployment, external environments, or credentials fsd doesn't hold. Mark those `not run by fsd` explicitly; never fabricate.
- If the 🔥 critical row exists and could not be run locally, say so in the Phase 10 report's Critical line.

Skill-specific outputs:

1. **Append to PR body** only if `open_pr = true` and matrix has rows. Show the exact `## Verification` section and gate `gh pr edit` via `AskUserQuestion`:
   ```
   question: "Append this Verification section to the draft PR?"
   header: "PR Verification"
   options:
     - label: "Append verification"
       description: "Run gh pr edit --body-file with the section shown above"
     - label: "Skip PR edit"
       description: "Leave the PR body unchanged; include the matrix only in the final report"
   ```
   If skipped, do not edit the PR body; still surface the matrix in Phase 10. If approved, prepare, show, authorize, and execute this payload-bound action:
   ```bash
   PR_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fsd-pr-body.XXXXXXXX.md")
   chmod 600 "$PR_BODY_FILE"
   trap 'rm -f "$PR_BODY_FILE"' EXIT
   gh pr view {pr_number} -R {owner}/{repo} --json body --jq .body > "$PR_BODY_FILE"
   # Append the Verification section to the file, then:
   MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
     --system github --summary "append verification to PR {owner}/{repo}#{pr_number}" -- \
     gh pr edit {pr_number} -R {owner}/{repo} --body-file "$PR_BODY_FILE" | jq -r .manifest)
   jq . "$MANIFEST"
   python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
   python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
   ```
   Append only; never overwrite. Skip when matrix has no rows.

2. **Surface in Phase 10 report**: pass critical layer and caveat to final report.

3. **No PR**: render the matrix in Phase 10.

---

## Phase 8c: KB Update

Persist before cleanup:

**1. Research gate findings** (from Phase 3.5): if `research_gate_findings` is non-empty, invoke `/nase:learn` for each library/API candidate and apply its verification triad before writing to the general KB. Preserve the existing persistence outcome and include signatures, required params, return types, pitfalls, and the official doc URL, but keep candidates that fail V2 or V3 in the FSD research artifact instead of the active KB. `/nase:learn` owns target resolution, current-state reconciliation, confidence, domain-map registration, and the guarded write.

**2. Implementation discoveries**: if implementation revealed new patterns, architectural insights, or hard constraints specific to the target repo, invoke `/nase:kb-update [domain]` with a concise summary.

Team mode: read `workspace/tmp/fsd-research-{branch_slug}.md` if present. Persist
its findings here. Retain it with a claimed worktree, or delete it at the start
of Phase 10 when no worktree was created. Do not defer KB updates to wrap-up.

---

## Phase 10: Report

For a no-worktree flow, delete `workspace/tmp/fsd-phases-{branch_slug}.md` and
`workspace/tmp/fsd-research-{branch_slug}.md` before reporting.

**First build the Success-Criteria Ledger.** One row per `success_criteria` item (from Phase 2 / the design doc), each mapped to exactly one:
- `proven` - cite the evidence: a test name, a Phase 8.5 matrix row, or a check run. A green build is not proof a criterion is met.
- `waived` - recorded reason.
- `blocked` - named blocker.

Derive `closure_state`:
- `done` - every required criterion is `proven`; the review returned `PROCEED` for the final candidate and bundle; the staged and committed trees equal `approved_candidate_tree_oid`; and final command evidence is newer than the last modification.
  - `review_outcome = not-run` fails this by definition, since there is no `PROCEED` and no `approved_candidate_tree_oid`. Such a run is at best `conditional`.
- `conditional` - every required criterion is `proven` or `waived`, with waiver reasons named.
- `not-closed` - any required criterion is `blocked` or unproven.

Never print `done ✓` when a criterion or final QA condition is unproven. If `success_criteria` = "Manual verify" (no explicit criteria), skip the ledger, but still require the review and tree-binding conditions. Note only the user-facing verification deferral.

**When the decision carried `disclose_unreviewed_repair`,** the tree that shipped is not the tree that was reviewed. Say so in the report and name the files the repair touched, so whoever reads the PR can weigh it. A repair applied after the only review is defensible; one that goes unmentioned is not.

**When `review_outcome = not-run`,** nothing was reviewed at all, which is the wider version of the same problem. The report says so, names the provider and what came back, and states which deterministic gates did pass - the build, the suite against its baseline, the lint and format gates, the flake evidence - because those are the whole basis for shipping in that case and the reader deserves to see the actual basis rather than infer it. Point at the retained candidate artifacts too. `disclose_unreviewed_repair` and `not-run` can both be set; report both rather than letting the larger one absorb the smaller. In the summary below, `Candidate` carries `tested_candidate_tree_oid`, `Reviewed` reads `not reviewed`, and `Review` names the provider and what came back rather than an action the reducer never returned.

Print a concise summary:

```
FSD {done ✓ | conditional ⚠ | not-closed ✗}

  Repo:        {repo_name}
  Branch:      {branch_name}
  Test iters:  {N} (passed on iteration N)
  Candidate:   {approved_candidate_tree_oid}
  Reviewed:    {reviewed_candidate_tree_oid} - append "(repaired after review, unreviewed)" when disclose_unreviewed_repair
  Bundle SHA:  {bundle_sha256}
  Review:      {review_action} - note the retry or context refill when the pass used one
  Tests:       {focused and canonical command evidence}
  QA fixes:    {P0/P1 auto-fixed count}; {deferred count} deferred
  Context:     {context batch count}
  QA blocker:  {infrastructure/evidence blocker or "none"}
  PR:          {PR URL} - or "not opened"
  Worktree:    {worktree_report}

Criteria: - omit block if "Manual verify"
  - {criterion} - proven: {evidence}
  - {criterion} - waived: {reason} - or blocked: {blocker}

Verification before promote (full matrix appended to PR body):
  🔥 Critical:  {critical layer label} - {why} - omit if no critical row
  Caveat:      {coverage caveat} - omit if none
  Required:    {list required rows by short label}
  Recommended: {list recommended rows by short label} - omit if none

Next: open the draft PR, run the Verification matrix, then promote to "ready for review".
```

If Phase 8.5 produced no rows (pure docs / comments change), omit the entire "Verification before promote" block.

If the Phase 1 gate-profile load used the live-fetch fallback, add the stale-KB note from `.claude/docs/pr-gates-consumption.md` §2 (`Run /nase:onboard {repo} to persist`).

Append to the daily log following `.claude/docs/daily-log-format.md` (tag: `fsd`; add `large-diff` too if Phase 6.1 marked it).
Log: `{one-line task summary} -> \`{branch_name}\` [{PR URL or "no PR"}]`

If the run had a surprise/non-obvious win (novel approach, avoided near-miss, build iters > 1, ambiguous requirement resolved), append to `workspace/journals/{YYYY-MM-DD}.md`:

```
### fsd: {one-line task summary}
- **Approach**: {Direct / Team / Phase-isolated} - {why it fit this task}
- **What worked**: {key decision or technique that made implementation smooth}
- **Build iters**: {N}/5
- **Gotchas**: {any surprise or near-miss}
```

Skip failed or routine no-surprise runs; routine wins dilute downstream skill-optimization signal.

## Error Handling

<error_handling>

- **Continue after Phase 2** - ordinary build, test, quality, and spec failures are automatically repaired and reverified. Ask only for an approved human blocker, the existing external mutation gates, >1500-line scope choice, or secret uncertainty.
- **Protected branches** - never commit directly to `main`, `master`, `develop`, or `release/*`. FSD always works on a feature branch.
- **Worktree path** - always take it from `.claude/docs/worktree-pattern.md -> Naming Convention` (`$HOME/.nase-worktrees/{repo_name}-{suffix}`). Never create it inside the repo, which causes git nesting issues, and never under `/tmp`, which the OS sweeps.
- **Secrets** - if unsure about a file during the staging scan, stop and ask rather than committing and reverting later.
- **Test loop bound** - 5 cumulative iterations is a hard cap and the review pass does not reset it. Exhaust automatic repairs before surfacing an evidence or infrastructure terminal state.
- **PR is always draft** - FSD never opens a ready-for-review PR. Promotion is a human decision.

</error_handling>
