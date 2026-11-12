# FSD PR Delivery

This reference owns four `/nase:fsd` phases. Phases 8, 8.5 and 8.6 - the pull request itself, the verification matrix posted on it, and the gate that marks it ready - only run when `open_pr = true`. Phase 8c, the KB update, runs on every FSD run, so a PR = No run loads this document for that section alone.

## Contents

- [Phase 8: Pull Request (if PR = Yes)](#phase-8-pull-request-if-pr--yes)
- [Phase 8.5: Verification Matrix](#phase-85-verification-matrix)
- [Phase 8.6: Ready Gate](#phase-86-ready-gate)
- [Phase 8c: KB Update](#phase-8c-kb-update)

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–4) to discover the PR template, draft the description with `surface=github-pr-body`, align the title with the commit subject, and preserve co-authors (relevant in team mode).

Then apply `.claude/docs/pr-gates-consumption.md` §3 with the Phase 1 `gate_profile`: ensure a required ticket key sits in the documented PR-title position, every required PR-body section exists at its minimum length, and - if the diff crossed a `gate_profile.size` threshold that mandates it - `## How to Review` is filled. Never invent a ticket key; keep the placeholder and flag it if unknown.

If `review_outcome = not-run`, the PR body states it in whichever section carries verification for this repo's template, alongside the deterministic gates that did pass. The reviewer on the PR is the person who most needs to know that nothing independent has looked at it yet, and they are the one reader who cannot find that out from the Phase 10 report.

Every `gh` mutation below is the exact argv passed to `external-write-action.py`; never run a raw mutating `gh` command. The helper enforces the account guard itself (`.claude/docs/external-mutation-policy.md → GitHub auth account guard`), so there is no separate snippet to run and no `gh auth` call to make - those are blocked.

Draft the exact PR payload and show it to the user. Gate creation via `AskUserQuestion` immediately before the mutation, unless one of two pre-authorizations applies. Either `pr_preauthorized = true`, because the user chose "create without asking again" in the intake (Q3), or `python3 .claude/scripts/autonomy-policy.py --class pr-create-draft` reports `decision: auto`. In both cases the user already consented, so still show the payload, then prepare and execute it without a question and append the audit entry with `python3 .claude/scripts/daily-log-append.py autonomy "pr-create-draft {repo_owner}/{repo_name} {manifest}"` (add `run pre-authorized` to the entry for the first case). The run-level consent covers only this one draft PR from this run's own branch. It never removes the manifest binding, the account guard or the prose gates, and it does not apply when a Phase 6 blocker or a failed gate stopped the run, because no PR is opened then. The question below is for every other run:

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
# Private 0700 payload dir - see external-mutation-policy.md -> Private payload directory.
PR_BODY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fsd-pr-body-XXXXXXXX")
PR_BODY_FILE="$PR_BODY_DIR/body.md"
trap 'rm -rf "$PR_BODY_DIR"' EXIT
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

**Then read `isDraft` back.** `--draft` is a request, not a state: the REST
creation path drops it,
and repo/org automation can fire `ready_for_review` seconds after creation. Confirm right after
creation, and again after the Phase 8.5 `gh pr edit`. This is deliberately narrower than the
`github-queries.md → PR Metadata` variants: it is a one-flag readback, not a metadata fetch:

```bash
gh pr view {pr_number} --repo {repo_owner}/{repo_name} --json isDraft,url \
  --jq '"isDraft=\(.isDraft)  \(.url)"'
```

If `isDraft` is false, the PR is already published for review. Say so on its own line in the Phase 10
report, and offer to re-draft through a gated `external-write-action.py` manifest for
`gh pr ready --undo` (gh refuses `--undo` on plans that do not support re-drafting; if it does,
leave the PR ready and say so rather than retrying). If the user re-drafts it, Phase 8.6 does not
mark it ready again (`ready_state = draft - re-drafted by user`). Never report "draft PR opened" without
having read the flag back.

---

## Phase 8.5: Verification Matrix

Build a verification matrix so the reviewer knows what to run before approving the PR.

Follow `.claude/docs/verification-matrix.md` §1, §2, §3, §5. Skip §4 because fsd is producing the plan. Phase 6.1 final canonical test evidence becomes the Unit `✅ done` row.

**Execute before rendering:** a matrix fsd only writes is a promise; a matrix fsd partially ran is evidence. Before rendering:
- Attempt every `required` row whose `command` runs locally inside `{work_root}`: local builds, env-var-switched `dotnet run`/`npm start` smoke checks, dry-run commands.
- When `claudeRunSkills.recipes` exists and the change affects runtime behavior, include `/verify` as a required behavioral row and run it before manual smoke rows that duplicate the same coverage.
- Attempt the 🔥 critical row above all when it can run locally.
- Record outcomes as `✅ done` with the actual output as evidence.
- Skip rows needing deployment, external environments, or credentials fsd doesn't hold. Mark those `not run by fsd` explicitly; never fabricate.
- If the 🔥 critical row exists and could not be run locally, say so in the Phase 10 report's Critical line.

Skill-specific outputs:

1. **Append to PR body** only if `open_pr = true` and matrix has rows. Show the exact `## Verification` section. When `pr_preauthorized = true`, the intake consent covers this one `gh pr edit --body-file` of the PR this run created, so run it through its manifest without a question and append the audit entry the same way as in Phase 8. It does not cover any other edit, a label, a reviewer or `gh pr ready`. Otherwise gate `gh pr edit` via `AskUserQuestion`:
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
   # Private 0700 payload dir - see external-mutation-policy.md -> Private payload directory.
   PR_BODY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fsd-pr-body-XXXXXXXX")
   PR_BODY_FILE="$PR_BODY_DIR/body.md"
   trap 'rm -rf "$PR_BODY_DIR"' EXIT
   gh pr view {pr_number} -R {owner}/{repo} --json body --jq .body > "$PR_BODY_FILE"
   # Append the Verification section to the file, then:
   MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
     --system github --summary "append verification to PR {owner}/{repo}#{pr_number}" -- \
     gh pr edit {pr_number} -R {owner}/{repo} --body-file "$PR_BODY_FILE" | jq -r .manifest)
   jq . "$MANIFEST"
   python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
   python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
   ```
   Append only; never overwrite. Skip when matrix has no rows. Record `verification_in_body`: `true` once appended, `false` when the edit was skipped or declined, `n/a` when the matrix has no rows.

2. **Surface in Phase 10 report**: pass critical layer and caveat to final report.

3. **No PR**: render the matrix in Phase 10.

---

## Phase 8.6: Ready Gate

Runs only when `open_pr = true` and Phase 8 returned a `pr_url`. "Ready for review" tells the reviewer that nothing is left for FSD to check, so a PR leaves draft only when FSD verified it end to end. Any other PR stays draft and Phase 10 says why. The gate runs after the Phase 8.5 body edit, so the reviewer opens a PR whose Verification section is already there.

**1. Build the ledger.** Run the Success-Criteria Ledger and `closure_state` derivation from `fsd-closeout.md -> Phase 10` now, after Phase 8.5 produced its evidence. A wave agent already returned `closure_state`; use that value and skip this step.

**2. Test the conditions.** Test Closed, Verified, and Unblocked first, all three even after one fails, so the report names every local blocker. When any of them is unmet, skip the CI check, because it would only add a wait, and report `CI not checked`.

| Condition | Met when |
|---|---|
| Closed | `closure_state = done`. Anything else, including a missing value, is unmet. |
| Verified | No `required` Phase 8.5 row is `not run by fsd`, the 🔥 critical row included, and `verification_in_body` is `true` or `n/a` (a skipped Phase 8.5 edit is unmet). A run with no rows (docs-only change) is met. A PR with a required row that needs a deployment or credentials stays draft by design, so the reviewer runs that row before marking it ready. |
| Unblocked | The PR's `design_pr_plan` row has `Depends on = none` and `External blockers = none`. A run with no plan row is met. |
| CI green | Every check on the PR head passed, required or not, per the CI check below. |

**CI check.** First confirm the PR carries the pushed commit. `gh pr view {pr_number} -R {repo_owner}/{repo_name} --json headRefOid --jq .headRefOid` must equal `git -C {work_root} rev-parse HEAD`; a mismatch is unmet (`head moved`). `git -C {work_root} status --porcelain` must print nothing, because `done` binds the committed tree; otherwise unmet (`worktree changed after review`). Then wait for the checks, as its own Bash call with `timeout: 600000`, no `$(...)`, and no loop. Ignore its exit code, because the read below decides:

```bash
gh pr checks {pr_number} -R {repo_owner}/{repo_name} --watch --fail-fast
```

Then read the final state once, as its own call. A watch that timed out or stopped at the first failure still leaves a state to read:

```bash
gh pr checks {pr_number} -R {repo_owner}/{repo_name} --json bucket --jq '[.[].bucket] | unique | join(",")'
```

Check the buckets in this order:

- `fail` or `cancel` is unmet (`CI failed`).
- `pending` is unmet (`CI still pending`). CI slower than the 10-minute cap ends here, and `/nase:prep-merge` is the way to mark the PR ready once it turns green.
- Only `pass` and `skipping`, with at least one `pass`, is met. Only `skipping` is unmet (`no CI ran`), because a skipped check proves nothing.
- No output (the CLI prints `no checks reported` and exits `1`) means no checks yet. Poll for up to 120 seconds for the first check to appear, with one bounded `until` loop in a single Bash call and no bare foreground `sleep`, which the harness blocks. Then run the watch and the read once more. A second empty read is unmet (`no CI evidence`), since no checks is not green. A repo that skips CI on drafts lands here, and its PR stays draft by design.
- A read the CLI guard blocks is unmet too. Do not work around the guard.

**3. Decide.** Any unmet condition means no mutation: set `ready_state = draft - {every unmet reason}` and stop. A PR already ready at Phase 8 with all four met is `ready_state = ready`; stop. A PR already ready with a condition unmet keeps Phase 8's re-draft offer and gets `ready_state = ready - unverified ({every unmet reason})`; stop. A PR the user re-drafted at Phase 8 stays draft: `ready_state = draft - re-drafted by user`; stop.

**4. Mark ready.** All four are met, so ask the policy with `python3 .claude/scripts/autonomy-policy.py --class pr-mark-ready`. On `auto`, show the manifest below, run it without a question, and append the audit entry with `python3 .claude/scripts/daily-log-append.py autonomy "pr-mark-ready {repo_owner}/{repo_name}#{pr_number} {manifest}"`. On any other value, gate it first:

```
question: "Mark this PR ready for review?"
header: "Ready"
options:
  - label: "Mark ready"
    description: "Run gh pr ready on the PR. Reviewers see it as ready for review."
  - label: "Keep draft"
    description: "Leave the PR as draft; mark it later with /nase:prep-merge or gh pr ready"
```

If kept draft, set `ready_state = draft - kept by user`. Otherwise prepare, show, authorize, and execute this action:

```bash
MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
  --system github --summary "mark PR ready {repo_owner}/{repo_name}#{pr_number}" -- \
  gh pr ready {pr_number} -R {repo_owner}/{repo_name} | jq -r .manifest)
jq . "$MANIFEST"
python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
```

Then read `isDraft` back with the Phase 8 command. `false` means `ready_state = ready`. `true` means `ready_state = draft - gh pr ready did not take effect`; report it and do not retry. Never report a PR as ready without the readback.

---

## Phase 8c: KB Update

Persist before cleanup:

**1. Research gate findings** (from Phase 3.5): if `research_gate_findings` is non-empty, invoke `/nase:learn` for each library/API candidate and apply its verification triad before writing to the general KB. Preserve the existing persistence outcome and include signatures, required params, return types, pitfalls, and the official doc URL, but keep candidates that fail V2 or V3 in the FSD research artifact instead of the active KB. `/nase:learn` owns target resolution, current-state reconciliation, confidence, domain-map registration, and the guarded write.

**2. Implementation discoveries**: if implementation revealed new patterns, architectural insights, or hard constraints specific to the target repo, invoke `/nase:kb-update [domain]` with a concise summary.

Team mode: read `workspace/tmp/fsd-research-{branch_slug}.md` if present. Persist
its findings here. Retain it with a claimed worktree, or delete it at the start
of Phase 10 when no worktree was created. Do not defer KB updates to wrap-up.

---
