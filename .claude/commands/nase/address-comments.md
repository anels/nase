---
name: nase:address-comments
description: "Resolve existing PR review feedback with fixes or replies. Use for address comments, fix review comments, handle PR feedback, or resolve threads."
argument-hint: "<pr-url-or-number>"
pattern: pipeline
category: Git workflow
---

**Input:** $ARGUMENTS - a GitHub PR URL or number

Follow:

- `.claude/docs/external-mutation-policy.md`: push, PR edit, reply, resolve, and Slack draft actions have separate gates. GitHub CLI mutations use payload-bound `external-write-action.py` manifests.
- `.claude/docs/workspace-write-guard.md` for durable workspace writes.
- `.claude/docs/repo-task-flow.md` for shared repo and PR mechanics.

## Phase 0: Language preflight

Follow `.claude/docs/language-config.md` minimum Step 0. Use `conversation:` for chat/prompts and `output:` for GitHub text.

## Phase 0.5: Input Guard

Follow `.claude/docs/pr-input-guard.md`. On empty input, ask for one PR URL with `AskUserQuestion`.

## Standing invariants

- Mutate one repo only. The PR, KB path, local `origin`, and PR head repo must match `{owner}/{repo}`; forks and second repos are unsupported.
- Keep the PR-unique dossier path `$TMPDIR/pr-comment-dossiers-{owner}-{repo}-{number}.json` and revalidate its repo/head before reuse.
- Preserve KB lookup via `mentions:<path>` for review-thread files.
- GraphQL thread `id` is for resolve; integer `databaseId` is for REST reply. Never interchange them.
- The final post-Phase-4 dossier/action map is the only category source for delivery.
- Every `accept` thread must produce the planned code diff and adequate test evidence. A no-diff accept blocks delivery.
- `decline` threads receive a reply but stay unresolved. `accept` and `reply-only` threads reply first, then resolve.
- PR Gates are skipped. Do not run `gh pr checks`, poll CI, or claim PR gates are green.
- Slack messages are drafts only. This command never sends them.
- Never force-push and never weaken tests to make them pass.

## State contract

Preserve `owner`, `repo`, `number`, `repo_path`, `baseRefName`, `headRefName`, `headRepository.nameWithOwner`, `pr_head_ref`, `gate_profile`, `module_inventory`, the PR-unique dossier path, each thread's `id` and `databaseId`, the final dossier/action map, `execution_mode`, `worktree_path`, `pr_branch`, and `no_commit`.

## Phase map

| Phase | Owner and load point |
|---|---|
| 0-0.5 | This entrypoint: language and input guard. |
| 1-4 | Read `.claude/docs/address-comments-analysis.md` when entering Phase 1. |
| 5-12 | After the user confirms execution, read `.claude/docs/address-comments-delivery.md`. |

## Phases 1-4: Analyze and confirm

Read `.claude/docs/address-comments-analysis.md` once. Execute repo resolution, bounded dossier collection, diff-first verification, classification, and both user checkpoints. Do not load the delivery document or perform external writes before confirmation.

The analysis document must return the state contract above and an explicit final per-thread dossier/action map.

## Phases 5-12: Deliver

Only after confirmation, read `.claude/docs/address-comments-delivery.md` once and execute it in order. Keep each external mutation behind its immediate concrete approval gate. If a mutation or resolve partially fails, report exact affected IDs and leave the remaining actions pending rather than guessing.
