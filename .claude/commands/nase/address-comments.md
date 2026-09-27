---
name: nase:address-comments
description: "Resolve existing PR review feedback with fixes or replies. Use for address comments, fix review comments, handle PR feedback, or resolve threads."
argument-hint: "<pr-url-or-number>"
category: Git workflow
---

**Input:** $ARGUMENTS - a GitHub PR URL or number

Follow:

- `.claude/docs/external-mutation-policy.md`: push, PR edit, reply, resolve, and Slack draft actions have separate gates. GitHub CLI mutations use payload-bound `external-write-action.py` manifests.
- `.claude/docs/workspace-write-guard.md` for durable workspace writes.
- `.claude/docs/repo-task-flow.md` for shared repo and PR mechanics.

## Phase 0: Language preflight

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Use `conversation:` for chat/prompts and `output:` for GitHub text.

## Phase 0.5: Input Guard

Follow `.claude/docs/pr-input-guard.md`. On empty input, ask for one PR URL with `AskUserQuestion`.

## Standing invariants

- Mutate one repo only. The PR, KB path, local `origin`, and PR head repo must match `{owner}/{repo}`; forks and second repos are unsupported.
- Keep the PR-unique dossier path `$TMPDIR/pr-comment-dossiers-{owner}-{repo}-{number}.json` and revalidate its repo/head before reuse.
- Preserve KB lookup via `mentions:<path>` for review-thread files.
- GraphQL thread `id` is for resolve; integer `databaseId` is for REST reply. Never interchange them.
- The final post-Phase-4 dossier/action map is the only category source for delivery.
- Every `accept` thread must produce the planned code diff plus the test evidence `.claude/docs/fsd-implementation-loop.md → Engineering Excellence Bar` requires for the changed paths. A no-diff accept blocks delivery.
- `decline` threads receive a reply but stay unresolved. `accept` and `reply-only` threads reply first, then resolve.
- PR Gates are skipped. Do not poll CI or claim PR gates are green. Do report a failing check that is already present in PR data this run fetched for another reason - a known-red check is a finding, not something to withhold. A post-push CI failure otherwise surfaces on the PR like any other; the user runs another round or fixes it directly.
- Slack messages are drafts only. This command never sends them.
- Never force-push and never weaken tests to make them pass.

## State contract

Phases 1-4 produce and must return: `owner`, `repo`, `number`, `repo_path`, `baseRefName`, `headRefName`, `headRepository.nameWithOwner`, `pr_head_ref`, `gate_profile`, `module_inventory`, the PR-unique dossier path, each thread's `id` and `databaseId`, and the final dossier/action map.

`worktree_path`, `pr_branch`, and `no_commit` are set inside `.claude/docs/address-comments-delivery.md` and stay live from there on. A Phase 1-4 return that omits them is complete, not truncated.

## Phase map

| Phase | Owner and load point |
|---|---|
| 0-0.5 | This entrypoint: language and input guard. |
| 1-4 | Read `.claude/docs/address-comments-analysis.md` when entering Phase 1. |
| 5-12 | After the user confirms execution, read `.claude/docs/address-comments-delivery.md`. |

## Phases 1-4: Analyze and confirm

Read `.claude/docs/address-comments-analysis.md` once. Execute repo resolution, bounded dossier collection, diff-first verification, classification, and both user checkpoints. Do not load the delivery document or perform external writes before confirmation.

The analysis document must return the Phases 1-4 names above and an explicit final per-thread dossier/action map. It does not set the delivery-phase names.

## Phases 5-12: Deliver

Only after confirmation, read `.claude/docs/address-comments-delivery.md` once and execute it in order. Keep each external mutation behind its immediate concrete approval gate. If a mutation or resolve partially fails, report exact affected IDs and leave the remaining actions pending rather than guessing.
