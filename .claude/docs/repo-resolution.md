# Repo Resolution & KB Loading — Shared Reference

Canonical algorithms used across nase skills. Skills with skill-specific deviations (e.g., onboard's batch mode) keep that logic inline and reference only the shared portions.

---

## Part 1: Repo Resolution

Resolve a GitHub URL or repo name to a local filesystem path via `workspace/context.md`.

### Algorithm

1. **If input is a GitHub URL** (starts with `https://github.com/` or `git@github.com:`):
   - Extract repo name: take the last path segment, strip `.git` suffix.
     - Example: `https://github.com/Org/MyRepo` → `MyRepo`
     - Example: `git@github.com:Org/MyRepo.git` → `MyRepo`
   - Read `workspace/context.md`. Search for a repo path whose last path component matches the extracted name (case-insensitive; treat both `/` and `\` as separators).
   - If found: use that local path for all subsequent steps. Print: `Resolved {url} → {path}`
   - If not found: output "GitHub URL provided but no local path found for `{name}` in `workspace/context.md`. Please provide the local path directly, or add it to context.md first." — stop.

2. **If input is a local path**: use it directly.

---

## Part 2: KB File Loading

Load the right KB file for a repo.

### Algorithm

1. Derive the domain key from the repo name: lowercase, hyphen-separated (e.g. `MyRepo` → `my-repo`, `insights-monitoring` → `insights-monitoring`).
2. Read `workspace/kb/.domain-map.md`. Each line has format `- {domain} → {path}`. Find the line whose domain key matches.
3. If found: read that KB file. Focus on the **Build & Run Commands** and **Architecture** sections.
4. If not found: warn "No KB file for `{domain}`. Consider running `/nase:onboard {repo-path}` first." — proceed without KB context.
