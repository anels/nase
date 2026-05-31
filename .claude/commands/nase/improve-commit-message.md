---
name: nase:improve-commit-message
description: Analyze the last commit and rewrite its message following conventional commits / commitlint rules. Always invoke before git push — part of the standard commit sequence. Use when asked to "improve commit", "fix commit message", "amend commit", "clean up commit", "before push", or after committing code. Also invoked automatically by /nase:fsd and /nase:prep-merge.
---

Good commit messages are searchable documentation. When someone runs `git log --oneline` six months from now, each line should tell them what changed and why — without opening the diff.

**Input:** $ARGUMENTS — optional flags (see below)

## Step 0 — Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Use `conversation:` for chat and prompts; use `output:` for the rewritten commit message.

## Flags

- `--auto-accept` — skip the confirmation prompt and amend immediately with the proposed message. Use this when called from automated workflows (e.g., `/nase:fsd`) that should not pause for user input. If the current message is already well-formed and the proposed message is identical, skip the amend entirely.

<investigate_before_acting>
Always verify git state (current branch, remote refs, commit history) before taking action.
Never assume repository state — check it with git commands first.
</investigate_before_acting>

## Steps

<workflow>

### 1. Detect commitlint config

Use Glob to find config files (`.commitlintrc.json`, `.commitlintrc.js`, `.commitlintrc.yml`, `commitlint.config.js`) in the repo root.
If a JSON config exists, use Read to parse it directly — extract:
- `header-max-length` (validation limit; display target is always **80 chars**)
- `type-enum` (allowed types)
- `subject-case` (0 = disabled, 2 = enforced)
- `subject-full-stop`

If no config found, use defaults: max 72, lowercase, no period, standard types.

### 2. Get commit info + check safety

<parallel>

```
git log -1 --format="%H%n%s%n%n%b"          # hash, subject, body
git branch -r --contains HEAD 2>/dev/null    # check if pushed (any remote contains HEAD)
git log -1 --format="%P" | tr ' ' '\n' | wc -l  # parent count (merge check)
```

</parallel>

- If merge commit (>1 parent): abort — do not amend merge commits.
- Compute `IS_PUSHED`: true when the second command output is non-empty (at least one remote branch contains HEAD). This determines the Step 6 branch.

### 3. Analyze changes (diff-first strategy)

**Get the diff** (handle initial commits):
1. Check parent count: `git rev-list --count HEAD`
2. If count is 1 (initial commit): `git show HEAD --format="" --patch`
3. Otherwise: `git diff -U5 HEAD^ HEAD`

```
# Normal case:
git diff -U5 HEAD^ HEAD
```

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

### 6. Show comparison and amend

**If `--auto-accept` flag is present in $ARGUMENTS:**
- If current message equals proposed message: output "Commit message already well-formed." and stop.
- Otherwise: display the current vs proposed message for visibility, then amend immediately — no confirmation prompt.
- When `IS_PUSHED=true`: amend still proceeds in `--auto-accept` mode, but emit a loud final line: `WARN: HEAD already pushed — your next 'git push' must use --force-with-lease, otherwise the remote will reject the rewritten history.` The caller (`/nase:fsd`, `/nase:prep-merge`) is expected to surface this to the user.

**Otherwise (interactive mode, default):**

When `IS_PUSHED=true`, the "Yes — amend" path is destructive on shared history. Add a single distinct AskUserQuestion BEFORE the regular confirmation:

```
question: "HEAD ({short_sha}) is already on a remote branch. Amending rewrites history — your next push must use --force-with-lease. Proceed?"
header: "Already-Pushed Amend"
options:
  - label: "Proceed with amend"          , description: "I understand the next push needs --force-with-lease"
  - label: "Skip"                         , description: "Keep the original message"
```

If "Skip": output "Keeping original message (HEAD pushed; aborted to avoid forced-push surprise)." and stop.
If "Proceed with amend": fall through to the regular confirmation below.

Then display the current vs proposed message, confirm using AskUserQuestion:
```
question: "Current: {current subject}\nProposed: {proposed subject}"
header: "Amend Commit Message"
options:
  - label: "Yes — amend"   , description: "Rewrite the commit message"
  - label: "Edit"           , description: "Adjust the proposed message first"
  - label: "Skip"           , description: "Keep the original message"
```

**After receiving the selection, immediately act on it — do not wait for further user input:**
- **Yes — amend**: run `git commit --amend` immediately
- **Edit**: ask a single follow-up question about what to change, then re-propose and re-confirm
- **Skip**: output "Keeping original message." and stop

Amend:
```
git commit --amend -m "type(scope): subject"
```

After the amend completes, if `IS_PUSHED=true`, emit the final line:
```
WARN: HEAD was already pushed before amend. Your next 'git push' must use --force-with-lease.
```

Important:
- `--amend` preserves original author and timestamp automatically
- For multi-line messages, use `-m "subject" -m "body paragraph"`
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

- **Already pushed**: detected via `git branch -r --contains HEAD` in Step 2 → `IS_PUSHED=true`. Step 6 branches on this: interactive mode adds a distinct pre-confirmation prompt; auto-accept mode proceeds but emits a `WARN:` line so the caller surfaces the `--force-with-lease` requirement. Skill never pushes itself.
- **Merge commit**: Skip — do not amend
- **No parent** (initial commit): Use `git show HEAD --format="" --patch` (as in Step 3)
- **Multiple scopes**: Use the most significant scope; mention others in body
- **Config parse error**: Fall back to defaults with a warning

</error_handling>

## Config Priority

1. `.commitlintrc.json` in repo root
2. `.commitlintrc.js`, `.commitlintrc.yml`, `commitlint.config.js`
3. Standard conventional commits defaults
