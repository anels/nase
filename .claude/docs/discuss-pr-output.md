# Discuss PR Output

## Contents

- Step 6 - Present findings and open discussion
- Sense Check
- Step 6.5 - Stage 2: automatic additional deep dives
- Step 7 - Stage 3: draft decision
- Step 8 - Stage 4: submit the review (gated write)
- Step 9 - Stage 5: completion message
- Error Handling
- Ongoing - KB update (on confirmed findings)
- Notes
- Final - Daily Log

Read this file only when /nase:discuss-pr reaches Step 6. It owns the user-visible review report, automatic additional deep dives, draft decision, gated review submission, completion message, KB handoff, and daily log. Steps 6-6.5 are investigation-only; all external writes go through the `external-write-action.py` manifest gate per the command's standing invariants.

## Step 6 - Present findings and open discussion

**Mandatory de-duplication filter (apply before presenting):** map each candidate finding against the existing comment set already fetched in Step 2; do not re-fetch. Drop candidates whose `(file, line, claim)` overlaps an existing open or resolved thread from a human or bot reviewer. If every candidate drops out, output `0 inline + 0 top-level` and state that prior reviewers already covered the diff.

**Output discipline:** chat only, no file write. Narrative uses `conversation:`; GitHub drafts/posts use `output:`. Keep paths, lines, symbols, identifiers in English.

Order in chat:
1. Summary line - counts per severity/disposition + dropped count
2. Problem framing table with rows: `Problem`, `Larger context`, `Core change`, `Verdict`
3. **Sense Check block** (from Step 2.6) - four-pillar table
4. Risk map - selected specialist list + one-line reason for any skipped optional specialist
5. **Verification block** (from Step 5.5) - recommended bar + PR-description plan status
6. PR Quality Scorecard (table below)
7. Findings grouped by severity/disposition; confidence remains a separate evidence score
8. Triage classifications from Step 3 - if any unresolved comments existed
9. Inline open questions - one bullet each for domain inputs code tracing cannot answer.

### Sense Check block

Render after Problem framing, before Risk map. Always present even when every pillar passes - this is the explicit "did you actually check the four things" surface.

```
## Sense Check
| Pillar | Status | Evidence |
|---|---|---|
| Scope vs Jira/description | ✅/⚠️/❌ | IN-#### AC fully covered by diff; or PR body claim {X} matches files {a,b,c}; or Jira fetch skipped: MCP unreachable |
| Rationale | ✅/⚠️ | why-now traceable to {trigger}; alternative {A} considered, rejected because {reason} |
| Out-of-scope | ✅/⚠️ | diff confined to {N} files in scope; or drive-by edit at {file:line} |
| Tests | ✅/⚠️/❌ | plan present + L1/L2 covered; or gap at {layer} |
```

Status symbols - narrative around them goes in `conversation:` language; pillar names, file paths, IN-#### keys, layer labels stay English.

### Verification block

Render after summary, before scorecard. Shape follows `verification-matrix.md §5`.

If §2 produced no rows (pure docs / comments-only change), omit the entire block.

### PR Quality Scorecard

Rate each dimension 1-5 from diff/tests/PR description. One phrase per row; average rounded.

| Dimension | Score | Justification |
|------|------|------|
| Problem fit | N/5 | clarity of intent and whether the implementation solves it |
| Logic | N/5 | correctness of branches, state, contracts, and edge cases |
| Design | N/5 | simplicity, local patterns, abstraction quality, maintainability |
| Code quality | N/5 | naming, conventions, cleanliness |
| Tests | N/5 | coverage, case quality, edge cases; recommended verification bar met (see Step 5.5); PR-description test plan present |
| Security | N/5 | input validation, auth, no leaked secrets |
| PR hygiene | N/5 | description clarity, size, commit quality |
| **Overall** | **N/5** | **one-sentence verdict** |

