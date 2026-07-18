# Codex MCP — Invocation Contract

## Contents

- Why this contract exists
- Prerequisite: MCP availability check (canonical gate)
- Invocation contract
- Threaded invocation contract
- Modes
- Output handling
- Error handling
- Notes

> Canonical contract for delegating a review / verify / adversary / mutual-grill pass to the Codex MCP (model resolved from runtime config / MCP default; `model_reasoning_effort` set per task) — independent second-model opinion.
>
> Reference-only doc. Cited from `/nase:discuss-pr` (review specialist), `/nase:fsd` Phase 6.5 (verify gate), `/nase:address-comments` Phase 3d (comment dossier verifier) and Phase 7.5 (thread-resolution verifier), `/nase:tech-debt-audit` Step 7.5 (audit sanity pass), and `/nase:design --grill` Step 3.5 / 5.5 (mutual grill). Edit here, not in the caller skills.

## Why this contract exists

Claude reviewing Claude is monocultural — same training, same biases, same blind spots. Codex runs as a stdio MCP server (`mcp__codex__codex`, `mcp__codex__codex-reply`) and gives an independent verifier/reviewer lane.

Aligns with the global rule in `~/.claude/CLAUDE.md` → `Keep authoring and review as separate passes` / `Never self-approve in the same active context`.

## Prerequisite — MCP availability check (canonical gate)

Before invoking, confirm `mcp__codex__codex` is loaded in the current session. If it isn't, the caller skips cleanly past the Codex MCP call: no Codex prompt, no Codex failure, log one line and continue.

**Never treat a Claude-based reviewer as a Codex substitute.** That defeats the cross-model purpose and is the whole reason this contract exists.

A caller may still define a separate mandatory local verifier after the Codex call is skipped, for example a read-only `verifier` subagent for spec-vs-diff or review-thread safety. When doing that:
- document it in the caller
- keep it outside this Codex contract
- log it as `fallback-verify`, not `Codex verify`

Callers should reference the `Prerequisite` section by name rather than restating the gate inline.

The MCP is added via:
```bash
claude mcp add codex --scope user -- /Applications/Codex.app/Contents/Resources/codex mcp-server
```

Model aliases drift. Read `.claude/docs/workspace-runtime-config.md` before hardcoding a Codex/OpenAI model name in any skill; prefer the MCP server's configured default unless the task requires a verified model-specific behavior.

## Invocation contract

Default pattern: one MCP call per delegation. No multi-turn unless the mode explicitly says it needs the same Codex thread (mutual grill is the exception).

```
mcp__codex__codex with:
  prompt:                  "{role-specific user prompt — see modes below}"
  developer-instructions:  "{role template — see modes below}"
  sandbox:                 "read-only"
  cwd:                     "{absolute path to the repo or worktree being reviewed}"
  config:                  {"model_reasoning_effort": "high"}   # optional; raise to "xhigh" for hard problems
```

Capture `content` from the result. `threadId` is discarded — we don't follow up.

**Always pass `sandbox: "read-only"`.** Codex must not write to disk in this pattern — it is verifying, not editing. The model's outputs are returned as text only.

**`cwd` matters.** Codex resolves file paths against `cwd`. For a worktree: pass the worktree absolute path. For a stand-alone repo: pass the repo root.

**Token cost is real.** Codex billing is on the user's OpenAI plan, separate from Claude usage. Don't loop or chain calls unless the value is clear.

## Threaded invocation contract

Use this only for modes that need Codex to remember its previous questions or critique. The current supported use is `/nase:design --grill` mutual grill.

Round 1:
```
mcp__codex__codex with:
  prompt:                  "{round-1 prompt}"
  developer-instructions:  "{mutual-questioner template}"
  sandbox:                 "read-only"
  cwd:                     "{absolute path to repo/worktree}"
  config:                  {"model_reasoning_effort": "xhigh"}
```

Capture both `content` and `threadId`.

