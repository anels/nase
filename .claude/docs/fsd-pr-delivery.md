# FSD PR Delivery

This reference owns the `/nase:fsd` phases that only run when `open_pr = true`: the pull request itself, the verification matrix posted on it, and the KB update that follows. Load it at Phase 8; a PR = No run never needs it.

## Contents

- [Phase 8: Pull Request (if PR = Yes)](#phase-8-pull-request-if-pr--yes)
- [Phase 8.5: Verification Matrix](#phase-85-verification-matrix)
- [Phase 8c: KB Update](#phase-8c-kb-update)

## Phase 8: Pull Request (if PR = Yes)

Follow `.claude/docs/pr-creation-pattern.md` (steps 1–4) to discover the PR template, draft the description with `surface=github-pr-body`, align the title with the commit subject, and preserve co-authors (relevant in team mode).

Then apply `.claude/docs/pr-gates-consumption.md` §3 with the Phase 1 `gate_profile`: ensure a required ticket key sits in the documented PR-title position, every required PR-body section exists at its minimum length, and - if the diff crossed a `gate_profile.size` threshold that mandates it - `## How to Review` is filled. Never invent a ticket key; keep the placeholder and flag it if unknown.

If `review_outcome = not-run`, the PR body states it in whichever section carries verification for this repo's template, alongside the deterministic gates that did pass. The reviewer on the PR is the person who most needs to know that nothing independent has looked at it yet, and they are the one reader who cannot find that out from the Phase 10 report.

Every `gh` mutation below is the exact argv passed to `external-write-action.py`; never run a raw mutating `gh` command. The helper enforces the account guard itself (`.claude/docs/external-mutation-policy.md → GitHub auth account guard`), so there is no separate snippet to run and no `gh auth` call to make - those are blocked.

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
leave the PR ready and say so rather than retrying). Never report "draft PR opened" without
having read the flag back.

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
