Generate or update `CHANGELOG.md` by analyzing actual code changes between two git refs, with GitHub commit/PR links. Use when preparing a release, after cherry-picking hotfixes, or when asked "what changed in this version?". Resolves cherry-picks to their original PRs for accurate traceability.

<investigate_before_acting>
Always verify git state (current branch, remote refs, commit history) before taking action.
Never assume repository state — check it with git commands first.
</investigate_before_acting>

## Purpose

Generates or updates `CHANGELOG.md` by analyzing **actual code changes** between two git refs. This is a standalone changelog tool — it does NOT create branches or cut releases.

Key capabilities:
- Analyzes real code diffs (not just commit messages) to produce meaningful entries
- Auto-detects base/head refs from release branches when not specified
- Includes GitHub commit hyperlinks and PR links in entries
- **Resolves cherry-pick commits** to their original PRs/commits for accurate traceability
- Supports any versioning scheme (sprint `S189`, semver `v1.2.3`, date-based `v2024.10.9`, etc.)

The changelog is a user-facing document — it answers "what changed in this release?" for developers, PMs, and support teams. Code-level accuracy matters because commit messages alone are often cryptic or misleading.

## Argument Parsing

**Input:** $ARGUMENTS — `[version] [from <base-ref>] [to <head-ref>]`

Parse the user's input to extract:

- **version** (optional): The version label for the changelog entry header
  - Accept any format: `v2024.10.9`, `release/v2024.10.9`, `S189`, `1.2.3`, etc.
  - If prefixed with `release/`, strip it for the display label but use it as ref hint
  - If not provided, try to infer from the current branch name or `head_ref`

- **base_ref** (optional): The older ref to compare from
  - Extracted from `from <ref>` in the argument
  - If not provided, auto-detect (see Step 2)

- **head_ref** (optional): The newer ref to compare to
  - Extracted from `to <ref>` in the argument
  - If not provided, default to the current branch or `HEAD`

Examples:
- `/nase:update-changelog` → auto-detect everything from current branch context
- `/nase:update-changelog v2024.10.9` → version=`v2024.10.9`, auto-detect refs
- `/nase:update-changelog v2024.10.9 from release/v2024.10.8` → explicit base, head=current branch
- `/nase:update-changelog v2024.10.9 from release/v2024.10.8 to release/v2024.10.9` → all explicit

If nothing can be inferred, ask the user:
```
What version label should this changelog entry use? (e.g. v2024.10.9, S189)
What are the two refs to compare? (e.g. from release/v2024.10.8 to release/v2024.10.9)
```

## Workflow

<workflow>

### Step 1: Pre-flight & GitHub URL Detection

```bash
# Must be inside a git repo
git rev-parse --git-dir 2>/dev/null || { echo "Not inside a git repository"; exit 1; }
```

<parallel>

- `git fetch origin 2>/dev/null` — fetch remote refs (fall back to local if unreachable)
- `git remote get-url origin` — detect GitHub remote URL for hyperlinks

</parallel>

Parse the output to derive `github_base_url`:
- HTTPS: `https://github.com/org/repo.git` → `https://github.com/org/repo`
- HTTPS with user: `https://user@github.com/org/repo.git` → `https://github.com/org/repo`
- SSH: `git@github.com:org/repo.git` → `https://github.com/org/repo`

Derive:
- `github_commit_url` = `{github_base_url}/commit`
- `github_pr_url` = `{github_base_url}/pull`

If remote is not `github.com`, set both to empty and fall back to plain text.

### Step 2: Auto-Detect Refs (if not provided)

#### Detecting head_ref
If `head_ref` is not provided:
1. Use the current branch: `git branch --show-current`
2. If detached HEAD, use `HEAD`

#### Detecting base_ref
If `base_ref` is not provided, use smart detection based on the head_ref pattern:

**For `release/vYYYY.MM.PATCH` pattern** (date-based versioning):
```
git branch -r --list 'origin/release/v*' \
  | sed 's|.*origin/||' \
  | sort -t. -k1,1 -k2,2n -k3,3n \
  | grep -B1 '<head_version>' \
  | head -1
```

**For `release/S<N>` pattern** (sprint-based):
```
git branch -r --list 'origin/release/S*' \
  | grep -E 'origin/release/S[0-9]+$' \
  | sed 's|.*origin/release/S||' \
  | sort -n \
  | awk -v n=<N> '$1 < n' \
  | tail -1
```

**For semver `vX.Y.Z` tags**:
```bash
git tag --sort=-version:refname | grep -E '^v[0-9]' | head -5
```
Pick the tag immediately before the target version.

