# PR Review Verification Patterns

Checks to run before trusting a claim during PR review. Used by `/nase:discuss-pr` (read-only review) and `/nase:address-comments` (write fixes).

Principle: **prose claims are hypotheses, not evidence**. Always diff-confirm against the file at HEAD before acting (resolve a thread, drop a finding, mark something fixed).

## 1. AI-reviewer assertion-value guard

When an AI reviewer (Copilot, claude bot, codex bot) changes the *expected value* in a test assertion (e.g. `BeEmpty()` → `BeNull()`, `Be(0)` → `Be(null)`, expected status code, expected serialized form), run the test at the suggested form **before** committing. AI reviewers cannot observe runtime values. A serialization or round-trip detail (e.g. `null` re-serializing as `""`) can invalidate the proposed expected value while leaving the structural critique valid.

## 2. Diff-scope verification

For each agent or reviewer finding, verify the flagged line or pattern is genuinely new in this PR — not pre-existing code. Read the base-branch version: `git show origin/{base_branch}:{path}`. Pre-existing issues that the PR did not introduce or modify are not the author's responsibility — drop silently.

## 3. File-vs-description verification

Read the actual file at the referenced line and confirm the reviewer's prose description matches reality. Reviewers (including AI reviewers) misread diffs. If the claim says "missing null check" but the check exists, the suggestion is based on a misread and should be declined regardless of other factors.

## 3.5. Taint-to-new-sink verification