Score guide: 5 exemplary, 4 solid, 3 adequate, 2 needs work, 1 significant gaps. N/A dimensions excluded.

**Do not blend spec-fit into a code-quality average.** A failing **Problem fit** (implements the wrong thing / doesn't solve the stated problem) is not offset by high Logic/Design/Code-quality - a PR can be clean *and* wrong (adapted from `mattpocock/skills → code-review` two-axis "never pick a cross-axis winner"). The **Overall** verdict must state a low Problem-fit explicitly rather than averaging it away; when spec-fit and code-quality diverge, name both in the one-sentence verdict.

**Internal only - never post this scorecard to GitHub.**

---

**Summary line** - one line showing severity/disposition counts and how many were dropped:
```
Found: {N} critical, {N} high, {N} medium, {N} low; {N} blocking, {N} non-blocking, {N} needs-answer ({N} dropped)
```

**Findings - group by severity/disposition.** Confidence is displayed separately and never determines the group. Within a severity group, order by category: bugs → security → architecture → testability → other. Put optional comments in their own section so a confidence-95 nit never appears as Critical.

```
### Critical
- [confidence 95] **Bug** · `issue (blocking)` · `path/to/file.ts:42` - description...

### High
- [confidence 85] **Security** · `issue (blocking)` · `path/to/api.ts:18` - description...

### Medium / Low
- [confidence 87] **Architecture** · `issue (non-blocking)` · `path/to/service.ts:100` - description...

### Needs answer
- [confidence 72] **Question** · `question (needs-answer)` · `path/to/handler.ts:55` - description...

### Suggestions and nits (non-blocking)
- [confidence 94] **Nit** · `nit (non-blocking)` · `path/to/model.ts:12` - description...
```

For each candidate include:
- Confidence score as evidence certainty: `[confidence 87]`
- Severity, kind, and disposition from the private outgoing-comment record
- Category tag in bold: `**Bug**`, `**Security**`, `**Architecture**`, `**Testability**`
- File and approximate line (English, paste-ready)
- One-sentence description (in `conversation:` language) with consequence if unfixed
- Evidence source (e.g. "confirmed via code trace through DashboardService.cs:332", "confirmed via Confluence AS tracker", "introduced in {pr_ref}")
- For deep-dived findings: a brief summary of what was traced and what was found (1-2 sentences - enough to show the work, not a full report)
- For `nit (non-blocking)`: safe, concise summaries of PR introduction, project authority or concrete benefit, and the formatter/linter check.
- For `issue (blocking)`: safe, concise `Concrete failure:` and `Why merge must wait:` summaries. Keep the rest of the private record private.

---

Steps 6.5 → 7 → 8 → 9 are the fixed handoff sequence. If preconditions do not apply, say so and move on.

All chat in steps 6.5–8 stays in `conversation:` language. Draft and posted GitHub text stays in `output:` language.

## Step 6.5 - Stage 2: automatic additional deep dives

Deep diving is automatic - do not ask the user whether to trace. Step 5 already auto-traced the findings whose confidence depends on behavior outside the diff; this step sweeps up the remaining trace-worthy items and resolves them before drafting so the review lands with evidence, not open guesses.

Collect remaining trace-worthy items:
- Confidence 50-79 candidates where more context could confirm or drop them
- `needs-answer` questions that code, tests, config, history, or available docs may still answer
- Open questions that COULD be answered by code but weren't critical enough to auto-trace
- Cross-file consistency checks worth validating

If none, say "No additional deep-dive candidates - auto-dive covered everything." and proceed to Step 7.

Otherwise auto-run the traces - no `AskUserQuestion`. Rank the candidates by how much a trace could move the verdict and spawn Explore agents for the top items in parallel (cap at 4 to bound cost; if more remain, note the ones you deferred and why). Use the same pattern as Step 5b: each spawn prompt carries the inline diff-first directive and the §12 trace-shape self-check. Update findings with the evidence returned, then proceed to Step 7.

## Step 7 - Stage 3: draft decision

Ask the user how to handle drafting via `AskUserQuestion`. Three options, always in this order, always with these labels. **Default recommendation is "Draft + post"** - the normal outcome of a review is inline comments submitted on GitHub, so lead with it and append `(recommended)`. The other two options stay available for a chat-only draft or nothing at all; the recommendation does not skip the confirmation - the user still actively picks, and Step 8 still asks for the review state before any write.

**Before drafting, run the trace-shape self-check** (`.claude/docs/pr-review-verification.md` §12) on your own main-thread investigation (Steps 4–5d): did it narrow before reading, batch discovery, stay diff-anchored, and recover from failed searches without path-guessing? Downgrade any finding that survived only a widen-first / path-guessing trace to WEAK and re-verify it before including it in the draft.

Then enforce the outgoing-comment research gate from Step 4c. Every draft must have a complete private record, a current diff coordinate, and a `Publish decision: draft`. Drop candidates with missing evidence, unresolved coordinates, duplicate root causes, sensitive evidence that cannot be safely summarized, or a kind-specific gate failure.

```
Question: "Draft inline comments now?"
Header: "Draft choice"
Options (single-select):
- "Draft + post (recommended)" - I draft inline comments and proceed to Step 8 to submit the review after you pick the state
- "Draft + discuss" - I draft inline comments inline in chat; you copy/refine manually, nothing is posted
- "No draft" - End the flow here, no comments drafted
```

Behavior per choice:

**Draft + post** -> produce the drafts (format below), then **immediately enter Step 8** without re-asking the draft question. Mention in the handoff line: "Drafts ready - moving to review-state selection."

**Draft + discuss** -> produce the drafts (format below) inline in chat. End the flow with: "Drafts above. Paste or refine manually. To submit via this skill, re-invoke and pick 'Draft + post'." Do NOT enter Step 8.

**No draft** -> End with: "No drafts produced. Re-invoke if you want to act on these later." Do NOT proceed.

**Draft format** (used by Draft + post and Draft + discuss):

- **Voice profile**: before drafting, follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-comment`; read `workspace/communication-style.md` for high-stakes or ambiguous comments. Keep no-blame phrasing, soft prefix when disagreeing with senior reviewers (`"Thanks for the suggestions. I agree with them. 😊 However, ..."`), and no AI-flavor fillers. Also honor `CLAUDE.md → Code Review` - don't over-escalate severity, prefer measured assessments.
- **1–2 sentences max** - state the point directly, no preamble or verbose explanation
- Conversational peer tone - not formal or gatekeeper
- Lead with the specific concern
- Include the fix direction only if unambiguous
- Prefix every comment with exactly one intent label: `issue (blocking):`, `issue (non-blocking):`, `suggestion (non-blocking):`, `nit (non-blocking):`, `question (non-blocking):`, or `question (needs-answer):`
- `nit` is always non-blocking. Cluster repeated instances into one representative comment and mention sibling occurrences briefly.
- Keep the private record private. Include only the minimum safe evidence needed for the author; never include secrets, credentials, unredacted scanner matches, private document excerpts, or unnecessary internal URLs.
- For findings that went through `pr-review-verification.md` §7 (citation/triage verification of a bot claim): append one short line with the verification command + result (e.g. `shellcheck exited 0 on this file`) so the author can audit instead of re-litigating
- **Language:** `output:` value from `workspace/config.md` (drafts are paste-ready for GitHub)

```
**File:** `path/to/file.ts` line <N>
<comment text>
```

## Step 8 - Stage 4: submit the review (gated write)

Enter this step only when Step 7 = "Draft + post". Otherwise skip it.

**Ownership check:** compare `gh api user --jq .login` against the PR `user.login`.

- If the PR is not the user's, submitting a review notifies the author - confirm once more before proceeding ("PR is owned by @other-user - submitting a review will notify them. Proceed?").
- If the PR is self-authored, GitHub does not allow the author to approve it. Never recommend or submit `APPROVE`; publish only as `COMMENT`, or keep the result in `Draft + discuss`. State the hypothetical merge verdict in chat instead of trying to encode it as an approval. Source: [GitHub required-review documentation](https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/approving-a-pull-request-with-required-reviews).

**Determine the recommended state** for a non-owned PR mechanically:

| Condition | Recommended state |
|---|---|
| No blocking issue and no `needs-answer`; non-blocking issues, suggestions, or nits may remain | `APPROVE` |
| A material `question (needs-answer)` prevents an approval verdict, but no must-not-merge issue is confirmed | `COMMENT` |
| At least one confirmed `issue (blocking)` has a `must_not_merge_reason` and no safe defer | `REQUEST_CHANGES` |

`APPROVE` remains the default when the PR is mergeable, including LGTM-with-nits. Required-check failures alone do not create an inline comment or change the review state; branch protection owns that gate unless the failure exposes a separate validated code defect.

`REQUEST_CHANGES` is exceptional. It requires a PR-introduced issue with confidence ≥ 80, a concrete failure or binding-policy violation, no safe follow-up path, and an explicit must-not-merge reason. It is not limited to already-observed production incidents: confirmed acceptance-criteria failure, compile/build break, security/privacy/data-integrity violation, public-contract break, or unsafe deploy/migration/rollback may qualify. Missing tests alone do not.

Ask via `AskUserQuestion`, recommended option first with `(recommended)` appended. Build the options from eligible states only:

```
Question: "Submit review as which state? (recommended: <STATE>)"
Header: "Review state"
Eligible options (single-select):
- "APPROVE" - include only when there is no blocking issue and no `needs-answer`
- "COMMENT" - include only when there is no blocking issue
- "REQUEST_CHANGES" - include only when a confirmed `issue (blocking)` has a `must_not_merge_reason` and no safe defer
```

For a non-owned PR with a confirmed blocking issue, `REQUEST_CHANGES` is the only submission state. The user may instead return to Step 7 and choose `Draft + discuss` or `No draft`. For a self-authored PR, omit `APPROVE` and `REQUEST_CHANGES`; submit as `COMMENT` only.

**Submit sequence** once the user picks - one payload-bound `external-write-action.py` manifest for the whole review (a GitHub review with inline comments and a state is a single POST). Never run a raw `gh api` mutation.

- Recompute state eligibility from the confirmed findings immediately before manifest creation. If the selected state is no longer eligible, do not build or authorize a manifest; return to review-state selection with the changed evidence.
- Body: for `APPROVE`, "LGTM" or "LGTM with nits" - never repeat the fix mechanism or re-summarize the PR. For `COMMENT`, name the unresolved question, missing domain evidence, or self-review verdict without calling it blocking. For `REQUEST_CHANGES`, name the confirmed must-not-merge concern in one or two sentences.
- Inline comments: same 1–2 sentence rule as the drafts, `output:` language, voice profile per `.claude/docs/voice-profile-routing.md` with `surface=github-review-comment`. Each needs `path` and `line` (or `start_line`+`line` for a range); use `side: "RIGHT"` for the PR head.
- Build the review payload as a private file, prepare the manifest, show it, get the immediate `AskUserQuestion` approval of that exact manifest, then authorize and execute:

```bash
REVIEW_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-{number}.XXXXXXXX.json")
chmod 600 "$REVIEW_FILE"
trap 'rm -f "$REVIEW_FILE"' EXIT
# Build with jq from the confirmed state, body, and drafted inline comments:
#   {"event":"APPROVE|COMMENT|REQUEST_CHANGES","body":"...","comments":[{"path":"...","line":N,"side":"RIGHT","body":"..."}]}
jq -n --arg event "$STATE" --arg body "$REVIEW_BODY" --argjson comments "$INLINE_COMMENTS_JSON" \
  '{event:$event, body:$body, comments:$comments}' > "$REVIEW_FILE"
MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
  --system github --summary "submit {STATE} review on {owner}/{repo}#{number}" -- \
  gh api "repos/{owner}/{repo}/pulls/{number}/reviews" --method POST --input "$REVIEW_FILE" | jq -r .manifest)
