---
name: nase:improve-commit-message
description: "Rewrite the latest commit message to match repo conventions. Use after committing, before push, or for improve commit, fix commit message, amend commit, or clean up commit."
argument-hint: "[--auto-accept]"
pattern: utility
category: Git workflow
---

Good commit messages are searchable documentation. When someone runs `git log --oneline` six months from now, each line should tell them what changed and why — without opening the diff.

**Input:** $ARGUMENTS — optional flags (see below)

## Step 0 — Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Use `conversation:` for chat and prompts; use `output:` for the rewritten commit message.

## Flags

- `--auto-accept` - skip confirmation and amend immediately only when `push_state: not-pushed`. A pushed HEAD, or a HEAD whose remote freshness cannot be established, still requires the exact approval in Step 6. If the current message is already well-formed and the proposed message is identical, skip the amend entirely.

<investigate_before_acting>
Always verify git state (current branch, remote refs, commit history) before taking action.
Never assume repository state — check it with git commands first.
</investigate_before_acting>

## Steps

<workflow>

### 1. Collect commit context

One call captures the HEAD message, parent count, publish state, and every commitlint config candidate:

```bash
python3 .claude/scripts/git-commit-context.py [--repo /abs/path/to/repo]
```

`--repo` defaults to the current directory; pass it when the commit lives in another checkout.

From `commitlint.candidates`, take the config CI actually loads — multiple may exist and the first found is not automatically the winner. Confirm against the `configFile:` line in the commitlint CI job log when a run exists. JSON candidates arrive pre-parsed under `rules`; a non-JSON candidate that CI loads still needs a direct Read. Extract:
- `header-max-length` (validation limit; display target is always **80 chars**)
- `type-enum` (allowed types)
- `subject-case` (0 = disabled, 2 = enforced)
- `subject-full-stop`

If no config is found (`commitlint.found: false`), use defaults: max 72, lowercase, no period, standard types.

### 2. Check safety

The helper already refreshed every configured remote head before deciding whether HEAD is published.

- If `is_merge` is true (>1 parent): abort — do not amend merge commits.
- `is_pushed` is `true` when `push_state` is `pushed` or `unknown`; only a successful refresh followed by no containing remote branch yields `false`. This fail-closed value determines the Step 6 branch.

### 3. Analyze changes (diff-first strategy)

**Get the diff**, branching on `is_initial_commit` from Step 1:
- true → `git show HEAD --format="" --patch`
- false → `git diff -U5 HEAD^ HEAD`

Read the diff first. Only read full source files when the 5-line context is insufficient to understand the purpose or scope of the change. Read only the files needed to understand the change scope.

### 4. Determine type and scope

Pick the commit **type** from the project's `type-enum` (or standard list):
`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

Pick an optional **scope** from the primary module/component affected (e.g., `auth`, `api`, `ui`, `db`, `deps`).

### 5. Generate improved message

Format: `type(scope): concise subject`

Rules:
- **Summary line target: `min(header-max-length, 80)` characters** — take the smaller of the configured `header-max-length` (default 72) and 80. The 80-char ceiling exists because GitHub PR titles, `git log --oneline`, and terminal UIs truncate beyond 80; a project may pick a stricter limit but never a looser one. Examples: `header-max-length=72` → use 72; `header-max-length=100` → still use 80. Overflow detail belongs in the commit body.
- Imperative mood: "add" not "added"
- No period at end (unless `subject-full-stop` allows it)
- Respect project's `subject-case` rule
- Be specific about *what* changed; put *why* in the body if needed
- If the change is too broad for 80 chars, pick the most impactful change for the summary and list the rest in the body
- **Body shape (commitlint `footer-leading-blank` compatibility):**
  - Default to one body paragraph, one blank line, then footer trailers (`Co-Authored-By:`, `Closes #N`, `Signed-off-by:`).
  - If multiple body paragraphs are necessary, keep trailers flush after the last paragraph with exactly one blank-line separator.
  - Do not leave extra blank lines between body paragraphs and trailers; commitlint can mis-split body/footer and fail even when the trailer is well-formed.
  - Do not start a body or bullet line with `Identifier:` (e.g. `- LookerDashboardEditJob: ...`); commitlint's parser reads a leading `token: value` as a footer trailer, mis-splits body/footer, and fails `footer-leading-blank`. Reword to prose (`- the LookerDashboardEditJob path ...`).