When the diff introduces a **new sink** — a REST path, file read/open, query, or shell argument — fed by an **untrusted field** (a finding's `file`, a webhook value, a user/tenant id), a fresh-context verifier PASS does **not** mean taint-clean. A from-scratch verifier reasons about the slice's stated contract and is blind to taint reaching a sink it authored in the same diff; that is exactly the traversal/injection class it misses. So for any diff that adds a sink: keep authoring and review as separate passes, run the review layer (second reviewer / Copilot / claude) even after a clean verifier, and grep every untrusted field that reaches the new sink for the missing normalization or guard — e.g. `..` surviving `encodeURIComponent` on a contents path, or a file read whose scope falls back to an untrusted value instead of a server-derived one.

## 4. Resolved-thread HEAD verification

Resolved threads (closed by author or `isResolved: true`) are a hypothesis, not evidence. For each resolved thread that touches code-correctness (not pure style/nit), pull the file at HEAD and grep/read the exact filter, branch, condition, or symbol the thread referenced. If the claimed fix is NOT in HEAD, surface as a new 🔧 needs-fix with note `claimed fixed but not in HEAD`.

## 5. Prior-round fix verification

For any 🔧 needs-fix items that originate from an EARLIER review round (comments that predate the most recent commit), do not auto-classify as ✅ can-resolve based on the author's "addressed" reply alone. Run `git show <sha>` for the commit claimed to address the issue and confirm the fix appears in the diff. If the commit doesn't contain the fix, keep the item as 🔧 needs-fix.

## 6. Suggestion-block re-derivation

A reviewer's ```suggestion fenced code block captures *intent*, not a literal patch — especially when it proposes a different data structure for an existing field. Snippets routinely drop critical wrapping that the original declaration carried: generic args, nullability, equality comparers, modifiers (`readonly`, `init`), `AsReadOnly()` wrappers, type aliases. Read the original declaration's full signature before applying. If the suggestion changes the container type (e.g. `ConcurrentDictionary<string, T?>` with `StringComparer.OrdinalIgnoreCase` → `Dictionary<string, T>.AsReadOnly()`), enumerate: (a) is the comparer still needed? (b) keep nullable value type? (c) widen receiver to `ReadOnlyDictionary<TKey,TValue>`? Restore the dropped wrapping in the final implementation — do not copy-paste the snippet verbatim. Pattern surfaced in a prior dashboarding PR review.

## 7. AI-reviewer citation + triage verification

Before echoing or accepting any bot-flagged finding — lint citation, SDK behavior claim, "unused import", cross-pattern asymmetry — run three checks against the file at HEAD. The gate decides whether to echo, accept, or decline. Record the verification command + result in the inline reply so the reviewer can audit.

- (a) **Trigger reachability** — grep call sites / consumer repos for the exact pattern that would trigger the issue. Zero matches → the finding is theoretical; follow-up, not blocker.
- (b) **Runtime contract** — read the installed version's source / types. The installed version is the source of truth, not the bot's generic rule citation.
- (c) **Historical precedent** — grep the codebase for the same pre-existing pattern. If it lives elsewhere since a vendor commit, the asymmetry is informational, not a regression introduced by this PR.

Examples of (b) — installed source vs. cited rule:

- **Lint rule citations** — run the cited linter on the file at HEAD. Bots routinely attach a rule code to patterns that rule doesn't cover. Sanitized pattern: a bot flagged a bash `for` loop as triggering `SC2206/SC2207`, but `shellcheck` exited 0 on the file — those codes only fire on array-assignment patterns, not `for` loops.
- **SDK method behavior** — read the installed version's type definitions / source. Sanitized pattern: a bot suggested `{timeout: 30_000}` on `Playwright.Locator.isVisible()`, but the installed `types.d.ts` marked the option deprecated/ignored. The proposed fix does nothing; the correct shape is `await expect(...).toBeVisible({timeout})`.
- **Unused-using / CS8019** — enumerate types declared in the suspect namespace via `grep -hE "^(public|internal|abstract|sealed)( +(abstract|sealed|partial|static))*( +(class|interface|enum|struct|record))" -- 'path/to/ns-dir/*.cs'`, then `grep -nFwf type-list.txt {flagged-file}`. Any match → the using is needed; decline. Bonus signal: if `build-test` at PR head is already green, CS8019 cannot be triggering on that line; the bot is wrong by construction. Sanitized pattern: bot flagged a transformer's `using …Models` as unused; the file referenced `MetricResponseEntryDto` (defined in that namespace) at multiple lines. Accepting would have broken every call site.

Common failure mode: the bot's *structural* concern is sometimes valid (lint cleanup needed, timeout handling needed) even when the *specific* citation is wrong. Treat citation verification as separate from the underlying concern.

## 8. Comment dossier contract

Before `/nase:address-comments` classifies any unresolved review thread, build the dossier shape from `.claude/docs/ai-code-verification-debt.md → Comment Dossier Contract`.

That shared contract owns the required fields and explicit-only AI provenance rule. `/nase:address-comments` owns the concrete collection commands for comment chain, PR head/base/diff, KB/repo constraints, caller impact, and test/scanner evidence.

Classification is blocked until the dossier exists. If evidence is missing and cannot be collected locally, classify as `ask-user` or draft a reply that names the missing business/intent context. Do not silently downgrade uncertain correctness/security comments to style or out-of-scope.

## 9. Review-Thread Resolution Gate

Gate per `.claude/docs/codex-review.md → Prerequisite`. If the Codex MCP is not loaded, skip cleanly past only the Codex invocation.

Do NOT skip this gate: replying to and resolving someone's review threads is an outward-facing, hard-to-undo action, so it always gets the single-model fallback check below.

**Single-model fallback (Codex unavailable):** spawn one fresh-context read-only subagent (role `verifier` per `.claude/roles.yaml`, tools: Read/Grep/Glob/Bash — no Edit/Write). Give it ONLY:
- the unresolved review threads from Phase 2 (full comment chains)
- the final post-Phase-4 dossier/action map and drafted replies from Phase 6
- the same diff payload described for the Codex prompt below

Ask it to judge independently, per thread:
- does the diff/reply actually address what the reviewer asked?
- is any decline reply factually wrong?
- does any reply contradict the dossier evidence or omit a required verification note?

Do NOT include your own classification reasoning or expected verdict. It must answer in the same `VERDICT:` shape below; apply the same decision tree. Log `thread-resolution verify: single-model fallback (Codex unavailable)`; overrides use tag `fallback-verify`.

Invoke the Codex MCP with the `comment-resolution` mode contract from `.claude/docs/codex-review.md`:

- `cwd` = `{worktree_path}`
- `prompt` = unresolved review threads from Phase 2, the final post-Phase-4 dossier/action map, drafted replies from Phase 6, and the implementation diff:
  - If code changed: `git -C {worktree_path} diff origin/{pr_branch}` (working tree diff before commit)
  - Also include `git -C {worktree_path} ls-files --others --exclude-standard` and the full content of any task-created untracked files
  - If no code changed: say `No code diff; reply-only / decline verification only`
  - For diffs >2000 lines: use `git diff --stat` plus the 5 most-changed files in full
- `developer-instructions` = the `comment-resolution` template verbatim
- `sandbox` = `read-only`

Expected shape:
```
VERDICT: PASS | FAIL | NEEDS-HUMAN
THREADS NOT ADDRESSED: ...
REPLY / RESOLVE RISKS: ...
SCOPE CREEP: ...
REASONING: ...
```

Decision tree:

- **PASS** → log one line (`Codex thread-resolution verify: PASS`) and proceed to Phase 8. No user prompt.
- **NEEDS-HUMAN** → present the full Codex output and ask via `AskUserQuestion`:
  - Q: "Codex flagged ambiguity in the review-thread resolution. What now?"
  - Options: `Revise first` / `Proceed — push anyway` / `Show me the diff + replies`
  - Honor the user's choice.
- **FAIL** → do NOT commit or push. Present the full Codex output and ask via `AskUserQuestion`:
  - Q: "Codex says at least one review thread isn't safely addressed. What now?"
  - Options: `Fix it` / `Override — Codex is wrong` / `Cancel`
  - On "Fix it": re-enter Phase 6 with the failing thread(s) as requirements, then rerun build/test and this gate.
  - On "Override": log the override to the daily log (tag: `codex-override`) before proceeding.

Malformed output (no `VERDICT:` line) → treat as `NEEDS-HUMAN`, present raw `content`, and ask the user.

This gate checks reviewer intent, not just tests.


## 10. Review Frame and Specialist Selection

### Sense Check

Mandatory private evaluation before Step 3. The result must be surfaced early in Step 6 — even when every pillar passes. This block exists because diff-scope (4a), code-matches-description (4b), and verification matrix (5.5) live in different sections and reviewers (and you) miss them when scattered.

Use this to answer four explicit questions about the PR before any specialist runs:

**Pillar 1 — Scope alignment**
- Extract Jira keys from PR body / title / branch name. Match `[A-Z]+-\d+` (most UiPath projects use `IN-####`); also accept Linear keys when the repo KB references Linear.
- If a Jira key is found: fetch the ticket via Atlassian MCP `getJiraIssue` (`cloudId` from `workspace/config.md`). Compare ticket summary + description + acceptance criteria against diff scope.
  - Diff is a strict subset of Jira AC and PR body does not document the partial delivery → flag as ⚠️ partial scope.
  - Diff exceeds Jira AC (extra files, unrelated edits) and PR body does not justify the extension → flag as ⚠️ scope creep.
  - MCP unavailable / ticket access denied → mark `Scope` evidence as `Jira fetch skipped: MCP unreachable` and fall back to description-only comparison.
- If no Jira key is found: compare diff against the PR body's stated change list. Every diff file should map to a body claim; every body claim should map to at least one diff file. Asymmetries become findings.

**Pillar 2 — Rationale soundness**
- Read Step 2.5 Problem/Old/New/Constraints and ask: given that problem statement, does the chosen approach make sense?
- Consider one realistic alternative reachable from KB or adjacent code (e.g., feature flag instead of full removal, targeted patch instead of refactor, library upgrade instead of vendoring). If the alternative is concretely simpler/safer/cheaper, surface it as ⚠️; otherwise note the rationale is sound.
- Do **not** invent alternatives that contradict known platform prohibitions or that the PR body explicitly addresses.

**Pillar 3 — Out-of-scope changes**
- Walk the changed-file list. For each file, ask: is this directly required by the stated problem?
- Flag drive-by formatting, unrelated refactors, surprise dependency bumps, leftover debug code, generated-file churn, and unrelated config edits. One ⚠️ per cluster, not per file.
- Test fixtures and tests for the changed surface are in-scope by default — do not flag.

**Pillar 4 — Test sufficiency**
- Reuse the Step 5.5 verification matrix result. Verdict here is a one-symbol summary:
  - ✅ — recommended bar met **and** PR-description test plan present
  - ⚠️ — partial: either plan missing or one matrix layer untested
  - ❌ — no plan and no executed verification for non-trivial behavior change
- ❌ on a non-trivial change is automatically a `[MED]` finding (already emitted by Step 5.5 §4 as `Verification gap`) — do not duplicate as a separate finding here.

Record each pillar's verdict + evidence in a private scratchpad; render in Step 6.

### Build Risk Map, Select Specialists, and Engage Existing Comments

Before launching any specialist agents, build a private risk map. This avoids running every specialist on every PR.

Risk map rows:

| Area | Signals | Risk | Specialist(s) |
|------|---------|------|---------------|
| Problem fit | unclear body, linked issue mismatch, core path not touched | low/med/high | Problem fit |
| Logic | state transitions, null/default changes, async, retries, persistence | low/med/high | Logic correctness |
| Design | new abstraction, duplicated flow, changed boundary, many files | low/med/high | Design/elegance, Architecture |
| Security | auth, tenant isolation, secrets, external input, telemetry export | low/med/high | Security |
| Verification | non-trivial behavior, missing tests, migration/deploy path | low/med/high | Testability |
| Review history | recurring comments, same files recently reverted, old decisions | low/med/high | Git history |
| Comments/docs | comments changed or code contradicts existing comments | low/med/high | Code comments |
| Pipeline/data | ETL, SQL, EventHub/Queue/Timer, LookerML, Avro/Parquet | low/med/high | Pipeline gates |
| AI-slop self-review | self-authored PR; no-op/churn-only diff, filler description, leaked assistant phrasing, agent-report voice | low/med | AI-slop self-check |

Selection rule:
- Always cover `Problem fit`, `Logic correctness`, and `Testability` in the main review pass — these plus `Security` (whenever its signals fire) are the always-on hard gate; every other lens is change-scoped.
- Spawn a specialist only when its risk row is `med` or `high`, or the user explicitly requested that focus.
- Skip `Security`, `Git history`, `Code comments`, and `Pipeline gates` when their trigger signals are absent — match the lens to the change class (e.g. a backend-only PR skips any UI/design lens).
- Run `AI-slop self-check` **only when the PR author login is one of the user's own GitHub accounts** (`work_gh_account` / `personal_gh_account` from `workspace/config.md`). Never run it on a teammate's PR — judging whether someone else's contribution "looks AI-generated" is low-value and adversarial. It is a self-nudge, not a reviewer verdict.
- Run Codex second-opinion only for high-risk PRs, security-sensitive PRs, large diffs, unfamiliar core areas, or explicit user request.
- Show the selected specialist list in the final output so omissions are auditable.

**Pipeline-touch detection:** if diff touches `*.sql`, ETL/ingestion/aggregation paths, Avro/Parquet, Databricks notebooks, LookerML, or EventHub/Queue/Timer Functions, add the Pipeline gates agent.

| Agent | Focus |
|-------|-------|
| **Problem fit** | Whether the PR solves the framed problem end-to-end without overreaching or leaving the main gap open |
| **Logic correctness** | Branch conditions, state transitions, null/default behavior, async/race risks, idempotency, data loss, bad fallbacks |
| **Design/elegance** | Whether a simpler local pattern, clearer API boundary, smaller abstraction, or less duplicated flow would solve the same problem better |
| **Architecture** | DRY violations, KISS violations, layering issues, SRP violations, abstraction quality |
| **Security** | Input validation, header injection, credential exposure, SSRF, auth bypass risks |
| **Testability** | Missing coverage for new paths, tests that only chase signatures, untestable designs. **Also emit a verification-bar recommendation** (see Step 5.5 classification) and check the PR body for a test plan section — if absent for any non-trivial change, emit a `[MED]` finding tagged `Verification gap`. |
| **Git history** | Patterns rejected in past PRs, recurring comments on the same files, regressions |
| **Code comments** | Violations of guidance in inline comments, stale or contradicted comments |
| **Pipeline gates** (conditional) | Three Meta-style gates for pipeline changes — see below |
| **AI-slop self-check** (conditional, self-authored only) | Heuristic self-nudge that the PR reads like unedited AI output — see below |
| **Codex second-opinion** (conditional) | Cross-model pass via Codex MCP — see below |

**Pipeline gates agent** — spawn only when pipeline-touch detected:

1. **Correctness** — does the PR show evidence of row-count + checksum + business-aggregate comparison vs the prior pipeline on a representative window (≥ 7 days of partitions)? Acceptable evidence: backfill diff log linked in PR body, a comparison query referenced in description, a validation test added. Missing → flag as 🔧 needs-fix with severity proportional to blast radius.
2. **Landing latency** — does the change risk regressing landing latency vs legacy? Look for: new joins on large tables without explicit index, removed parallelism, additional serial waits, new external calls in the hot path. Flag candidates and ask author for evidence (perf test result, EXPLAIN ANALYZE, prior-run timing).
3. **Resource utilization** — does the change increase compute / IO / cost vs legacy? Look for: new full scans, removed pushdown filters, larger shuffle, additional materialization, more aggressive retry. Flag candidates and ask author for evidence (warehouse credit estimate, DBU diff, query profile).

Output exactly the three gates plus per-gate verdict: ✅ evidenced / ⚠️ unclear / 🔧 missing. If any gate is 🔧 missing for a production pipeline, score as `[HIGH]` (≥80) at minimum.

**AI-slop self-check** — spawn only on a self-authored PR (gate above). Adapted from SlopGuard's static heuristics, scoped to *your own* output so you fix it before reviewers see it. Scan the diff + PR description for:

- **No-op / churn-only** — whitespace, reorder-only, comment-only, or generated-file churn with no behavior change masquerading as a real change.
- **Filler description** — content-free praise ("comprehensive solution", "robust implementation"), restating the diff in prose, or a body that never states the actual problem.
- **Leaked assistant phrasing** — "Here's the…", "I've implemented…", "Let me…", "Note that…", emoji-section headers, or other unedited-LLM tells in code comments, the PR body, or commit messages.
- **Agent-report voice** — narrating what was done as a transcript ("First I…, then I…") instead of describing the change.
- **Comment slop** — comments restating the code line they sit above, or `// TODO`/placeholder left by generation. (Cross-check `Code comments` lens; do not double-count.)

This lens is **advisory only**: cap every finding at `[MED]`, render in the Step 6 findings tier tagged `self-review`, and never draft an inline comment from it. Skip any signal already raised by another pillar — scope creep is Pillar 3, premature abstraction is Design/elegance. If nothing fires, say so in one line. The point is a pre-reviewer cleanup pass (`/nase:simplify` territory), not a severity gate.

**Codex second-opinion agent** — conditional per the risk-map selection rule above. Gate per `.claude/docs/codex-review.md → Prerequisite`; skip cleanly if MCP is not loaded:

- `cwd` = absolute repo path
- `prompt` = `{repo_name} / PR #{pr_number} — {pr_title}`, PR diff (or diff stat + top changed file snippets for PRs >5000 lines), and one-line summary of each queued Claude finding so Codex looks for new angles without duplicates
- `developer-instructions` = the `review` template verbatim, with `{focus_areas}` set to the same focus list passed to the Claude specialists
- `sandbox` = `read-only`

Run Codex in parallel. Parse `[SEV] file:line — issue. Fix: action.`, score via Step 4, tag `[codex]`; if Claude and Codex flag same file/line, tag `[claude+codex]` and add +10 confidence capped at 100.

**While agents run — triage existing comments** (if any):

Auto-classify unresolved threads and present a confirmation table:

| # | File:Line | Author | Summary | Auto-classification |
|---|-----------|--------|---------|-------------------|
| 1 | `foo.ts:42` | @alice | "null check missing" | 🔧 needs-fix |
| 2 | `bar.ts:10` | @bob | "why not use X?" | 💬 needs-reply |
| 3 | `baz.ts:99` | @alice | "nit: rename" | ✅ can-resolve |

Classification rules:
- 🔧 **needs-fix** — reviewer identified a concrete defect or missing guard; code change required
- 💬 **needs-reply** — a question or design discussion; reply needed, may or may not require code change
- ✅ **can-resolve** — nit/style/already addressed; safe to resolve without action
- 🔍 **needs-research** — unclear without more context; look into code or Confluence before deciding

Ask "Does this look right? Any to change?" Research each 🔍 item before final classification.

Apply `.claude/docs/pr-review-verification.md` §4 and §5 on every classification pass.

**Bot-comment batch-verify (read-only):** when the PR has ≥10 prior bot inline comments with concrete file:line claims, spawn one investigator agent for a single-pass table: `file:line | claim text | state`, where state is `CONFIRMED` / `FIXED` / `WRONG` / `INCONCLUSIVE` for the PR's current head. Cite the table for context; do not echo confirmed claims as net-new findings. This gate stays read-only; do not react, reply, resolve, or post a review.

**Duplicate-of-N reframe check:** when a candidate finding would be dismissed as "duplicate of PR #N" or "superseded by #N", open #N's body + commits first. If #N explicitly defers the surface now being changed (`This PR does NOT change X`, unchecked `[ ]` items, "follow-up planned"), the PRs are complementary, not duplicate — the finding stands.

Collect the final classifications. This skill never posts reactions, replies, resolves, or reviews.

## 11. Diff-First Investigation

Reusable directive for PR-review code investigation — referenced by `/nase:discuss-pr` and `/nase:address-comments`, and inlined (compact form) into any `Explore` agent they spawn for PR code investigation, because a spawned subagent does not load this doc. Distinct from §2 (which verifies the *scope of findings*); this governs *how you investigate*.

Review investigation is **diff-first**: start from the diff and a specific question, `rg`/`glob` to narrow **before** reading, read exact line ranges, and batch discovery searches before file reads. This is diff-**first**, not diff-**only** — widen deliberately by the rules below, never by default.

- **Narrow before read.** Form the specific question the diff raises, then `rg`/`glob` to locate; do not read whole files or scan neighboring directories to "get oriented". Batch the discovery searches, then read the exact ranges they point to.
- **Failed-search recovery (bounded).** If an `rg`/`glob` returns nothing or errors, retry **once** using the changed symbol or path from the diff. If that also finds nothing, mark the concern evidence-missing / ask the author. Never guess neighboring paths and never fall into repeated broad sweeps — that is the exploration-loop failure mode.
- **Positive widening rule.** Widen beyond the diff only to a contract the changed hunk itself evidences — a caller of a changed public symbol, an imported config key, a schema field, a deployment contract — and cite the diff→widen linkage. Absent such a signal, stay in the diff.
- **Activation-PR carve-out.** For a §10 / Step 5a activation-PR candidate (last PR in a multi-PR migration, small diff / large blast radius), the activation transition **is** the diff-evidenced contract: enumerate every newly-live entry point and its load-bearing auth/scope/test path. Do not widen to dormant or unrelated migration components — the broad walk is bounded to what this PR activates.

## 12. Trace-Shape Self-Check

A short self-check on *how* the investigation ran — applied by **the agent that did the investigation, before it emits findings** (its own search sequence is in its own context). For a spawned `Explore` agent this rides in the spawn prompt as a pre-return self-check; the main thread never sees a subagent's trace, so this is **not** a fresh-context-verifier gate. It is behavior-shaping self-check guidance, not a scored gate.

Before returning findings, confirm:

- **Narrowed, not widened** — investigation started from the diff + a specific question and narrowed with `rg`/`glob`, rather than reading broadly to orient.
- **Batched discovery** — discovery searches ran before file reads, not interleaved read-by-read.
- **Diff-anchored** — every read traces back to the diff or a hunk-evidenced contract (positive widening rule), not a guessed path.
- **Recovered without guessing** — any failed search was retried once with the changed symbol/path, then abandoned to evidence-missing — no neighboring-path guessing.

A "widen-first / path-guessing" trace is a **WEAK** signal even when the final finding looked right: it means the finding survived a noisy process and the next one may not.
