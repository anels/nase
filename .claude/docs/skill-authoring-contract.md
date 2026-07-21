# Skill Authoring Contract — Shared Reference

## Contents

- Scope
- 1. Language preflight (chat output)
- 2. External mutation = explicit gate
- 2.5. Durable workspace writes = staged + drift-checked
- 3. ADO CLI doctrine
- 4. Git safety
- 5. AskUserQuestion discipline
- 6. Bash hygiene
- 7. Subagent context isolation
- 8. Anti-overlap rule ("Saying yes = saying no") + team-architecture pattern
- 9. Output discipline (delegated)
- 10. Skill-invocation error handling
- 11. Authoring self-review: failure modes & invocation cost (advisory)
- 12. Context budgets and progressive disclosure
- CI
- Editing this doc

Hard rules every `/nase:*` (and `/nase:workspace:*`) skill MUST follow. Companion to `.claude/docs/skill-contract.md` (output discipline). This doc covers **behavior**.

Skim once before authoring; treat as binding when editing skill files.

## Scope

This contract applies to nase **slash-commands** (`.claude/commands/nase/*.md`, `.claude/commands/nase/workspace/*.md` synced from `workspace/skills/*.md`). It does **not** govern Anthropic Agent Skills (`~/.claude/skills/{name}/SKILL.md`) — those follow the Agent Skills open standard at agentskills.io. If you author both kinds in the same PR, treat them as separate contracts.

---

## 1. Language preflight (chat output)

Every chat-producing skill MUST start with a Step 0 language-preflight block. Use the canonical snippet in `.claude/docs/language-config.md → Minimum Step 0 block`. CLAUDE.md inheritance alone is **not** sufficient — auto-drift to English has been observed.

Skills that also write to external systems (PR / Slack / Jira / Confluence) read **both** `conversation:` AND `output:` and route per channel.

CI check: `tests/check-skill-doctrine.sh → D4` (hard fail).

---

## 2. External mutation = explicit gate

Every Slack / Jira / Confluence / GitHub / ADO / cloud-resource mutation MUST go through one of:
- Draft-first (`slack_send_message_draft`, `workspace/tmp/{name}.md` for Confluence, draft PR)
- `AskUserQuestion` immediately before the mutation call, showing the concrete payload

No "I'll just transition this ticket without asking" exemptions — Jira-In-Progress is a notification + watcher event too. Slack is absolute: NEVER call `slack_send_message`, always `_draft`.

Reference `.claude/docs/external-mutation-policy.md` from any mutation-capable skill (one-line pointer near the top).

CI check: `tests/check-skill-doctrine.sh → W1`.

---

## 2.5. Durable workspace writes = staged + drift-checked

Any skill that writes durable local workspace state MUST reference `.claude/docs/workspace-write-guard.md` near the top and use `.claude/scripts/workspace-write-guard.py` for full-file durable writes unless it is using a documented append-only exception. Follow this flow:
- Read existing target mtime/hash before drafting
- Stage the proposed output under `workspace/tmp/`
- Record the staged SHA-256 returned by the helper
- Show a diff or planned-path preview before applying
- Pass target mtime/hash and staged SHA-256 to the apply command
- Apply only the documented target

This applies to `workspace/kb/**`, `workspace/tasks/**`, `workspace/skills/**`, `workspace/efforts/**`, `workspace/journals/**`, `workspace/logs/**`, `workspace/context.md`, and `workspace/communication-style.md`. Append-only daily logs, journals, and JSONL stats may use the documented append-only exception, but must still keep writes narrow.

CI check: `tests/check-skill-doctrine.sh → D10` (hard fail).

Auto-write modes (`--auto`, `--auto-accept`, or command-owned automatic writes)
may skip human confirmation only. They must never skip final drift checks.

---

## 3. ADO CLI doctrine

Per `feedback_ado-az-cli-only.md`: all Azure DevOps interactions use `az` CLI. Never `curl -u ":$ADO_PAT"` or similar PAT-bearing curl invocations.

- Read queries: `az pipelines runs list/show`, `az pipelines build show`, `az pipelines variable list`
- Non-CLI verbs (cancel, post with nested JSON, timeline): `az rest --method <verb> --uri ...` — still reuses `az login`, no PAT env vars
- Auth failures: tell the user to `az login`, do not fall back to curl

CI check: `tests/check-skill-doctrine.sh → D1` (hard fail).

---

## 4. Git safety

- Never push directly to `main`/`master`/`develop`/`release/*` (`block-dangerous-git.sh` enforces; do not bypass with `--no-verify`)
- New work goes on a feature branch in a worktree (`workspace/tmp/worktrees/{repo}-{suffix}/`)
- Default branch must be clean before worktree creation; otherwise ask first
- Force-push only with `--force-with-lease`, and only after warning the user
- Per `feedback_detached-head-worktree-push.md`: if the branch is checked out elsewhere, work on detached HEAD and push `HEAD:branch`

