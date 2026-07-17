# FSD Delivery Gates

This reference owns the conditional delivery controls used by `/nase:fsd`. It preserves the complete execution contract while keeping the command workflow concise. Load only the phase required for the current run.

## Contents

- [Phase 5.75: Pre-Commit Deep-Dive Self-Review](#phase-575-pre-commit-deep-dive-self-review-loop-fresh-context-until-clean)
- [Phase 6.5: Pre-Push Verification](#phase-65-pre-push-verification-gate-codex-with-single-model-fallback)
- [Phase 8: Draft Pull Request and Verification Matrix](#phase-8-pull-request-if-pr--yes)
- [Phase 8c: KB Update](#phase-8c-kb-update)

## Phase 5.75: Pre-Commit Deep-Dive Self-Review Loop (fresh-context, until clean)

Before simplifying or committing, the diff gets a real review at the depth of `/nase:discuss-pr`, and each finding is acted on with the discipline of `/nase:address-comments` — adapted to a pre-push local diff. There is no GitHub PR yet, so nothing here posts, replies, or resolves threads; the borrowed structure is the *method* (deep multi-lens analysis, then a per-finding accept/decline/fix loop), not the GitHub plumbing. The point is to catch correctness and maintainability defects while they're cheap, on the actual diff, before `/nase:simplify` reshapes it and before the cross-model spec check in Phase 6.5. AI-written diffs carry materially more defects than they appear to (`workspace/kb/general/llm.md` — "confidently incomplete"), so this pass is mandatory, not optional.

**Reviewer is fresh-context, never the implementing context.** Scoring your own diff in the context that wrote it is self-approval — the blind spot that produced a bug scores right past it (`CLAUDE.md → Code Review`; `feedback_ai-code-comprehension-gate.md`). Spawn a read-only subagent (role `verifier` per `.claude/roles.yaml`, tools Read/Grep/Glob/Bash — no Edit/Write). Give it only: the task spec from `$ARGUMENTS` plus any `success_criteria_from_design` / `design_constraints` from Phase 1 (the contract), the merge-base diff, and `{work_root}`. Do not hand it your reasoning or a verdict.

### Review depth — full `discuss-pr` lens set, every run

The reviewer applies the `/nase:discuss-pr` review stance, in order: (1) what problem is this solving, for whom, and why now; (2) does the implementation actually satisfy that intent across every changed path; (3) does the design fit the larger system boundaries, ownership, and adjacent patterns; (4) is there a simpler, more elegant implementation that cuts risk or maintenance; (5) are tests, security, and hygiene sufficient for the risk. Run **all** of these lenses on every run regardless of diff size — problem fit, logic correctness, design/elegance + active simpler-option search, architecture, security, testability, and code-comment accuracy. Judge design and elegance through the principle ordering captured in Phase 3.6 and the design-time decision values (`/nase:design` → *What a technical decision optimizes for*): quality, simplicity, robustness, scalability, elegance, maintainability — not build speed.

For any **non-trivial finding** (a non-obvious correctness claim, a cross-boundary assumption the diff alone can't settle, or a severity upgrade resting on inferred rather than observed behavior), run the `/nase:discuss-pr` doubt cycle: hand a fresh reviewer `ARTIFACT + CONTRACT` only — never your CLAIM — let it judge independently, then reconcile each result as contract-misread / valid / valid-trade-off / noise. This kills plausible-but-wrong findings before they cost a fix. Skip the doubt cycle only for mechanical nits already 100% grounded in the diff.

### Severity rubric

Reuse the existing ladder (`workspace/kb/general/clean-code.md` severity ladder; `CLAUDE.md → Code Review`) — don't invent a parallel scheme. Map to gate tiers:

| Tier | = ladder | What counts | Gate? |
|------|----------|-------------|-------|
| **P0** | blocking | correctness bug, security / tenant-isolation / secret leak, data loss, broken behavior, diff contradicts the spec | **must fix before commit** |
| **P1** | blocking/suggestion | real maintainability or UX defect, a fixed bug with no regression test (Beyoncé rule), code you cannot restate in your own words (comprehension gap), premature abstraction that should be cut | **must fix before commit** |
| **P2** | nit/suggestion | style, naming, polish | record as follow-up; do **not** gate |

Don't over-escalate (`CLAUDE.md`): `P0` needs concrete evidence the code is broken or exploitable, not a preference.

### Structured fix — per finding, `address-comments` discipline

Treat each surviving finding like an unresolved review thread you own:

1. **Dossier + verify.** One line per finding: file:line, the concrete defect, and the evidence (the diff hunk plus any cross-boundary code traced during the doubt cycle). Verify the finding against the actual line per `.claude/docs/pr-review-verification.md` §3 — if the claim doesn't match the file at that line, drop it.
2. **Classify** (don't reflexively patch every comment): **accept** (real defect → fix it), **decline** (current code is already correct, or the finding misread context → record the one-line reason, change nothing), or **middle-ground** (a narrower fix now, or a tracked follow-up for an out-of-scope part). Probe for the middle ground before committing to a binary accept/decline.
3. **Fix accepts.** Apply the minimal change for every accepted P0 and P1 in `{work_root}`. If a fix alters logic or fixes a bug, add or update the test that covers it (Beyoncé rule). P2s become Phase 10 follow-up notes.

### Scope discipline (so the loop converges)

Review the **diff**, not the whole repo. For a *code-quality* finding, grep whether the pattern is **pre-existing** (`workspace/kb/general/workflow.md` § pre-existing-pattern check) - if this change didn't introduce it, log it as a follow-up; don't fix unrelated code smells here (`CLAUDE.md` "while we're at it" rejection). **Exception:** lint errors, test failures, and test flakiness follow `.claude/docs/fsd-implementation-loop.md -> Engineering Excellence Bar`; fix them even when pre-existing. A stray code smell may be deferred, but a red or flaky gate may not.

### Loop

1. Reviewer returns findings (full lens set + doubt cycle on non-trivial ones), each tagged P0/P1/P2 with file:line, the concrete problem, and its classification.
2. Fix **every accepted P0 and P1** in `{work_root}` (respecting scope discipline). Record declines with their one-line reason. P2s become Phase 10 follow-up notes.
3. **Re-spawn a fresh reviewer** on the updated diff. Confirm each prior fix actually landed at HEAD (`feedback_verify-claimed-fix-vs-head.md` — a claimed fix is a hypothesis until diff-confirmed) and that no new P0/P1 appeared.
4. Repeat until a pass returns zero accepted P0/P1, or **3 iterations**. If iteration 3 still has open P0/P1: stop, do **not** commit, present the remaining findings via `AskUserQuestion` (Fix more / Override with reason / Cancel). An honest stop beats pushing a known-broken diff.

Log one line: `self-review: {N} iters, {X} P0/P1 fixed, {Y} declined, {Z} P2 deferred`.

This is correctness/quality review; Phase 6.5 (Codex) is the independent cross-model spec-vs-diff check. They're complementary — keep both.

## Phase 6.5: Pre-Push Verification Gate (Codex, with single-model fallback)

Gate per `.claude/docs/codex-review.md → Prerequisite`. If the Codex MCP is not loaded, skip cleanly past only the Codex invocation.

Do NOT skip this gate: run the single-model fallback below instead. The verification step is mandatory; only the cross-model variant is optional.

If tempted to skip or self-approve, see `.claude/docs/anti-rationalization.md → /nase:fsd`.

**Single-model fallback (Codex unavailable):** spawn one fresh-context read-only subagent (role `verifier` per `.claude/roles.yaml`, tools: Read/Grep/Glob/Bash — no Edit/Write). Give it ONLY:
- the original task spec from `$ARGUMENTS` verbatim (the CONTRACT)
- the verification bundle path (or the merge-base diff) and `{work_root}` (the ARTIFACT)
- the instruction to answer in the exact `VERDICT: PASS | FAIL | NEEDS-HUMAN` shape below

Do NOT include your own assessment, implementation reasoning, or expected verdict. The subagent must judge spec-vs-diff independently, following the same principle as the `discuss-pr` doubt cycle: hand it the artifact and contract, not your conclusion.

Parse its output with the same decision tree as Codex. Log `verify: single-model fallback (Codex unavailable)` and use tag `fallback-verify` instead of `codex-override` for overrides. A fallback PASS is weaker evidence than a cross-model PASS; note that in the Phase 10 report line.

Build the verification bundle per `.claude/docs/codex-verification-bundle.md`:

```bash
BASE=$(git -C {worktree_or_repo} merge-base origin/{default_branch} HEAD)
python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" \
  --base "$BASE" \
  --task "$ARGUMENTS" \
  --output "{nase_workspace}/workspace/tmp/codex-verify-{short_sha}.md"
```

Invoke the Codex MCP with the `verify` mode contract from `.claude/docs/codex-review.md`:

- `cwd` = `{worktree_path}` (or `{repo}` if worktree = No)
- `prompt` = the original task spec from `$ARGUMENTS` verbatim, the bundle path, merge base, changed-file count, and the insufficient-manifest instruction from `.claude/docs/codex-verification-bundle.md`
- `developer-instructions` = the `verify` template verbatim
- `sandbox` = `read-only`

Parse `content`. Expected shape:
```
VERDICT: PASS | FAIL | NEEDS-HUMAN
SPEC ITEMS NOT ADDRESSED: ...
SCOPE CREEP: ...
REASONING: ...
```

**Decision tree:**

- **PASS** → log one line (`Codex verify: PASS`) and proceed to Phase 7. No user prompt.
- **NEEDS-HUMAN** → write the full Codex output next to the bundle as `codex-verify-{short_sha}-result.md`, then present only `VERDICT`, missing context/files, and the top 5 requested follow-ups via `AskUserQuestion`:
  - Q: "Codex flagged ambiguity — proceed to push or revise first?"
  - Options: `Proceed — push anyway` / `Revise — pause for me to look` / `Show me the diff side-by-side first`
  - Honor the user's choice.
- **FAIL** → do NOT push. Write the full Codex output next to the bundle as `codex-verify-{short_sha}-result.md`, then present only `VERDICT`, top 5 failures, and the result path. Ask via `AskUserQuestion`:
  - Q: "Codex says the diff doesn't match the spec. What now?"
  - Options: `Fix it` / `Override — Codex is wrong, push anyway` / `Cancel — abandon this run`
  - On "Fix it": re-enter Phase 3.7 for phase-isolated runs or Phase 4 otherwise, then rerun verifier.
  - On "Override": log reason to daily log with tag `codex-override`.

**Malformed output** (no `VERDICT:` line) → write raw `content` next to the bundle as `codex-verify-{short_sha}-result.md`, treat as `NEEDS-HUMAN`, present a short malformed-output note plus the result path, and ask the user.

If Codex explicitly reports missing context that is available locally, read only those requested files or hunks, update the bundle, and rerun the verifier once. Do not loop beyond one context-completion rerun without asking the user.

Codex reviews the code Claude wrote; do not self-approve in the same active context.

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

Follow `.claude/docs/verification-matrix.md` §1, §2, §3, §5. Skip §4 because fsd is producing the plan. Phase 5 unit tests become the Unit `✅ done` row.

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

**1. Research gate findings** (from Phase 3.5): if `research_gate_findings` is non-empty, write each library/API to the general KB:
- Target: `workspace/kb/general/{technology}.md` (e.g. `azure-service-bus.md`, `signalr.md`) — create if it doesn't exist
- Use standard `### YYYY-MM-DD — {topic}` entry format
- Add `**Tags:** api-contract` and `**Confidence:** medium` (web-sourced, not yet battle-tested in this repo)
- Include: signatures, required params, return types, pitfalls, official doc URL
- If the file is new, register it in `workspace/kb/.domain-map.md` under `## General`

**2. Implementation discoveries**: if implementation revealed new patterns, architectural insights, or hard constraints specific to the target repo, invoke `/nase:kb-update [domain]` with a concise summary.

Team mode: read `workspace/tmp/fsd-research-{branch_slug}.md` if present. Persist
its findings here. Retain it with a claimed worktree, or delete it at the start
of Phase 10 when no worktree was created. Do not defer KB updates to wrap-up.