### 6. Show comparison and amend

If current message equals proposed message, output "Commit message already well-formed." and stop.

Use this amend operation after the applicable approval branch below:

```
git commit --amend -m "type(scope): subject"
```

For multi-line messages, use `-m "subject" -m "body paragraph"`.

When `is_pushed: true`, `--auto-accept` does not authorize the amend. Approval cannot be inherited from a caller flag or earlier workflow confirmation. Display the full current and proposed messages, rerun `git log -1 --format=%H`, and require its output to equal the captured `{full_sha}`. Set `{history_status}` to `pushed` when `push_state: pushed`, or `possibly pushed because remote freshness failed` when `push_state: unknown`. Then ask this exact approval question immediately before the amend:

```
question: "Approve amending {history_status} HEAD ({full_sha}) from exactly:\n{current full message}\n\nto exactly:\n{proposed full message}\n\nThis rewrites history and the next push must use --force-with-lease."
header: "Already-Pushed Amend"
options:
  - label: "Approve exact amend"          , description: "Amend this exact HEAD to this exact message"
  - label: "Skip"                         , description: "Keep the original message"
```

If "Skip", output "Keeping original message ({history_status} HEAD; aborted to avoid forced-push surprise)." and stop. If HEAD or the proposed message changes after approval, discard the approval and ask again with the new exact values. If "Approve exact amend", run the amend immediately with no intervening prompt or action, emit `WARN: HEAD was {history_status} before amend. Your next 'git push' must use --force-with-lease.`, and stop.

When `push_state: not-pushed` and `--auto-accept` is present, display the current vs proposed message, amend immediately, and stop.

Otherwise, display the comparison and confirm using AskUserQuestion:

```
question: "Current: {current subject}\nProposed: {proposed subject}"
header: "Amend Commit Message"
options:
  - label: "Yes - amend"   , description: "Rewrite the commit message"
  - label: "Edit"          , description: "Adjust the proposed message first"
  - label: "Skip"          , description: "Keep the original message"
```

After receiving the selection, act immediately: amend and stop on "Yes - amend", ask one focused follow-up and re-confirm on "Edit", or keep the original message and stop on "Skip".

Important:
- `--amend` preserves the original author and author date unless explicitly reset; the replacement commit gets a new committer timestamp
- This skill never pushes; the caller (or user) runs `git push --force-with-lease` after the amend

</workflow>

## Examples

<examples>

### Feature addition
**Original**: "update auth"
**Diff**: Added `DecodedToken` interface, typed `jwtDecode<DecodedToken>()` call, added `@types/jwt-decode`
**Improved**:
```
feat(auth): add typed JWT token decoding interface
```

### Bug fix
**Original**: "fix bug"
**Diff**: Added `if (null === null)` guard in `validateUserToken()` before `token.decode()`
**Improved**:
```
fix(auth): handle null tokens from expired sessions
```

</examples>

## Edge Cases

<error_handling>

- **Pushed or freshness unknown**: after the mandatory remote refresh, either a containing remote branch or a refresh failure sets `is_pushed: true`. Step 6 always requires exact immediate approval for the final HEAD and message, including in `--auto-accept` mode. Skill never pushes itself.
- **Merge commit**: Skip — do not amend
- **No parent** (initial commit): Use `git show HEAD --format="" --patch` (as in Step 3)
- **Multiple scopes**: Use the most significant scope; mention others in body
- **Config parse error**: Fall back to defaults with a warning

</error_handling>

## Config Priority

1. `.commitlintrc.json` in repo root
2. `.commitlintrc.js`, `.commitlintrc.yml`, `commitlint.config.js`, `commitlint.config.mjs`, `commitlint.config.cjs`, `commitlint.config.ts`
3. Standard conventional commits defaults
