# KB Staleness Detection

## Contents

- Inputs
- Step A: Last-active date per file (three tracks)
- Step B: Classify each file
- Step C: Orphan and gap scan
- Step D: Lesson promotion candidates
- Step D2: Low-value accretion candidates
- Step E: Temp and outdated artifact scan
- Output for the caller

> Shared algorithm for surfacing stale, orphaned, and outdated KB content. Referenced from `/nase:kb-review` under *Deep review -> Content and relationships* and `/nase:doctor --deep`. Edit here, not in the skills.

## Inputs

- The KB scope under review: `workspace/kb/general/`, `workspace/kb/projects/**/`, `workspace/kb/cross-project/`, `workspace/kb/ops/`, plus `workspace/tasks/lessons.md` and `workspace/kb/.domain-map.md`.
- Optional: a subset filter passed in as `$ARGUMENTS` from the caller.

## Step A - Last-active date per file (three tracks)

For each KB file, derive a `last_active` date from the entry date plus domain metadata, with file mtime as a metadata fallback:

1. **Track 1 — entry date**: scan the file for `### YYYY-MM-DD` headers. Take the maximum. If none found, the file has no dated entries — Track 1 is `null`.
2. **Track 2 - domain metadata**: read the mapped file's `last-updated:YYYY-MM-DD` from `workspace/kb/.domain-map.md`. Writers update this only after a durable content change. If missing or invalid, Track 2 is `null`.
3. **Track 3 - file mtime fallback**: run `stat -f %m <file>` (macOS) or `stat -c %Y <file>` (GNU). Convert the Unix epoch to `YYYY-MM-DD`. Use this only when Track 2 is null. If `stat` fails, Track 3 is `null` for that file.

`last_active = max(Track 1, Track 2 if present, otherwise Track 3)`. Record which track won (`source = "entry" | "domain-map" | "mtime-fallback"`).

### mtime poison detection

`mtime` is a best-effort fallback because `/nase:restore` resets every file's mtime to restore-time. Before using mtime fallbacks, check for the poison signature:

- Sort all mtimes ascending.
- If **more than 80% of files have mtimes within 60 seconds of each other**, mtime data is poisoned. Drop Track 3 entirely for this run and rely on entry dates plus domain metadata.

## Step B — Classify each file

Apply these thresholds against `last_active`:

| Tier | Threshold | Glyph | Meaning |
|---|---|---|---|
| Active | `<14 days` | 🟢 | Recent edits or entries |
| Aging | `14–30 days` | 🟡 | Worth a refresh look |
| Stale | `>30 days` | 🔴 | Likely diverged from current code |
| Unknown | `last_active is null` | ⚪ | No dated entry, domain metadata, or usable mtime |

Stale ≠ obsolete. **Historical records** (past incidents, architecture decisions dated to their event) should never be flagged. Only flag entries that describe *ongoing or current* work with old dates. Heuristics for "ongoing":
- Title or section mentions an active repo (cross-reference `workspace/context.md`).
- Body uses present tense and references things expected to be true today.
- Last entry is dated but recent code in the repo touches the same file/module (cheap check: `git log --since="<last_active>" --oneline -- <related-path>`).

## Step C — Orphan and gap scan

- **Orphaned files** — files under `workspace/kb/` that have no entry in `workspace/kb/.domain-map.md`. Report path and basename.
- **Empty/sparse** — files whose body (after stripping the header and frontmatter) is under 50 non-whitespace characters.
- **Domain map gaps** — entries in `.domain-map.md` pointing at files that don't exist.
- **Access staleness** - use `workspace/stats/kb-usage.jsonl` read events when available. A file with no read event in 60 days is a review candidate, not an automatic archive candidate. `resolve` and `search-result` events prove discovery only and must not be treated as reads. Missing telemetry means unknown, not unused.

## Step D — Lesson promotion candidates

For each entry in `workspace/tasks/lessons.md`:

1. Parse the header — format is `## <category> -- <YYYY-MM-DD> -- <topic>`.
2. Maturity threshold — promote if **any** of:
   - Date is older than 14 days.
   - The same pattern appears in two or more separate lesson entries (frequency = importance).
   - The entry body explicitly says "add to KB" or "promote".
3. Skip if the entry already carries a `> Promoted →` line — already moved.
4. Route by category:
   - `workflow` → `workspace/kb/general/workflow.md`
   - `debugging` → `workspace/kb/general/debugging.md`
   - `code` → `workspace/kb/general/<stack>.md` (e.g. `dotnet.md`) or the relevant project KB
   - `architecture` → `workspace/kb/general/system-design.md` or the relevant project KB
   - `ops` → `workspace/kb/ops/<env>.md`
   - `project` → `workspace/kb/projects/<repo>.md`

## Step D2 — Low-value accretion candidates

Project KB refreshes should reconcile current-state sections, not append dated
heartbeats. Scan project KBs for dated blocks or bullets made only of
git-recoverable, non-notable facts:

- `### YYYY-MM-DD — Refresh` sections that enumerate what the scan observed.
- "No new commits since X", "HEAD remains {sha}", "unchanged", or "no action
  needed" status notes.
- Commit-count or ownership-count drift that `git log` / `git shortlog`
  re-derives at use-time.
- Dependency bumps already visible in manifests or lockfiles.

This is distinct from stale content:

- **Stale** = once-true current-state content that now appears outdated.
- **Accretion** = never-notable snapshot content that should not have been
  persisted.

Do not flag genuine historical records such as incidents, architecture
decisions, release milestones, or human decisions dated to their event. For
each accretion candidate, report the file, heading or line, why the fact is
git-recoverable, any durable fact that should be folded into a current-state
section, and the recommended delete/compact action.

## Step E — Temp and outdated artifact scan

Scan `workspace/` for non-KB content that accumulated during daily work:

- **Temp artifacts** — files with extensions `.diff`, `.patch`, `.tmp`, `.bak`, `.orig` anywhere under `workspace/`. Also `*-pre-restore-*`, `*-snapshot-*`, `*.backup` patterns. Exclude `workspace/logs/*.log` (intentional).
- **Stale one-off files** — files in `workspace/` root (not in `kb/`, `logs/`, `tasks/`, `journals/`, `stats/`, `recaps/`, `skills/`, `scripts/`, `tmp/`, `efforts/`, `docs/`, `reports/`, `memory/`) older than 14 days.
- **Old reports** — files in `workspace/stats/report-*.md` older than 30 days (the latest report supersedes older ones).

## Output for the caller

The caller (skill) collects:

- A per-file table with `(path, topics, entries, last_active, source, tier)`.
- An orphans list, an empties list, a domain-map-gap list.
- A lesson promotion candidates list with proposed target paths.
- A low-value accretion candidates list with fold/delete recommendations.
- A temp/outdated artifacts list grouped by safe-to-delete vs review-first.

The caller decides what to do with these — write to a report file, prompt for action, or both. This doc only defines *what* "stale" means; the *what next* is the skill's job.
