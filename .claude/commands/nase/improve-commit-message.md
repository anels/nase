Analyze the last commit and rewrite its message following conventional commits / commitlint rules. Always invoke before git push — it's the second step in the standard commit sequence: /simplify → /improve-commit-message → git push.
Good commit messages are searchable documentation. When someone runs `git log --oneline` six months from now, each line should tell them what changed and why — without opening the diff.

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
git branch -r --contains HEAD 2>/dev/null    # check if pushed
git log -1 --format="%P" | tr ' ' '\n' | wc -l  # parent count (merge check)
```

</parallel>

- If merge commit (>1 parent): abort — do not amend merge commits.
- If already pushed to remote: warn the user that amending will require `--force-with-lease`.

### 3. Analyze changes (diff-first strategy)

```
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
- **Summary line MUST be under 80 characters.** GitHub PR titles, `git log --oneline`, and terminal UIs truncate beyond this. Overflow detail belongs in the commit body.
- Commitlint `header-max-length` is the hard validation limit (default 72; projects may set higher). 80 is the display/readability target — never exceed it even if config allows more.
- Imperative mood: "add" not "added"
- No period at end (unless `subject-full-stop` allows it)
- Respect project's `subject-case` rule
- Be specific about *what* changed; put *why* in the body if needed
- If the change is too broad for 80 chars, pick the most impactful change for the summary and list the rest in the body

### 6. Show comparison and amend

Display the current vs proposed message, then confirm using AskUserQuestion:
```
question: "Current: {current subject}\nProposed: {proposed subject}"
header: "Amend Commit Message"
options:
  - label: "Yes — amend"   , description: "Rewrite the commit message"
  - label: "Edit"           , description: "Adjust the proposed message first"
  - label: "Skip"           , description: "Keep the original message"
```
- **Yes**: proceed to amend
- **Edit**: ask what to change, re-propose, then re-confirm
- **Skip**: stop, no changes

Amend:
```
git commit --amend -m "type(scope): subject"
```

Important:
- `--amend` preserves original author and timestamp automatically
- Do NOT add co-author or Claude attribution
- For multi-line messages, use `-m "subject" -m "body paragraph"`

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

- **Already pushed**: Warn user about `--force-with-lease` requirement
- **Merge commit**: Skip — do not amend
- **No parent** (initial commit): Use `git diff --cached` instead of `HEAD^ HEAD`
- **Multiple scopes**: Use the most significant scope; mention others in body
- **Config parse error**: Fall back to defaults with a warning

</error_handling>

## Config Priority

1. `.commitlintrc.json` in repo root
2. `.commitlintrc.js`, `.commitlintrc.yml`, `commitlint.config.js`
3. Standard conventional commits defaults
