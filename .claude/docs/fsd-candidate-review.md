# FSD Candidate Review Gate

This reference owns the Phase 6.4 candidate review gate used by `/nase:fsd`: the generated contract, the operator preflight, the reviewer spawn, review depth, deterministic reduction, and the human blocker taxonomy. Load it when Phase 6.4 starts.

## Contents

- [Phase 6.4: Candidate Review](#phase-64-candidate-review)

## Phase 6.4: Candidate Review

One review covers both code quality and spec conformance, and its verdict is applied rather than re-litigated.

Run this after simplification, formatters, focused tests, canonical tests, flake checks, and the final size guard. Do not retain or reuse an earlier verdict.

Because the pass happens once, an `AUTOFIX` repair applied after it is never reviewed: the deterministic gates re-run and catch a build or test regression, but nothing re-examines design, naming, or test quality in the repaired lines. That is why `AUTOFIX` sets `disclose_unreviewed_repair` and Phase 10 must name the repaired files. Silently shipping an unreviewed repair is the one outcome this design must not produce.

An `INVALID` result or a `CONTEXT` request does not consume the pass, because neither says anything about the candidate - one is a reviewer format slip, the other a blob the bundle should have carried. Each is allowed once. Past that it is not a quality signal but an exhaustion the Actions table names: a second `INVALID` spends the malformed-result retry and stops the run with `review_outcome = not-run`, a second `CONTEXT` is `blocked-evidence` - the only `terminal_status` the reducer emits.

**The review gate is never skipped.** A reviewer that cannot produce a usable result says nothing about the candidate, but it also means nobody independent has looked at it. So an exhausted malformed-result retry, an exhausted precheck cap, or a reviewer that returns nothing stops the run: set `review_outcome = not-run` and stop with a clear error before Phase 7. Nothing is committed, pushed, or opened as a PR. `blocked-evidence` still stops, because a bundle that failed to carry what the reviewer asked for is a defect in our own payload. `NEEDS_HUMAN` still stops, because its taxonomy covers product decisions, secret uncertainty and irreversible actions - things that are unsafe to decide by default.

A stopped run is a loud failure, not a quiet downgrade. Do not offer to continue without the review, and do not mark a PR ready on the strength of the deterministic gates alone. The way forward is to fix the reviewer, then re-run the gate against the retained candidate (see *When the review did not run*).

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

A failing precheck is fixed and re-requested from the provider without calling `reduce`. Cap those pre-reducer retries at 3, then set `review_outcome = not-run` and stop with the error described in *When the review did not run*.

A reviewer that returns nothing at all - an empty turn, an idle signal, no JSON - never reaches `reduce`, so it is this cap that catches it rather than the reducer. Re-request once with the missing-output problem named explicitly, because an empty turn is often a reviewer declining the task shape rather than failing at it, and a second attempt with the four input paths restated frequently succeeds. Do not record an empty turn as a passing review; there is no verdict to record.

### Run the reviewer

Spawn one fresh-context read-only reviewer as the persisted agent `nase-verifier` (`.claude/agents/nase-verifier.md`), the enforced form of the `verifier` role in `.claude/roles.yaml`. Its frontmatter allows only `Read`, `Grep`, and `Glob`, so read-only is a tool whitelist and not an instruction. The reviewer is a local subagent, so there is no availability branch here: the gate always runs, and the only ways it stops are the result-shape failures described above. Its instructions are `Mode: verify` in `.claude/docs/review-mode-verify.md`, handed over verbatim.

If `nase-verifier` is not registered in the session, stop with that error. Do not fall back to a search-oriented agent: one whose own definition says it locates code and does not review or audit it accepts the spawn and then returns an empty turn, which reads exactly like an infrastructure failure and consumes the retry budget for a reason that is really agent selection. Do not substitute a project-level or plugin reviewer that holds Edit or Write, because that is read-only by instruction alone.

**Reviewer for every verification gate.** The persisted `nase-verifier` is the one reviewer for the fsd candidate review and for both `/nase:address-comments` gates (`.claude/docs/address-comments-analysis.md` Step 3d, `.claude/docs/pr-review-fix-verification.md` §9). Each gate runs it as one fresh-context read-only subagent. All three are local, so none has an availability branch, and a gate that applies is never skipped. An unregistered `nase-verifier`, or a reviewer that returns no usable result, stops the run with an error; the `verifier` role is never a fallback.

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

The `simple_design` lens adds two checks. **Scope trace:** every new abstraction, parameter, file, flag, or branch must trace to a success criterion or to `design_intent`; an addition that traces to neither is a finding. **Workaround detection:** any smell listed in `.claude/docs/design-principles.md` → Solution selection is a finding, unless the change states why it is not treating a symptom.

The `problem_fit` lens adds **Intent conformance** against `design_intent`: the change must serve the `Why:`, reach `Done looks like:`, and not touch anything on the `Not wanted:` list. When there is no `design_intent` (a run with no effort doc), skip this check.

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
| `INVALID` | Re-request a fresh result from the provider at the same round, once. A second one sets `review_outcome = not-run` and stops the run. |
| `STALE` | The candidate genuinely moved after the bundle was built. The reducer records terminal `STALE`, so rebuild the bundle for the current candidate and review again. A git probe failure (`GitProbeError`) is not `STALE`: `fsd-review-gate.py` exits 2, writes no state, and the same call can be retried. |

Ordinary quality or spec failure is never an `AskUserQuestion`. Existing external mutation gates, the >1500-line scope decision, and secret uncertainty remain explicit human checkpoints.

### When the review did not run

`review_outcome = not-run` means no verdict exists for this candidate, and the run stops here. Three things follow.

- **Phase 7 never starts.** No `approved_candidate_tree_oid` exists, and `tested_candidate_tree_oid` is never promoted into its place. Nothing is committed, pushed, or opened.
- **`closure_state` is not `done`.** The Phase 10 report says the run stopped at the review gate, so the ledger stays readable as a signal.
- **The candidate artifacts are retained and named.** The bundle, requirement inventory, evidence and reviewer identity are already bound to the candidate tree by hash, so the review can be re-run against exactly this candidate once the reviewer works, without redoing the work. Say where they are, so that is a real option rather than a theoretical one.

Report what actually failed, in one line: which provider was tried, how many attempts, and what came back. "Two attempts returned an idle signal with no output" tells the next reader something; "review unavailable" does not, and it hides the agent-selection cause described above.

Any code edit, test edit, formatter write, staging mismatch, or commit-tree mismatch after the review invalidates it. The only sanctioned post-review edit is the `AUTOFIX` repair itself.

### Human blocker taxonomy

The only reducer-approved human blockers are `PRODUCT_DECISION`, `CONTRACT_CONFLICT`, `CREDENTIAL_OR_PERMISSION`, `EXTERNAL_OR_CROSS_OWNER`, `DESTRUCTIVE_OR_IRREVERSIBLE`, `SECRET_UNCERTAINTY`, and `TEST_ORACLE_AMBIGUITY`.

After a human resolves one, record the decision, discard the terminal state and the prior result, create a fresh QA state, and restart Phase 6 at `qa_round=1`. The cumulative five-iteration build/test budget does not reset.

---