jq . "$MANIFEST"
# AskUserQuestion approved this exact manifest. Then:
python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
```

- After the review submits, post any Step 3 batched reactions/replies the user agreed to. Each reaction/reply/resolve is its own `external-write-action.py` manifest with its own one-shot token - follow `.claude/docs/github-queries.md -> Resolve Review Threads` for the reply/resolve shapes; reply through the REST endpoint with the integer `databaseId`. Reactions use `gh api "repos/{owner}/{repo}/pulls/comments/{comment_id}/reactions" --method POST --raw-field content="+1"` wrapped in the same manifest gate. Honor the 30-mutation throttle rule in that doc.

## Step 9 - Stage 5: completion message

Reached only after Step 8 submits successfully. Emit a single chat block (labels in `conversation:` language, URL and counts English):

```
✅ Submitted.

- Review: <full review URL, e.g. https://github.com/owner/repo/pull/N#pullrequestreview-XXXXXX>
- State: <APPROVE | COMMENT | REQUEST_CHANGES>
- Inline comments: <N>
- Reactions: <N>  (omit line if 0)
- Replies: <N>    (omit line if 0)
- Daily log: <appended | skipped>
```

Get the review URL from the execute response (`html_url`, or build `https://github.com/<owner>/<repo>/pull/<N>#pullrequestreview-<id>` from the returned `id`). If a write partially failed (review submitted but a reaction failed), use ⚠️ instead of ✅ and list the failures explicitly.