---

## 5. AskUserQuestion discipline

- Batch related questions into a single `AskUserQuestion` call (`questions` array). Multi-screen prompt sequences for the same decision are a token-burn anti-pattern.
- Show the **concrete payload** in the question prompt — Jira transition target, Confluence diff, ADO `templateParameters`, PR title+body. Generic "should we proceed?" is not a gate.
- After the gate fires, ACT immediately on the answer — do not wait for an additional confirmation turn.

---

## 6. Bash hygiene

- Quote `$VAR` expansions when they may contain paths or whitespace: `"$LOG_FILES"` not `$LOG_FILES`
- For lists of paths, prefer arrays over space-separated strings; if you must use a string, pipe through `xargs -0` or `read -r -a arr`
- Use `set -euo pipefail` in long scripts; `set -uo pipefail` if a non-zero exit code is part of the contract somewhere
- Guard `$()` substitution failures with `|| { echo "ERROR: ..." >&2; return 1; }` when downstream depends on the value being non-empty
- `gh api --paginate -q 'length'` emits per-page lengths — sum via `awk '{s+=$1} END {print s}'` or use `jq -s 'add | length'`
- Verify `command -v` before invoking optional binaries (`gh`, `az`, `7z`)
- Follow `.claude/docs/cli-tooling.md` before adding a new optional CLI dependency to a skill; prefer `.claude/scripts/tool-availability.py` for machine-local probes and keep missing optional tools warning-only unless the current workflow cannot produce reliable evidence without them

---

## 7. Subagent context isolation

Subagents spawned via `/team` or `Agent` do NOT inherit the calling session's context. If the subagent needs:
- Research findings → derive a path-safe slug for branch/repo identifiers, write to `workspace/tmp/{skill}-{slug}.md`, and pass the path in the prompt
- Repo build/test commands → include verbatim in the prompt (do not assume KB pre-loading)
- Conversation state → cannot inherit it; either send what's needed or restructure to keep the work in the caller

After completion: read the artifact file back, then delete it (`workspace/tmp/` is not auto-cleaned).

---

## 8. Anti-overlap rule ("Saying yes = saying no") + team-architecture pattern

CLAUDE.md §"Saying yes = saying no" applies at skill-creation time. Before authoring a new skill:

1. Grep existing trigger keywords across `.claude/commands/nase/*.md` + `workspace/skills/*.md` for overlap
2. Answer in your PR description: "what existing skill does this make redundant, and if none, why isn't this a flag on an existing one?"
3. Refuse to ship if two skills share >50% of their trigger surface — fold into a `--flag` instead
4. Declare the team-architecture `pattern` in frontmatter (see vocabulary below). If the skill composes patterns (e.g. supervisor wrapping a fan-out), list `sub-patterns`.

Counter-example: `/nase:learn` + `/nase:workspace:learn-with-exa` shipped with overlapping triggers ("learn", topic keywords) for 6 weeks before being folded into `/nase:learn --exa`. Don't repeat.

### Pattern vocabulary

Pattern is a documentation tag — it does not change runtime behavior. The point is to make protocol surface readable when scanning many skills.

| Pattern | When to pick |
|---|---|
| `pipeline` | Strict-order stages, each step's output feeds the next, no branching. Default for `fsd`/`design`/`onboard`/`learn`/`tech-digest` style flows. |
| `fan-out` | Parallel independent specialist agents + fan-in merge. Pick when 3+ subagents can run with disjoint inputs. Example: `/nase:discuss-pr`. |
| `expert-pool` | Input dispatcher routes to one branch out of N. Example: `/nase:learn` routes by input type (URL / keyword / tip / empty). |
| `producer-reviewer` | Generation step + independent reviewer (agent or human gate). Example: `/nase:workspace:doc-pr-head-ground-scan`. |
| `supervisor` | Centralized dynamic distribution to subagents (decided at runtime). Rare in nase — Agent-tool main thread already supplies this implicitly; only tag when the skill itself explicitly dispatches. |
| `utility` | Read-only display / single-pass transform with no team coordination. Example: `/nase:help`, `/nase:stats`, `/nase:reflect`. |

Deliberately not used: `hierarchical-delegation` — recursive top-down delegation is over-engineering for a single-operator workspace.

### Frontmatter field

```yaml
---
description: ...
pattern: pipeline
sub-patterns: []     # optional; list combinations, e.g. [pipeline, supervisor] for fsd
---
```

Use one of: `pipeline`, `fan-out`, `expert-pool`, `producer-reviewer`, `supervisor`, `utility`.

Required for every core skill under `.claude/commands/nase/*.md`. Put pattern reasoning in the PR or effort doc when it matters.

CI check: `tests/check-skill-doctrine.sh → D9` (hard fail).

---

## 9. Output discipline (delegated)

Follow `.claude/docs/skill-contract.md` — canonical rules for artifact/chat/verbose handling and `AskUserQuestion` batching live there.

