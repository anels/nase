# Repo Resolution & KB Loading — Shared Reference

Canonical algorithms used across nase skills. Skills with skill-specific deviations (e.g., onboard's batch mode) keep that logic inline and reference only the shared portions.

## Contents

- [Part 1: Repo Resolution](#part-1-repo-resolution) - resolve a URL or repo name to a local path
- [Part 2: KB File Loading](#part-2-kb-file-loading) - resolve a repo or domain to its KB file
- [Retired entries](#retired-entries) - the `retired:` field and what stops acting on the entry
- [Project groups](#project-groups) - the `### <group>` routing label under `## Projects`

---

## Part 1: Repo Resolution

Resolve a GitHub URL or repo name to a local filesystem path via `.local-paths`.

### Algorithm

1. **If input is a GitHub URL** (starts with `https://github.com/` or `git@github.com:`):
   - Extract repo name: take the last path segment, strip `.git` suffix.
     - Example: `https://github.com/Org/MyRepo` → `MyRepo`
     - Example: `git@github.com:Org/MyRepo.git` → `MyRepo`
   - **Check the retired marker first** (see Part 2). If the repo's domain-map entry carries `retired:`, stop here: report the
     entry's retirement date and KB path, and do not prompt for a local path. A retired repo has no working clone to resolve,
     so asking for one produces a wrong answer rather than no answer. Proceed only if the caller explicitly overrides.
   - Read `.local-paths` at the workspace root. Search for a line matching `{RepoName}={path}` (case-sensitive key match).
   - If found: use that local path for all subsequent steps. Print: `Resolved {url} → {path}`
   - If not found: use AskUserQuestion to ask the user for the local path. Once provided, append `{RepoName}={path}` to `.local-paths`. Then use that path for all subsequent steps.

2. **If input is a local path**: use it directly.

---

## Part 2: KB File Loading

Load the right KB file for a repo.

### Algorithm

Use the script for deterministic resolution:

```bash
KB_FILE=$(bash .claude/scripts/kb-domain-resolve.sh "<repo-name-or-domain>")
```

The script normalises the name to a domain key (lowercase, hyphens), looks up `workspace/kb/.domain-map.md`, and returns the file path.
- Exit 0 + path on stdout: read that KB file; focus on the sections relevant to the task. Use KB claims as durable context and navigation. Verify actionable commands, IDs, owners, configuration, and current behavior against the repo or external source of truth before mutation.
- Exit 1 + error on stderr: script not found OR domain not in map → warn and proceed without KB context.

For a task scoped to concrete source/config paths, also run:

```bash
bash .claude/scripts/kb-search.sh mentions:<path> --max-entry-lines 8
```

Carry returned constraints into the workflow. A missing hit means no indexed KB
constraint was found; it does not prove the path has no operational constraint.

If the script is unavailable, fall back to manual lookup:
1. Derive domain key: lowercase, hyphen-separated (e.g. `MyRepo` → `my-repo`).
2. Grep `.domain-map.md` for `- {domain} →`. Extract path (stop before any parenthetical description).
3. If not found: warn "No KB file for `{domain}`. Consider running `/nase:onboard {repo-path}` first."

### Retired entries

A domain-map entry may carry a `[retired:YYYY-MM-DD]` field alongside `[last-updated:YYYY-MM-DD]`:

```
- preen → workspace/kb/projects/preen.md [last-updated:2026-08-25] [retired:2026-08-25] (notes)
```

`retired:` means the upstream repo or domain no longer exists as a live target - archived on the host, deleted, or
permanently discontinued - and the KB file is kept as a historical record. The date is when it was retired, not when the
KB file was last touched.

Rules:

- The KB file stays readable and stays mapped. `kb-domain-resolve.sh` keeps returning its path, and reads of it are normal.
  Retirement changes what writers and freshness checks do, never what readers can see.
- **Refresh writers skip it.** `/nase:onboard` excludes retired entries from batch refresh, and single-repo resolution stops
  before prompting for a local path (Part 1).
- **Freshness checks exempt it.** `.claude/docs/kb-staleness.md -> Step B` classifies retired entries as `Retired` instead of
  aging them, because a KB file for a repo with no current code cannot diverge from current code.
- Both fields are positioned after the KB path, so the existing parsers keep working unchanged: `kb-domain-resolve.sh` takes
  the first whitespace-delimited token after `→`, and `kb-hygiene-scan.py -> domain_map_targets` reads only the path.
- Retiring is not deleting. Remove a KB file only when its content is wrong or duplicated, never merely because the repo went away.

### Project groups

Entries under `## Projects` are filed beneath a `### <group>` heading:

```
## Projects

### <group-a>
- <key> → workspace/kb/projects/<key>.md [last-updated:YYYY-MM-DD] (notes)
- <key-2> → workspace/kb/projects/<key-2>.md [last-updated:YYYY-MM-DD] (notes)

### <group-b>
- <key-3> → workspace/kb/projects/<key-3>.md [last-updated:YYYY-MM-DD] (notes)
```

The group is a **routing label, not a location**. The KB file's path on disk never changes, so every existing reference
to `workspace/kb/projects/<name>.md` keeps resolving - including the ones in `workspace/logs/`, `workspace/journals/`,
and `workspace/recaps/`, which are historical records and must not be rewritten to chase a directory move.

Rules:

- **Every entry belongs to exactly one group.** An entry with no `### ` heading above it, or a key listed under two
  headings, is a map defect - `/nase:kb-review` reports it rather than guessing.
- **Groups are for routing and reading, not for access control.** `kb-domain-resolve.sh` resolves a key regardless of
  its group; nothing needs to know the group to read a KB file.
- **Derived entries follow their subject.** A `<key>-tech-debt`, `<key>-decisions`, or `<key>-<contract>` entry sits in the
  same group as `<key>`, even though its file lives under `tech-debt/`, `decisions/`, or `contracts/`. The on-disk
  subdirectory splits by artifact type; the group splits by subject. They are different axes and neither replaces the other.
- Adding or renaming a group is a deliberate edit to this section plus the map. Do not invent a group inline.