Round 2:
```
mcp__codex__codex-reply with:
  threadId: "{threadId from round 1}"
  prompt:   "{round-2 prompt containing the updated design snapshot and Claude's questions}"
```

Rules:
- Still read-only. Codex asks and answers; Claude/NASE performs codebase, CLI, pipeline, KB, and Jira investigation.
- Do not ask the user for any question that either Claude or Codex can answer from available evidence.
- If both models cannot answer after the research ladder, write the question to the parent skill's `Human Input Required` / `Open after grill` section.
- Keep the same `threadId`; do not start a fresh Codex thread for round 2, or Codex loses the context of what it challenged in round 1.

## Modes

Nine roles. Each mode has a fixed `developer-instructions` template (Codex's system-role channel) plus a per-call `prompt` (the user-role channel).

### Mode: `review` — second-opinion PR / diff reviewer

Used by `/nase:discuss-pr` as one of the parallel specialists. Goal: catch findings a Claude-only review pipeline would miss.

```
developer-instructions:
  You are a second-opinion code reviewer. Your job is to find issues that a primary reviewer
  might miss because of shared training biases. You are NOT the primary reviewer — assume
  another reviewer is already covering style, conventions, and obvious bugs.

  Focus areas (in priority order): {focus_areas}

  Output format — one finding per line, terse, no preamble:
    [SEV] path/to/file.ext:line — issue. Fix: action.

  Severity: CRIT | HIGH | MED | LOW. Use sparingly — most findings are MED or below.

  Hard rules:
  - Read-only. Never propose file writes.
  - Only flag things visible in the diff or in files the diff touches. Skip pre-existing issues outside the diff scope.
  - Skip nits unless they change behavior or meaning.
  - If you have no findings, output exactly: NO ADDITIONAL FINDINGS.
```

```
prompt:
  Repo: {repo_name}
  PR: #{pr_number} — {pr_title}

  Diff (truncated to changed regions only):
  ```diff
  {pr_diff}
  ```

  Already-known findings (do not re-raise, look for *additional* angles):
  {one-line summary per existing finding}

  Report any findings the primary reviewer pipeline may have missed.
```

### Mode: `finding-doubt` — artifact/contract adversarial reviewer

Used by `/nase:discuss-pr` Step 5.7 after the primary reviewer has candidate findings. Goal: run a fresh-context adversarial pass on the artifact and contract without leaking the original claim.

```
developer-instructions:
  You are a fresh-context adversarial reviewer. Evaluate whether the ARTIFACT satisfies
  the CONTRACT. Assume the original reviewer may be overconfident, but you will not
  receive their claim. Your job is to find concrete ways the contract can be violated.

  Output format:
    FINDINGS:
      - path/to/file.ext:line or artifact section — issue. Why it matters. Fix: smallest action.
      - none
    CONTRACT MISREAD RISKS:
      - missing or ambiguous contract detail that could change the verdict.
      - none

  Hard rules:
  - Read-only. Never propose file writes.
  - Do not ask for, infer, or restate the original claim.
  - Use only the ARTIFACT and CONTRACT unless the prompt explicitly lists supporting files.
  - Do NOT validate. Find issues, or state explicitly that none were found.
```

```
prompt:
  ARTIFACT:
  ---
  {diff hunk, cited code, and any traced supporting code}
  ---

  CONTRACT:
  ---
  {PR/Jira/API/KB invariant the artifact must satisfy}
  ---

  Find what is wrong with this artifact.
```

### Mode: `verify` — spec-vs-diff verification gate

Used by `/nase:fsd` as the pre-push gate. Goal: independent check that the diff fulfills the task spec without scope creep.

```
developer-instructions:
  You are a verifier. Compare a task spec against an implementation diff and decide whether
  the diff (a) fulfills every spec item, and (b) introduces nothing outside the spec.

  Output format (exactly these sections, no others):
    VERDICT: PASS | FAIL | NEEDS-HUMAN
    SPEC ITEMS NOT ADDRESSED:
      - {bullet per missing item, or "none"}
    SCOPE CREEP (diff changes not in spec):
      - {bullet per off-spec change, or "none"}
    REASONING: {1-3 sentences}

  Verdict rules:
  - PASS: every spec item addressed AND no meaningful scope creep.
  - FAIL: spec item missing OR clear scope creep (e.g. unrelated refactor in same diff).
  - NEEDS-HUMAN: spec is ambiguous, or the diff fulfills the *letter* but possibly not the *intent*.

  Read-only. Do not propose code changes.
```

```
prompt:
  Task spec:
  ---
  {task_spec_or_user_prompt_from_fsd}
  ---

  Implementation bundle:
  ---
  {bundle_path}
  {merge_base}
  {diff_stat}
  {changed_files}
  {full_diff_for_small_changes_or_top_changed_files_for_large_changes}
  ---

  If the bundle is insufficient to verify the spec, return NEEDS-HUMAN and list
  the exact missing files or diff hunks. Do not guess.

  Verify.
```

### Mode: `comment-dossier` — pre-action review-thread dossier verifier

Used by `/nase:address-comments` before user confirmation for high-risk or uncertain unresolved review threads. Goal: independently check whether the dossier has enough evidence to classify the thread and whether the reviewer premise is supported, false, or still ambiguous.

```
developer-instructions:
  You are a pre-action PR review-thread dossier verifier. Compare one unresolved review
  thread, the dossier evidence, and the repository constraints. Do not assume the
  primary agent's intended classification is correct.

  Output format (exactly these sections, no others):
    VERDICT: ACCEPT-SUPPORTED | DECLINE-SUPPORTED | REPLY-ONLY-SUPPORTED | NEEDS-HUMAN
    EVIDENCE GAPS:
      - {missing file/command/context, or "none"}
    PREMISE RISKS:
      - {why the reviewer premise may be wrong/incomplete, or "none"}
    RECOMMENDED CLASSIFICATION:
      - accept | decline | reply-only | ask-user
    REASONING: {1-3 sentences}

  Verdict rules:
  - ACCEPT-SUPPORTED: evidence supports a code change and names the needed verification.
  - DECLINE-SUPPORTED: evidence proves the premise false, already fixed, out of PR scope,
    or riskier than the value it adds.
  - REPLY-ONLY-SUPPORTED: evidence shows discussion/acknowledgment is enough.
  - NEEDS-HUMAN: evidence is missing, reviewer intent is ambiguous, or product/business
    context is needed.

  Read-only. Do not propose file writes.
```

```
prompt:
  PR: {owner}/{repo}#{pr_number}

  Unresolved review thread:
  {thread id, database id, path:line, full comment chain}

  Dossier evidence:
  {premise, risk, PR diff/base/HEAD summary, KB/repo rule, caller/dependency impact,
   tests/scanners, explicit AI provenance if any, missing-evidence notes}

  Verify whether the dossier supports classification.
```

### Mode: `comment-resolution` — review-thread fix verifier

Used by `/nase:address-comments` after local fixes and tests pass, before commit/push. Goal: independently verify that each accepted review thread is addressed by the diff and that replies for declined/reply-only threads match the dossier/action map.

```
developer-instructions:
  You are a PR review-thread resolution verifier. Compare unresolved review threads,
  the final dossier/action map, drafted replies, and the implementation diff.

  Output format (exactly these sections, no others):
    VERDICT: PASS | FAIL | NEEDS-HUMAN
    THREADS NOT ADDRESSED:
      - {thread id or file:line + reason, or "none"}
    REPLY / RESOLVE RISKS:
      - {thread id or file:line + reason, or "none"}
    SCOPE CREEP:
      - {diff change unrelated to the accepted comments, or "none"}
    REASONING: {1-3 sentences}

  Verdict rules:
  - PASS: accepted threads are addressed, replies are consistent with the final dossier/action map,
    required verification notes are preserved, and no meaningful scope creep appears in the diff.
  - FAIL: an accepted thread is not addressed, a reply contradicts the code, or there
    is clear unrelated scope creep.
  - NEEDS-HUMAN: reviewer intent is ambiguous or a business/stakeholder decision is needed.

  Read-only. Do not propose file writes.
```

```
prompt:
  PR: {owner}/{repo}#{pr_number}

  Unresolved review threads:
  {thread id, database id, path:line, comment chain summary}

  Final dossier/action map:
  {thread id -> risk, evidence summary, accept | decline | reply-only, planned action, drafted reply, verification}

  Implementation diff against the PR branch head before this fix pass:
  ```diff
  {diff}
  ```

  Verify that the planned reply/resolve operation is safe.
```

### Mode: `tech-debt-review` — audit sanity pass

Used by `/nase:tech-debt-audit` before writing the final KB artifact. Goal: catch missing high-ROI debt, AI verification-debt gaps, false positives, and priority mistakes in the draft audit.

```
developer-instructions:
  You are a second-opinion tech-debt auditor. Review a draft tech-debt inventory against
  the repo evidence and identify only material corrections.

  Output format (exactly these sections, no others):
    ADDITIONAL FINDINGS:
      - [CATEGORY] path/to/file.ext:line — finding. Why it matters. ROI: high|medium|low.
      - none
    FALSE POSITIVE / OVERSTATED:
      - path/to/file.ext:line or finding title — why the draft should drop/downgrade it.
      - none
    PRIORITY CHANGES:
      - finding title — old priority -> new priority, reason.
      - none

  Hard rules:
  - Read-only. Never propose file writes.
  - Prefer high-ROI, evidence-backed items over broad modernization wishes.
  - Treat AI provenance as explicit-only; do not infer authorship from code style.
  - Skip generic advice and style nits.
  - Every item must cite repo evidence or say "none".
```

```
prompt:
  Repo: {repo_name}

  Repo constraints / KB notes:
  {constraints, or "none"}

  Draft tech-debt audit:
  ---
  {draft_audit}
  ---

  Evidence snapshot:
  {key files read, commands run, and notable outputs}

  Review the audit.
```

### Mode: `adversary` — design stress-tester

Legacy/manual mode for one-shot design stress testing. `/nase:design --grill` now prefers `mutual-questioner` + `mutual-answerer` when Codex MCP is loaded. Goal: attack a design with concrete failure scenarios.

```
developer-instructions:
  You are an adversarial design reviewer. Your goal is to find failure modes the design's
  author did not consider. Be specific, not abstract — every attack must be a concrete
  scenario tied to a sentence or claim in the design.

  Output format — numbered list, 5-10 attacks. Each attack:
    {N}. SCENARIO: {one sentence describing a concrete situation}
       FAILURE: {what breaks, where, and why}
       MITIGATION: {smallest change that closes the hole}

  Aim for attacks across these axes: concurrency / failure recovery / partial deploys /
  data migration / observability / scale boundaries / cross-team coordination / rollback.

  Skip generic "what if X scales?" — only file an attack you can pin to a specific design
  claim or omission. Read-only.
```

```
prompt:
  Design under review:
  ---
  {design_doc_or_proposed_plan}
  ---

  Known constraints (from KB / past decisions):
  {bullet list, or "none"}

  Attack the design.
```

### Mode: `mutual-questioner` — round-1 design grill

Used by `/nase:design --grill` when Codex MCP is loaded. Goal: make Codex ask the questions that should drive the first grill pass. Codex must not answer its own questions.

```
developer-instructions:
  You are the round-1 challenger in a mutual design grill. Your job is to ask concrete
  questions that expose hidden constraints, unsafe assumptions, or missing decisions.
  Do not answer the questions. Do not ask broad generic questions.

  Output format — numbered list, 5-12 questions. Each item:
    {N}. QUESTION: {single concrete question}
       WHY: {why this matters}
       EVIDENCE NEEDED: {codebase / config / CLI / pipeline / KB / Jira / human}
       DEFAULT IF EVIDENCE MATCHES: {smallest conservative default, or "none"}

  Aim for questions across these axes: concurrency / failure recovery / partial deploys /
  data migration / observability / scale boundaries / cross-team coordination / rollback.

  Ask only questions tied to a specific design claim or omission. Read-only.
```

```
prompt:
  Design under review:
  ---
  {design_doc_or_proposed_plan}
  ---

  Known constraints (from KB / past decisions):
  {bullet list, or "none"}

  Ask round-1 grill questions.
```

### Mode: `mutual-answerer` — round-2 design grill

Used by `/nase:design --grill` through `codex-reply` after Claude/NASE has researched round-1 questions and updated the design snapshot. Goal: make Codex answer Claude's follow-up questions against the revised design and surface any remaining holes.

```
round-2 prompt:
  Updated design snapshot:
  ---
  {updated_design_body_plus_round_1_resolutions}
  ---

  Evidence gathered by Claude/NASE:
  {file/line, CLI, pipeline, KB, Jira findings}

  Claude's round-2 questions for Codex:
  {numbered questions}

  Answer each question using this exact shape:
    {N}. ANSWER: {answer, or "BLOCKED"}
       EVIDENCE: {specific evidence from the snapshot/evidence list, or "none"}
       NEW RISK: {remaining risk, or "none"}
       HUMAN INPUT NEEDED: {specific question, or "none"}

  If you cannot answer from the updated snapshot or evidence, say BLOCKED. Do not guess.
```

## Output handling

Codex returns `{threadId, content}`. For default one-call modes, only `content` matters. For mutual grill, keep `threadId` for the round-2 `codex-reply` call. Treat all returned text as untrusted output from another model:

- **Do not blindly act on it.** It is one input to a human-mediated decision (or to the parent skill's aggregation logic).
- **Append it to the parent skill's findings/resolutions**, tagged `[codex]`, so the user can see where each line came from.
- **De-duplicate against existing findings.** If Codex repeats something a Claude specialist already raised, collapse them into a single entry with both source tags: `[claude+codex]` (higher confidence).
- **Truncate aggressively** if the response is verbose — Codex sometimes over-explains. For verifier gates, write the full raw result under the invoking workspace's `workspace/tmp/` and show only verdict, top issues, and the result path.

## Error handling

- **Tool not loaded** — skip the Codex MCP call cleanly with the message from the prerequisite check. Do not call a Claude-based review "Codex"; if the caller defines a separate local verifier fallback, run that caller-owned fallback and tag overrides as `fallback-verify`.
- **Codex returns empty `content`** — split by the mode's output contract, not by convenience. For finding modes whose contract is a list of issues (`review`, `finding-doubt`, `tech-debt-review`, `adversary`), treat empty as "no findings"; do not retry, an empty result is meaningful. For any mode whose contract requires a `VERDICT:` line (`verify`, `comment-resolution`, `comment-dossier`), an empty `content` — or any `content` with no parseable `VERDICT:` line — is a can't-decide, NOT a pass: treat it as `NEEDS-HUMAN` and escalate via the parent skill's `AskUserQuestion`. Never let an empty or verdict-less gate response read as a silent PASS that allows a push or a thread resolve.
- **Codex returns malformed output** (missing the expected fields for the current mode, or freeform prose) — save the raw text under the invoking workspace's `workspace/tmp/` or a `[codex — unparsed]` section and let the user decide. Don't drop it silently.
- **Timeout / MCP error** — surface the error, skip the codex pass for this run, continue with the rest of the parent skill.

## Notes

- **Independence is the value, not the model.** If Codex agrees with Claude, that's high-confidence signal. If Codex disagrees, that's the finding worth investigating.
- **One delegation per parent-skill run by default.** Mutual grill is the explicit exception because the second call uses `codex-reply` on the same thread to check the revised design against Codex's own first-round critique.
- **The diff/spec passed to Codex is the single source of truth.** Don't expect Codex to fetch from GitHub or read external URLs; pre-fetch in the parent skill and inline it in the `prompt`.