---

## 10. Skill-invocation error handling

When a skill chains other skills (`/nase:reflect`, `/nase:learn`, `/team`, etc.):
- Don't assume success — catch failure ("skill X not available", "tool returned error", "user cancelled")
- Set the per-step status to `failed` not `done`, continue to next step where safe
- Surface the failure once at the end (do not bury silently)

---

## 11. Authoring self-review — failure modes & invocation cost (advisory)

Judgment-based self-review checklist for new/edited skill bodies. **Advisory, not CI-gated** (these are inherently non-mechanical — detecting a no-op line or a backfiring prohibition needs a reader, not a grep). Source: `mattpocock/skills → writing-great-skills`; full KB context in `workspace/kb/general/workflow.md 2026-07-10`.

Root virtue: **predictability = the skill drives the same *process*, not the same output.** Cost/maintainability are symptoms of losing that, not competing goals.

Six failure modes to scan a draft for:
1. **Premature completion** — a step lets the agent stop early. Fix order: sharpen the step's completion criterion *first*; only then split to hide post-completion steps (hiding works only across a real context boundary, not an inline model-invoked call).
2. **Duplication** — the same meaning stated in two places. Single source of truth per meaning.
3. **Sediment** — stale layers left by edits. The default fate without active pruning.
4. **Sprawl** — too long even when every line is live. Cure is the information hierarchy / a split, not word-trimming.
5. **No-op** — a line the model already obeys by default. Test: *does it change behavior vs default?* "Be thorough" is a no-op; replace with a stronger leading word ("relentless"). Prune with the no-op test **per sentence in isolation — delete the whole sentence when it fails**, not trim words. Be aggressive.
6. **Negation** — a bare prohibition backfires ("don't think of an elephant"). Prompt the *positive* target instead; keep a ban only when the target is unphraseable positively, and still pair it with what-to-do.

### Read-tax discipline

A skill's resident cost is driven by which reference files it re-reads every run, not only by its body length. Three rules:

- **Inline the always-read core.** The minimal shapes/recipes nearly every run reads belong in the entrypoint body (or one `core-recipes.md` loaded once up front), not in per-topic files opened separately each run.
- **Lazy-gate heavyweights behind explicit triggers.** Large templates and phase-specific docs load only when a named condition holds (e.g. "target file absent"), never by default.
- **Read each reference at most once per run.** Do not re-open a recipe already applied.

When a skill or its shared docs grow expensive, measure Read% (reads / total tool calls) before trimming prose. The fix is usually inlining the hot core plus gating the cold tail, not word-trimming (cross-check the sprawl failure mode above).

Completion criteria have two axes: **clarity** (resists premature completion) + **demand** (sets legwork depth — an exhaustive "every modified model accounted for" beats "produce a change list"). Strongest criteria are both checkable and exhaustive.

**Invocation-by-cost** (reinforces §8 pattern + the two-tier taxonomy in `workflow.md`): model-invoked keeps a `description` and pays permanent **context load** (it sits in the window every turn) — pick it only when the agent or another skill must reach the skill on its own. User-invoked (`disable-model-invocation: true`) is zero context load but spends human **cognitive load** (someone must remember it exists). When user-invoked skills outgrow memory, add one router skill that names the others.

---

## 12. Context budgets and progressive disclosure

Treat the command body as a dispatcher: public interface, routing, mandatory safety/quality gates, and completion contract. Put deterministic parsing in scripts and branch-specific procedures, long examples, query recipes, and templates in direct references.

Hard budgets:

- every top-level core or workspace entrypoint: at most 250 lines and 12,000 bytes
- each description: at most 240 characters; the combined native + workspace catalog: at most 9,000 characters
- shared references: at most 500 lines; references over 100 lines include `## Contents`

Descriptions state capability plus concrete trigger/exclusion language. Do not summarize the workflow there; workflow summaries can override the more precise body and permanently consume routing context. Omit `when_to_use` when it only repeats `description`.

Keep execution-critical references one level from the entrypoint where practical. Avoid self-references and missing paths. Preserve safety, completion, and behavior gates when moving detail; context reduction is not permission to weaken results.

CI checks: `tests/scripts/test-command-skill-size-budget.sh` and `tests/check-shared-doc-refs.sh`.

## CI

`tests/check-skill-doctrine.sh` enforces sections 1, 2, 2.5, 3, and 8 mechanically, plus archive/import hardening rules. The context-budget checks enforce section 12. Run via `bash tests/check-all.sh` before pushing any skill change. Section 11 is advisory.

## Editing this doc

This is THE source of truth for skill authoring rules. When adding a new rule:
1. For a mechanically enforceable rule, implement the CI check first (in `check-skill-doctrine.sh`) and add the rule here with a CI-check pointer
2. Put non-mechanical guidance in §11 and label it advisory
3. Update affected skills in the same PR — do not ship a new enforceable rule before the skills comply
