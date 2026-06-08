# Skill Authoring Contract — Shared Reference

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
- Show a diff or planned-path preview before applying
- Re-check mtime/hash immediately before the write
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
- Research findings → write to `workspace/tmp/{skill}-{branch}.md` first, pass the path in the prompt
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

## CI

`tests/check-skill-doctrine.sh` enforces sections 1, 2, 2.5, 3, and 8 mechanically, plus archive/import hardening rules. Run via `bash tests/check-all.sh` before pushing any skill change.

## Editing this doc

This is THE source of truth for skill authoring rules. When adding a new rule:
1. Implement the CI check first (in `check-skill-doctrine.sh`)
2. Add the rule here with a CI-check pointer
3. Update affected skills in the same PR — do not ship the rule before the skills comply
