# Shared Repo Task Flow

Common protocol for `/nase:*` workflows that touch a repository or GitHub PR.
This doc does not replace each command's specific business logic. It only keeps
the branch/worktree/build/push/mutation guardrails in one place.

## Scope

Use this for:
- repo/PR resolution
- fetch + branch state checks
- worktree setup
- build/lint/typecheck/test loop
- pre-push verification
- commit/push
- GitHub mutation gates
- cleanup/logging

## Protocol

1. **repo/PR resolution**
   - For PR inputs, parse the PR reference with `.claude/scripts/pr-github-helper.py`.
   - Resolve the local repo through `.local-paths`, `workspace/context.md`, or the command-specific repo argument.
   - Stop and ask when two local repos could match the same remote.

2. **fetch + branch state checks**
   - Fetch the target remote before trusting branch or PR metadata.
   - Record current branch, upstream, HEAD SHA, and working-tree status.
   - Do not overwrite uncommitted user changes. If the command requires a clean branch and local changes are present, stop and ask.
   - Never commit directly to protected branches: `develop`, `main`, `master`, or `release/*`.

3. **worktree setup**
   - Use a separate worktree when the user requested isolation, the current branch is not appropriate, or the command needs a PR branch checked out while preserving the current workspace.
   - Use repo-local conventions for branch names and remote selection.
   - Log worktree lifecycle only through the existing hooks/scripts.

4. **build/lint/typecheck/test loop**
   - Discover commands from repo docs, package manifests, build files, `just --list`, and recent CI evidence before guessing.
   - Run the narrowest command that proves the changed behavior first.
   - Expand verification when shared contracts, generated files, cross-module behavior, or public APIs are touched.
   - On failure, fix the root cause and rerun the same failing gate before moving on.

5. **pre-push verification**
   - Re-check `git status --short`, `git diff --check`, and changed-file scope.
   - Run command-specific final verification, including Codex verifier fallback where the command requires it.
   - Summarize exact commands run and unresolved blockers.

6. **commit/push**
   - Stage only intended files.
   - Commit only on a feature/cherry-pick branch.
   - Improve the commit message when the calling command requires the standard commit sequence.
   - Push only after local verification is complete or the user explicitly accepts an environment blocker.

7. **GitHub mutation gates**
   - Follow `.claude/docs/external-mutation-policy.md` before `gh pr create`, `gh pr edit`, `gh pr ready`, review-thread resolution, review comments, reviewer assignment, Jira writes, Confluence writes, or Slack drafts/sends.
   - Draft PRs are the default unless the command explicitly says otherwise.
   - Do not post GitHub review comments unless the user explicitly asked to publish them.

8. **cleanup/logging**
   - Update effort lifecycle or KB only through the command's documented write path and `.claude/docs/workspace-write-guard.md`.
   - Leave unrelated local changes untouched.
   - Report final repo path, branch, pushed remote/ref, verification commands, and remaining blockers.
