# FSD Delivery Gates

This reference owns the conditional delivery controls used by `/nase:fsd`. It preserves the complete execution contract while keeping the command workflow concise. Load only the phase required for the current run.

## Contents

- [Phase 6.25: Candidate Quality Review](#phase-625-candidate-quality-review)
- [Phase 6.5: Candidate Spec Review](#phase-65-candidate-spec-review)
- [Shared QA State Machine](#shared-qa-state-machine)
- [Phase 8: Draft Pull Request and Verification Matrix](#phase-8-pull-request-if-pr--yes)
- [Phase 8c: KB Update](#phase-8c-kb-update)
- [Phase 10: Report](#phase-10-report)

## Phase 6.25: Candidate Quality Review

This is the single authoritative code-quality review. It runs after simplification, formatters, focused tests, canonical tests, flake checks, and the final size guard. Do not retain or reuse any earlier quality verdict.

### Fresh reviewer and exact contract

Generate the reviewer contract from the parser that will reduce the result:

```bash
python3 .claude/scripts/fsd-review-gate.py contract --kind quality \
  > "{nase_workspace}/workspace/tmp/fsd-quality-contract.json"
```

### Operator preflight - run before every reducer call

Prevent malformed operator input from reaching the reducer. Validate locally first; only call `reduce` once these hold:

- **Inventory shape**: `ref` values are `REQ-001`, `REQ-002`, ... in exact order, `id` values unique, every `summary` non-empty. The reducer rejects anything else outright.
- **Reviewer result shape**: parses as one JSON object and `artifact` echoes the four identity fields verbatim. For quality, every contract-declared axis and lens is present, and every `FAIL` axis or lens has a linked `P0`/`P1` finding. For spec, the inventory assessment and requirement rows match the exact inventory. `UNVERIFIABLE` needs a linked context request or an allowed human blocker.
- **Bundle binding**: `expected-bundle-sha256` equals `shasum -a 256` of the bundle file you are passing, and the result's `bundle_sha256` equals it too.

If a local check fails, fix the input and re-request from the provider without calling `reduce` or incrementing `qa_round`. Record it as `operator-retry: {what was malformed}`. Cap these pre-reducer retries at 3 per round, then stop as `blocked-infrastructure`. If `reduce` is called and returns `INVALID`, follow the shared state machine below; that attempt consumes the round.

Gate per `.claude/docs/codex-review.md → Prerequisite`. If the Codex MCP is unavailable, skip cleanly past only that invocation and spawn one fresh-context, read-only `verifier` with Read/Grep/Glob/Bash and no Edit/Write. Give either reviewer only:

- the generated quality contract
- the trusted artifact identity JSON generated with the bundle; instruct the reviewer to copy it exactly into `result.artifact`
- the exact candidate bundle from Phase 6.1
- the instruction to return one JSON object matching the contract, without Markdown fences

Do not include implementation reasoning, a proposed verdict, or prior reviewer text. Persist the returned bytes as the round result. Missing or malformed output is a reducer input failure, not a product decision.

### Review depth

Apply the full `discuss-pr` lens set: problem fit, correctness, simple-design search, architecture boundaries, security/privacy, reliability/data integrity, concurrency, compatibility/migration, performance, UI/accessibility, deployment/operability, testability, and comment accuracy. P0 and P1 need concrete evidence. P2 is deferred and does not gate.

The `test_quality` axis is blocking. It must judge observable behavioral contracts, plausible failure power or a mutation seam, risk-appropriate positive/negative/boundary/error paths, regression fidelity, concrete assertions over values/state/side effects/absence, isolation of nondeterministic inputs, mock fidelity, retry/order/concurrency/locale/timezone determinism, and whether parameterized cases add distinct behavior. Source-text grep, incidental snapshots, test count, and line coverage cannot alone prove behavior.

For bug fixes, reuse strict-TDD RED evidence or the original reproduction. Without that evidence, the reviewer must name the smallest plausible mutation the test would reject. Mutation, property, and fuzz tools may run only when already configured in the target repository and clearly relevant. Never install them for FSD.

### Deterministic reduction

```bash
python3 .claude/scripts/fsd-review-gate.py reduce \
  --kind quality --round "{qa_round}" \
  --repo "{worktree_or_repo}" \
  --inventory "{inventory_json}" \
  --bundle "{bundle_path}" \
  --expected-bundle-sha256 "{captured_bundle_sha256}" \
  --expected-base-oid "$BASE" \
  --result "{quality_result_json}" \
  --state "{nase_workspace}/workspace/tmp/fsd-qa-{branch_slug}-state.json" \
  > "{quality_decision_json}"
```

The reducer rejects unknown keys, invalid enum values, contradictory axis/finding states, unsafe paths, stale artifact identity, a bundle that differs from the SHA-256 captured before review, and a result that does not echo that exact hash. Required axes are `correctness`, `test_quality`, and `verification_evidence`. Conditional axes are emitted by `contract` and must be assessed or explicitly marked `NOT_APPLICABLE` with a reason. The generated `lens_coverage` contract also makes problem fit, simple design, architecture boundaries, and comment accuracy explicit instead of relying on free-form reviewer prose.

Only a quality `PROCEED` result may advance to Phase 6.5 on the same bundle.

## Phase 6.5: Candidate Spec Review

Generate the spec contract from the same reducer:

```bash
python3 .claude/scripts/fsd-review-gate.py contract --kind spec \
  > "{nase_workspace}/workspace/tmp/fsd-spec-contract.json"
```

Run a new fresh-context, read-only reviewer. Give it exactly **four** inputs: the spec contract, the trusted artifact identity JSON, **the requirement inventory as its own file**, and the same candidate bundle already approved by Phase 6.25.

`codex-verify-bundle.py` does **not** render `--inventory-file` into the bundle - it only binds it through `contract_inventory_sha256`. A spec reviewer told the inventory is "in the bundle" will correctly return `INCOMPLETE` and burn a round. Name the inventory file in the reviewer's read-list. Instruct it to copy the trusted identity exactly into `result.artifact`. The bundle's canonical task must include the original request and every Phase 2/design criterion used to derive the inventory. Require raw JSON matching the contract.

The reviewer first audits the canonical task/design criteria against the inventory through `inventory_assessment`. An omitted criterion is `INCOMPLETE` and blocks even when every submitted requirement is satisfied. It then returns every requirement in the inventory. The reducer compares count, order, `ref`, `id`, and `summary` exactly. Omission, duplicate, rewrite, reorder, or addition is `INVALID`. `SATISFIED` needs evidence. `MISSING` must be autofixable or carry an allowed human blocker. `UNVERIFIABLE` must carry an exact linked context request or allowed human blocker. Scope-creep items use the same evidence and repair rules.

Reduce it with the same state file:

```bash
python3 .claude/scripts/fsd-review-gate.py reduce \
  --kind spec --round "{qa_round}" \
  --repo "{worktree_or_repo}" \
  --inventory "{inventory_json}" \
  --bundle "{bundle_path}" \
  --expected-bundle-sha256 "{captured_bundle_sha256}" \
  --expected-base-oid "$BASE" \
  --result "{spec_result_json}" \
  --state "{nase_workspace}/workspace/tmp/fsd-qa-{branch_slug}-state.json" \
  > "{spec_decision_json}"
```

Set `approved_candidate_tree_oid` only when both reducers return `PROCEED` for the same `candidate_tree_oid`, `bundle_sha256`, and `contract_inventory_sha256`.

## Shared QA State Machine

Quality and spec share one `qa_round` budget of 1 through 3. They do not each receive three rounds.

The state file enforces the sequence: quality round 1 starts the machine, spec may run only after quality `PROCEED` in the same round and on the same artifact, and any non-proceed review advances the next attempt to quality in the next round. A terminal result or completed spec review rejects further reducer calls.

### Actions

The reducer emits `PROCEED`, `AUTOFIX`, `NEEDS_HUMAN`, `STALE`, `INVALID`, or internal `CONTEXT`.

| Action | FSD behavior |
|---|---|
| `PROCEED` | Quality advances to spec. Spec approves this candidate. |
| `AUTOFIX` | Apply every bounded P0/P1, missing-requirement, or scope repair after the round. Do not ask the user, and do not report the finding as a blocker - repair it and keep going. Then increment the shared round and restart at Phase 6. |
| `CONTEXT` | Deduplicate requests and automatic bundle gaps by bound tree and canonical path. Build the next bundle with `--context-request-file "{reducer_output_json}"` when requests exist, increment the shared round, and restart at Phase 6. |
| `NEEDS_HUMAN` | Stop only for the allowed blocker named by the reducer. |
| `STALE` or reducer-input `INVALID` | Consume the round. Do not reinterpret it as a product choice. Retry the finalization chain with a fresh provider result when a round remains. A call rejected before a valid state transition does not start or consume a round. |

Any code edit, test edit, formatter write, staging mismatch, commit-tree mismatch, or new context bundle makes all previous results stale. Never reuse a PASS for a similar diff or descendant commit.

The reducer owns no-progress identity. Reviewer finding refs, summaries, or paraphrases cannot change it. If `no_progress` or `no_change` is non-empty, do not repeat the same repair strategy. A malformed, stale, missing-provider-result, no-result, or no-change attempt still consumes the shared round. The five-iteration build/test budget remains cumulative and is not reset.

Context is always read from the bound Git tree. `codex-verify-bundle.py` resolves the requested path with `git ls-tree` against `base_oid` or `candidate_tree_oid`, then reads the exact resolved blob OID with `git cat-file`; it never reads the live worktree. Symlinks, gitlinks, missing blobs, special files, non-UTF-8 blobs, and context-cap exhaustion become evidence gaps. Bundle-declared gaps enter `CONTEXT` even when the reviewer did not request them. The reducer accepts at most 64 requests per result before any Git lookup. Each payload is capped at 64 KiB and total context at 256 KiB, with byte count and SHA-256 retained.

### Round 3 terminal behavior

Round 3 must not modify code or tests. Its reducer result closes the run as follows:

- verified remaining P0/P1, missing requirement, or scope defect: `NEEDS_HUMAN` with `QA_REPAIR_EXHAUSTED`
- explicit allowed human blocker: `NEEDS_HUMAN` with that blocker
- remaining context or non-blob evidence gap: `blocked-evidence`
- invalid, stale, provider/tool failure, or no result: `blocked-infrastructure`
- P2 only: `PROCEED` and defer it

This prevents a last-round edit from creating an unreviewed candidate.

### Human blocker taxonomy

The only reducer-approved human blockers are:

- `PRODUCT_DECISION`
- `CONTRACT_CONFLICT`
- `CREDENTIAL_OR_PERMISSION`
- `EXTERNAL_OR_CROSS_OWNER`
- `DESTRUCTIVE_OR_IRREVERSIBLE`
- `SECRET_UNCERTAINTY`
- `TEST_ORACLE_AMBIGUITY`
- `QA_REPAIR_EXHAUSTED`

Ordinary quality or spec failure is never an `AskUserQuestion`. Existing external mutation gates, the >1500-line scope decision, and secret uncertainty remain explicit human checkpoints.

After a human resolves a `NEEDS_HUMAN` blocker, record the decision, discard the terminal state and every prior review result, create a fresh QA state, and restart Phase 6 at `qa_round=1`. The cumulative five-iteration build/test budget does not reset.

---

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–4) to discover the PR template, draft the description with `surface=github-pr-body`, align the title with the commit subject, and preserve co-authors (relevant in team mode).

Then apply `.claude/docs/pr-gates-consumption.md` §3 with the Phase 1 `gate_profile`: ensure a required ticket key sits in the documented PR-title position, every required PR-body section exists at its minimum length, and — if the diff crossed a `gate_profile.size` threshold that mandates it — `## How to Review` is filled. Never invent a ticket key; keep the placeholder and flag it if unknown.

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
- `done` - every required criterion is `proven`; quality and spec are `PROCEED` for the same final candidate and bundle; the staged and committed trees equal `approved_candidate_tree_oid`; and final command evidence is newer than the last modification.
- `conditional` - every required criterion is `proven` or `waived`, with waiver reasons named.
- `not-closed` - any required criterion is `blocked` or unproven.

Never print `done ✓` when a criterion or final QA condition is unproven. If `success_criteria` = "Manual verify" (no explicit criteria), skip the ledger, but still require the quality/spec and tree-binding conditions. Note only the user-facing verification deferral.

Print a concise summary:

```
FSD {done ✓ | conditional ⚠ | not-closed ✗}

  Repo:        {repo_name}
  Branch:      {branch_name}
  Test iters:  {N} (passed on iteration N)
  QA rounds:   {qa_round}/3
  Candidate:   {approved_candidate_tree_oid}
  Bundle SHA:  {bundle_sha256}
  Quality:     {quality_action}
  Spec:        {spec_action}
  Tests:       {focused and canonical command evidence}
  QA fixes:    {P0/P1 auto-fixed count}; {P2 deferred count} P2 deferred
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
- **Test loop bound** - 5 cumulative iterations is a hard cap and QA rounds do not reset it. Exhaust automatic repairs before surfacing `QA_REPAIR_EXHAUSTED` or an evidence/infrastructure terminal state.
- **PR is always draft** - FSD never opens a ready-for-review PR. Promotion is a human decision.

</error_handling>