**Fallback**: List the 10 most recent release branches and ask the user to pick one.

#### Validate refs
```
git rev-parse --verify "origin/<ref>" 2>/dev/null
git rev-parse --verify "<ref>" 2>/dev/null
```

Show the user what was detected:
```
Changelog comparison:
  Base : release/v2024.10.8
  Head : release/v2024.10.9
  Label: v2024.10.9
```

### Step 3: Build Commit & File Map (with Cherry-Pick Resolution)

```
git log --pretty=format:"COMMIT:%h%nSUBJECT:%s%nBODY_START%n%b%nBODY_END" --name-only <base_ref>..<head_ref>
```

If using remote refs, prefix with `origin/`.

Parse this output to build:
- `file_list` — all unique files changed
- `commit_map` — `{ file_path → [{sha, message}, ...] }`

#### 3a. Extract PR numbers from commit messages

- Pattern: `(#\d+)` in commit subject → maps to `github_pr_url/<number>`
- Pattern: `Merge pull request #\d+` → extract PR number

#### 3b. Detect and resolve cherry-pick commits

**Detection patterns** (check in order):

1. **Title pattern — `Cherry-Pick:` prefix**
   ```
   Cherry-Pick: fix(deps): upgrade packages (#4153) -> release/v2024.10.9 (#4156)
   ```
   Regex: `^Cherry-Pick:\s*(.+?)\s*\(#(\d+)\)\s*->\s*.+?\s*\(#(\d+)\)$`

2. **Title pattern — `[cherry-pick → ...]` suffix**
   ```
   build(clientapp): migrate to pnpm [cherry-pick → release/v2024.10.9] (#4161)
   ```
   Regex: `^(.+?)\s*\[cherry-pick\s*→\s*.+?\]\s*\(#(\d+)\)$`

3. **Body pattern — `(cherry picked from commit <SHA>)`**
   ```
   git log --format="%h %s" <original_sha> -1
   ```

Build `cherry_pick_map` — `{ cherry_sha → { original_pr, original_sha, original_subject } }`

**Resolution priority** for each commit:
1. If `cherry_pick_map[sha]` exists → use `original_pr` from the map
2. Else if `pr_map` has a PR number → use it directly
3. Else → fall back to commit SHA link

#### 3c. Cross-reference base branch changelog

```
git show origin/<base_ref>:CHANGELOG.md 2>/dev/null
```

If it exists, parse the latest entry, extract PR references, find any not already in `commit_map`, and recover those commits from the head branch. Report findings:
```
Cross-referenced base changelog (<base_ref>):
  PRs in base changelog: <N>
  Already in diff:        <M>
  Recovered:              <K>
```

### Step 4: Classify Files by Area

| Signal | Area label |
|---|---|
| `*.test.*`, `*.spec.*`, `test/`, `tests/`, `__tests__/`, `Tests/` | Tests |
| `*.md`, `docs/`, `documentation/` | Documentation |
| `package.json`, `*.csproj`, `*.toml`, `requirements.txt`, `go.mod` | Dependencies |
| `.github/`, `*.yml` CI, `Dockerfile`, `.pipelines/` | Build & CI |
| Paths with `controller`, `handler`, `router`, `endpoint`, `api/` | API / Endpoints |
| Paths with `service`, `provider`, `client` (non-test) | Services |
| Paths with `model`, `schema`, `migration`, `repository`, `db/` | Data Layer |
| Paths with `view`, `component`, `page`, `ui/`, `frontend/` | Frontend |
| Paths with `auth`, `permission`, `access`, `security` | Permissions / Auth |
| Everything else | `<top-level dir name>` |

### Step 5: Analyze Code Changes (Staged Depth)

<parallel>

For each area, get a size estimate:
```
git diff --stat <base_ref>..<head_ref> -- <area_path_pattern>
```

**Depth rules:**
- **1–5 files**: Full diff with `-U3` context
- **6–20 files**: Full diff with `-U2` context
- **20+ files**: `--stat` only; selectively read the 3–5 most impactful files

</parallel>

**Read priority order** (highest to lowest user impact):
1. API / Controllers / Handlers
2. Frontend / UI / Pages
3. Data Layer / Models / Migrations
4. Services / Business Logic
5. Configuration / Init scripts
6. Dependencies (scan for version bumps)
7. Build & CI (brief)
8. Tests (only if significant new coverage)

### Step 6: Generate Categorized Changelog