## Error Handling

- **Auth failure** (`gh` not authenticated or 403): report the error and stop - do not retry or guess credentials.
- **Oversized diff** (>5000 lines based on `additions + deletions` from PR metadata): skip `gh pr diff` and use `gh pr diff --stat` instead. Read only the top N most-changed files individually. Note in the output which files were skipped.
- **Private repo / 404**: verify the repo exists and the user has access. Suggest `gh auth status` if unclear.
- **Rate limit (HTTP 429)**: wait and retry once. If still limited, report and stop.

## Ongoing - KB update (on confirmed findings)

During any discussion - whether from your own analysis or from engaging with existing comments - watch for moments where something is **confirmed and non-obvious**:
- Author clarifies an intentional design decision that isn't obvious from the code
- A pattern is confirmed as the team's convention (e.g. "we always separate these types for call-site safety")
- A bug is confirmed to exist or not to exist with a concrete reason

When this happens, immediately offer: _"This seems worth capturing in the KB - want me to run `/nase:kb-update`?"_

If the user agrees (or proactively says "add this to KB"), run `/nase:kb-update [domain]` with a concise summary of what was learned. Don't wait until the end of the session.

## Notes

- Always confirm feature flag scope issues against product docs (Confluence) before flagging - what looks like a missing path may be intentionally out of scope
- Git history agent is often the most valuable - prior PR comments on the same files frequently repeat
- Skip your own findings for anything already raised in existing comments
- Next-step hint at end of flow: if the PR is the user's own, suggest `/nase:address-comments <PR-URL>`. If the PR is someone else's, drop that suggestion entirely or suggest `/nase:request-review` if drafts went out. Never blanket-suggest `/nase:address-comments` on PRs the user does not own.

## Final - Daily Log

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `review`). Runs at the end of every invocation regardless of whether a review was submitted, so a "No draft" or "Draft + discuss" exit still gets a one-line entry. When Step 8 submitted a review, its `Daily log:` field reports the actual outcome (`appended` / `skipped`) and the log line names the state.

Log: `{repo}#{number} - {N} files, {N} issues ({categories})[, review: {STATE}]; key: {1-line summary}`
