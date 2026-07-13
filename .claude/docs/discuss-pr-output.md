# Discuss PR Output

Read this file only when /nase:discuss-pr reaches Step 6. It owns the user-visible review report, optional additional deep dives, draft decision, KB handoff, and daily log. This flow stays read-only.

## Step 6 - Present findings and open discussion

**Mandatory de-duplication filter (apply before presenting):** map each candidate finding against the existing comment set already fetched in Step 2; do not re-fetch. Drop candidates whose `(file, line, claim)` overlaps an existing open or resolved thread from a human or bot reviewer. If every candidate drops out, output `0 inline + 0 top-level` and state that prior reviewers already covered the diff.

**Output discipline:** chat only, no file write. Narrative uses `conversation:`; GitHub drafts/posts use `output:`. Keep paths, lines, symbols, identifiers in English.

Order in chat:
1. Summary line - counts per tier + dropped count
2. Problem framing table with rows: `Problem`, `Larger context`, `Core change`, `Verdict`
3. **Sense Check block** (from Step 2.6) - four-pillar table
4. Risk map - selected specialist list + one-line reason for any skipped optional specialist
5. **Verification block** (from Step 5.5) - recommended bar + PR-description plan status
6. PR Quality Scorecard (table below)
7. Findings grouped by confidence tier (Critical / High / Medium)
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

**Summary line** - one line showing the count per tier and how many were dropped:
```
Found: {N} critical, {N} high, {N} medium ({N} dropped below threshold)
```

**Findings - group by confidence tier**, not just severity category. Within each tier, order by category: bugs → security → architecture → testability → other.

```
### Critical (90-100)
- [95] **Bug** · `path/to/file.ts:42` - description...
- [92] **Security** · `path/to/api.ts:18` - description...

### High (80-89)
- [85] **Architecture** · `path/to/service.ts:100` - description...

### Medium (50-79) - discussion only, no inline drafts
- [62] **Testability** · `path/to/handler.ts:55` - description...
```

For each issue include:
- Confidence score in brackets: `[87]`
- Category tag in bold: `**Bug**`, `**Security**`, `**Architecture**`, `**Testability**`
- File and approximate line (English, paste-ready)
- One-sentence description (in `conversation:` language) with consequence if unfixed
- Evidence source (e.g. "confirmed via code trace through DashboardService.cs:332", "confirmed via Confluence AS tracker", "introduced in {pr_ref}")
- For deep-dived findings: a brief summary of what was traced and what was found (1-2 sentences - enough to show the work, not a full report)

---

Steps 6.5 → 7 → 8 → 9 are the fixed handoff sequence. If preconditions do not apply, say so and move on.

All chat in steps 6.5–8 stays in `conversation:` language. Draft and posted GitHub text stays in `output:` language.

## Step 6.5 - Stage 2: ask about additional deep dives

Collect remaining trace-worthy items:
- Medium-confidence findings (50–79) where more context could move them up or drop them
- Open questions that COULD be answered by code but weren't critical enough to auto-trace
- Cross-file consistency checks the user might want validated

If none, say "No additional deep-dive candidates - auto-dive covered everything." and skip to Step 7.

Otherwise ask via `AskUserQuestion` (`multiSelect: true`, max 4 options):

```
Question: "Anything else worth deep-diving before drafting?"
Header: "Deep dive"
Options (multiSelect):
- "[70] Validate caller assumes X" - Trace MyController.cs to confirm
- "[65] Check downstream consumers of Y" - grep across consuming repos for Y
- "[62] Verify Z is feature-flagged" - check Confluence + flag config
- "Skip - proceed to draft" - no further dives
```

Spawn Explore agents for selected items (same pattern as Step 5b - each spawn prompt carries the inline diff-first directive and the §12 trace-shape self-check). Update findings with evidence. Then proceed to Step 7.

## Step 7 - Stage 3: draft decision

This command is read-only. Ask whether to return draft comments or end without drafts. Never offer posting from this flow.

**Before drafting, run the trace-shape self-check** (`.claude/docs/pr-review-verification.md` §12) on your own main-thread investigation (Steps 4–5d): did it narrow before reading, batch discovery, stay diff-anchored, and recover from failed searches without path-guessing? Downgrade any finding that survived only a widen-first / path-guessing trace to WEAK and re-verify it before including it in the draft.

```
Question: "Draft inline comments now?"
Header: "Draft choice"
Options (single-select):
- "Draft comments (recommended)" - I draft inline comments in chat; nothing is posted
- "No draft" - End the flow here, no comments drafted
```

Behavior per choice:

**Draft comments** -> produce the drafts below in chat. End with: "Drafts above. Post only after an explicit request through the GitHub mutation workflow."

**No draft** -> End with: "No drafts produced. Re-invoke if you want to act on these later."

**Draft format:**

- **Voice profile**: before drafting, follow `.claude/docs/voice-profile-routing.md` with `surface=github-review-comment`; read `workspace/communication-style.md` for high-stakes or ambiguous comments. Keep no-blame phrasing, soft prefix when disagreeing with senior reviewers (`"Thanks for the suggestions. I agree with them. 😊 However, ..."`), and no AI-flavor fillers. Also honor `CLAUDE.md → Code Review` - don't over-escalate severity, prefer measured assessments.
- **1–2 sentences max** - state the point directly, no preamble or verbose explanation
- Conversational peer tone - not formal or gatekeeper
- Lead with the specific concern
- Include the fix direction only if unambiguous
- For findings that went through `pr-review-verification.md` §7 (citation/triage verification of a bot claim): append one short line with the verification command + result (e.g. `shellcheck exited 0 on this file`) so the author can audit instead of re-litigating
- **Language:** `output:` value from `workspace/config.md` (drafts are paste-ready for GitHub)

```
**File:** `path/to/file.ts` line <N>
<comment text>
```

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

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `review`). Runs at the end of every invocation, including a "No draft" exit.

Log: `{repo}#{number} - {N} files, {N} issues ({categories}); key: {1-line summary}`