| What the code change does | Changelog section |
|---|---|
| New feature, UI, API endpoint, user-visible behavior | ✨ Features |
| Fixed incorrect behavior, crash, wrong output | 🐛 Bug Fixes |
| Faster queries, reduced memory, better throughput | ⚡ Performance |
| Input validation, auth check, secrets handling | 🔒 Security |
| Internal restructure with no behavioral change | ♻️ Refactoring |
| New or upgraded dependency | 📦 Dependencies |
| Pipeline, build, tooling changes | 🔧 Build & CI |
| New or improved test coverage | 🧪 Tests |

**Writing rules:**
- Describe **what the user or developer gains**, not what lines changed
- Use present tense and active voice; be specific about component/service names
- Multi-file changes for one feature → ONE entry
- Omit pure internal refactors unless they affect API or performance
- Cherry-pick resolution: always link to the **original** PR, not the cherry-pick PR

**Output format** (Keep a Changelog style):

```markdown
## [v2024.10.9] - YYYY-MM-DD

> Compared: `release/v2024.10.8` → `release/v2024.10.9`
> Files changed: 42 | Commits: 15

### ✨ Features
- Add retry logic for Looker API initialization with configurable backoff ([#546](url/546))

### 🐛 Bug Fixes
- Fix admin settings applying in parallel causing race conditions ([#532](url/532))

### 🔧 Build & CI
- Update Docker image signing to run as final pipeline step ([#543](url/543))
```

If a category has no changes, omit that section.

### Step 7: Write to CHANGELOG.md

Read current `CHANGELOG.md` (if it exists).

**If it does NOT exist**, create it with a standard header, then prepend the new entry.

**If it DOES exist**:
- Check if an entry for the same version already exists
  - If yes, confirm using AskUserQuestion:
    ```
    question: "An entry for [version] already exists in CHANGELOG.md."
    header: "Duplicate Changelog Entry"
    options:
      - label: "Replace"  , description: "Overwrite the existing entry with the new one"
      - label: "Append"    , description: "Add as a separate entry above the existing one"
      - label: "Cancel"    , description: "Do not write anything"
    ```
- Prepend the new entry after the header/intro but before the first existing `## [...]` section

### Step 8: Commit and Deliver

#### 8-pre. Detect commit mode

```bash
current_branch=$(git branch --show-current)
remote_exists=$(git ls-remote --heads origin "$current_branch" 2>/dev/null | wc -l)
```

**Direct commit mode** — when current branch is NOT `develop`/`main`/`master` AND does not exist on remote yet (e.g., invoked by `/cut-release` on a fresh local branch):
```
git add CHANGELOG.md
git commit -m "docs: update changelog for <version>"
```
Then stop — do not create a side branch or PR.

**Side-branch + PR mode** (default for protected/pushed branches):

#### 8a. Determine the target branch

Typically `head_ref` if it's a release branch, otherwise the current branch.

#### 8b. Create a new branch

```
git checkout -b docs/changelog-<version> origin/<target_branch>
```

#### 8c. Commit the changelog

```
git add CHANGELOG.md
git commit -m "docs: update changelog for <version>"
```

#### 8d. Push and open a PR

Ask the user: "Push and open a PR to merge the changelog into `<target_branch>`? (yes/no)"

If yes:
1. Run `/nase:improve-commit-message` to review the commit message
2. Push: `git push -u origin docs/changelog-<version>`
3. Open a PR with `gh pr create`

#### 8e. Return to the original branch

```
git checkout <original_branch>
```

### Step 9: Summary

```
╔═══════════════════════════════════════════════════════╗
║           Changelog Update Summary                    ║
╠═══════════════════════════════════════════════════════╣
║  Version  : v2024.10.9                                ║
║  Compared : release/v2024.10.8 → release/v2024.10.9   ║
║  Commits  : 15                                        ║
║  Entries  : 8 (3 features, 2 fixes, ...)              ║
║  File     : CHANGELOG.md (updated)                    ║
║  Branch   : docs/changelog-v2024.10.9                 ║
║  PR       : #123 → release/v2024.10.9                 ║
╚═══════════════════════════════════════════════════════╝
```

</workflow>

## Error Handling

<error_handling>

- **Empty diff**: note "No code changes in this release" in the entry
- **Invalid ref**: list available release branches and ask the user to pick
- **Duplicate entry**: ask before overwriting

</error_handling>

## Notes

- **Can be invoked by other skills** — uses direct commit mode on unpushed, non-protected branches
- **In standalone mode**, never commits directly to `develop`, `main`, `master`, or `release/*` — creates a `docs/changelog-<version>` branch and opens a PR
- **Cherry-pick aware**: resolves three patterns to original PRs so the changelog links to the original code review
- **Base changelog cross-reference**: recovers commits independently cherry-picked to both branches that `git log base..head` would miss
- Changelog quality comes from **code analysis**, not commit message discipline
