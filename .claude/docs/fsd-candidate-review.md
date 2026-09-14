# FSD Candidate Review Gate

This reference owns the Phase 6.4 candidate review gate used by `/nase:fsd`: the generated contract, the operator preflight, the reviewer spawn, review depth, deterministic reduction, and the human blocker taxonomy. Load it when Phase 6.4 starts.

## Contents

- [Phase 6.4: Candidate Review](#phase-64-candidate-review)

## Phase 6.4: Candidate Review

One review covers both code quality and spec conformance, and its verdict is applied rather than re-litigated.

Run this after simplification, formatters, focused tests, canonical tests, flake checks, and the final size guard. Do not retain or reuse an earlier verdict.

Because the pass happens once, an `AUTOFIX` repair applied after it is never reviewed: the deterministic gates re-run and catch a build or test regression, but nothing re-examines design, naming, or test quality in the repaired lines. That is why `AUTOFIX` sets `disclose_unreviewed_repair` and Phase 10 must name the repaired files. Silently shipping an unreviewed repair is the one outcome this design must not produce.

An `INVALID` result or a `CONTEXT` request does not consume the pass, because neither says anything about the candidate - one is a reviewer format slip, the other a blob the bundle should have carried. Each is allowed once. Past that it is not a quality signal but an exhaustion the Actions table names: a second `INVALID` spends the malformed-result retry and yields, a second `CONTEXT` is `blocked-evidence` - the only `terminal_status` the reducer emits.

**The review is a gate on quality, not a gate on delivery.** A reviewer that cannot produce a usable result says nothing about the candidate, so an exhausted malformed-result retry does not stop the run: set `review_outcome = not-run` and continue to Phase 7. This is the one exhaustion that yields, because it is the only one whose cause lies entirely outside the candidate. `blocked-evidence` still stops, because a bundle that failed to carry what the reviewer asked for is a defect in our own payload and proceeding past it means never fixing it. `NEEDS_HUMAN` still stops, because its taxonomy covers product decisions, secret uncertainty and irreversible actions - things that are unsafe to decide by default.

Treat that yield as a real cost, not a formality. In practice a flaky reviewer means the gate is skipped most of the time, so a silent skip would quietly convert "reviewed" into "assumed fine" across a whole series of PRs. That is why `review_outcome = not-run` is stated in both places a reader arrives from: the PR body at Phase 8 and the Phase 10 report. Someone reading the PR months later should not have to reconstruct whether anyone looked at it.

### Generate the contract

```bash
python3 .claude/scripts/fsd-review-gate.py contract --kind combined \
  > "{nase_workspace}/workspace/tmp/fsd-review-contract.json"
```

### Operator preflight - run before every reducer call

Only call `reduce` once this exits 0:

```bash
python3 .claude/scripts/fsd-review-gate.py precheck --round "{qa_round}" \
  --inventory "{inventory_json}" --result "{result_json}" --bundle "{bundle_md}" \
  --expected-bundle-sha256 "{bundle_sha256}" --expected-base-oid "{base_oid}"
```

It runs the reducer's own inventory-shape, result-shape, and bundle-binding validators and prints `{"status": "ok"}` or the list of problems - but writes no state. That is the whole point: `reduce` records an `InvalidResultError` in its history and spends the round's single INVALID retry, so a malformed reviewer reply must never reach it. Do not re-derive these checks by hand.

A failing precheck is fixed and re-requested from the provider without calling `reduce`. Cap those pre-reducer retries at 3, then set `review_outcome = not-run` and continue.

A reviewer that returns nothing at all - an empty turn, an idle signal, no JSON - never reaches `reduce`, so it is this cap that catches it rather than the reducer. Re-request once with the missing-output problem named explicitly, because an empty turn is often a reviewer declining the task shape rather than failing at it, and a second attempt with the four input paths restated frequently succeeds. Do not record an empty turn as a passing review; there is no verdict to record.

### Run the reviewer

Spawn one fresh-context read-only reviewer. The reviewer is a local subagent, so
there is no availability branch here: the gate always runs, and the only ways it
yields are the result-shape failures described above. Its instructions are
`Mode: verify` in `.claude/docs/review-mode-verify.md`, handed over verbatim.

**Route it through the `verifier` role in `.claude/roles.yaml`**, which already encodes what this reviewer needs: `tools: [Read, Grep, Glob, Bash]` with no Edit/Write, and a `prompt_prefix` that asks for faithful reporting rather than a soft pass. Naming the role matters because the tool shape alone does not identify a usable agent. A search-oriented agent whose own definition says it locates code and does not review or audit it will accept the spawn and then return an empty turn - which reads exactly like an infrastructure failure and consumes the retry budget for a reason that is really agent selection. If a project-level or plugin reviewer agent is available and is review-capable, it is a fine substitute, but check its tool whitelist: an agent with Edit/Write is read-only only by instruction, which is weaker than the role's whitelist, and the Phase 10 report should say which of the two guarantees applied.

Give the reviewer exactly four things:

1. the generated contract
2. the trusted artifact identity JSON written with the bundle, to copy verbatim into `result.artifact`
3. the candidate bundle from Phase 6.1
4. **the requirement inventory as its own file**

`verify-bundle.py` binds the inventory by hash but does not render it into the bundle, so a reviewer told the inventory is "in the bundle" will correctly report it cannot enumerate the requirements. Name the inventory file in the reviewer's read-list.

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
