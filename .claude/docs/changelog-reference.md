# Changelog Reference — Cherry-Pick Patterns & File Classification

Read this file when executing `/nase:update-changelog` Step 3b (cherry-pick resolution) or Step 4 (file classification).

---

## Cherry-Pick Detection Patterns

Check in order 1→2→3; stop at the **first match** for each commit. Do not apply multiple patterns to the same commit.

### Pattern 1: `Cherry-Pick:` prefix

```
Cherry-Pick: fix(deps): upgrade packages (#4153) -> release/v2024.10.9 (#4156)
```

Regex: `^Cherry-Pick:\s*(.+?)\s*\(#(\d+)\)\s*->\s*.+?\s*\(#(\d+)\)$`

- Group 1: original subject
- Group 2: original PR number
- Group 3: cherry-pick PR number

### Pattern 2: `[cherry-pick → ...]` suffix

```
build(clientapp): migrate to pnpm [cherry-pick → release/v2024.10.9] (#4161)
```

Regex: `^(.+?)\s*\[cherry-pick\s*→\s*.+?\]\s*\(#(\d+)\)$`

- Group 1: original subject
- Group 2: cherry-pick PR number

### Pattern 3: Body `(cherry picked from commit <SHA>)`

Found in the commit body. Resolve the original commit:
```bash
git log --format="%h %s" <original_sha> -1
```

### Resolution Priority

For each commit:
1. If `cherry_pick_map[sha]` exists → use `original_pr`
2. Else if the commit message contains a PR number (from Step 3a `commit_map`) → use it directly
3. Else → fall back to commit SHA link

---

## File Classification Table

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

---

## Changelog Section Mapping

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

### Writing Rules

- Describe **what the user or developer gains**, not what lines changed
- Use present tense and active voice; be specific about component/service names
- Multi-file changes for one feature → ONE entry
- Omit pure internal refactors unless they affect API or performance
- Cherry-pick resolution: always link to the **original** PR, not the cherry-pick PR
