# KB Staleness Detection

> Shared algorithm for surfacing stale, orphaned, and outdated KB content. Referenced from `/nase:kb-review` (Steps 1, 4, 4b) and `/nase:doctor --deep`. Edit here, not in the skills.

## Inputs

- The KB scope under review: `workspace/kb/general/`, `workspace/kb/projects/**/`, `workspace/kb/cross-project/`, `workspace/kb/ops/`, plus `workspace/tasks/lessons.md` and `workspace/kb/.domain-map.md`.
- Optional: a subset filter passed in as `$ARGUMENTS` from the caller.

## Step A — Last-active date per file (dual track)

For each KB file, derive a `last_active` date using **the more recent** of two tracks:

1. **Track 1 — entry date**: scan the file for `### YYYY-MM-DD` headers. Take the maximum. If none found, the file has no dated entries — Track 1 is `null`.
2. **Track 2 — file mtime**: run `stat -f %m <file>` (macOS) or `stat -c %Y <file>` (GNU). Convert the Unix epoch to `YYYY-MM-DD`. If `stat` fails (broken symlink, permission denied), Track 2 is `null` for that file.

`last_active = max(Track 1, Track 2)`. Record which track won (`source = "entry" | "mtime"`).

### mtime poison detection

`mtime` is a best-effort signal because `/nase:restore` resets every file's mtime to restore-time. Before using mtimes, check for the poison signature:

- Sort all mtimes ascending.
- If **more than 80% of files have mtimes within 60 seconds of each other**, mtime data is poisoned. Drop Track 2 entirely for this run and rely solely on Track 1 entry dates.

## Step B — Classify each file

Apply these thresholds against `last_active`:

| Tier | Threshold | Glyph | Meaning |
|---|---|---|---|
| Active | `<14 days` | 🟢 | Recent edits or entries |
| Aging | `14–30 days` | 🟡 | Worth a refresh look |
| Stale | `>30 days` | 🔴 | Likely diverged from current code |
| Unknown | `last_active is null` | ⚪ | No entries and no mtime — empty or never written |

Stale ≠ obsolete. **Historical records** (past incidents, architecture decisions dated to their event) should never be flagged. Only flag entries that describe *ongoing or current* work with old dates. Heuristics for "ongoing":
- Title or section mentions an active repo (cross-reference `workspace/context.md`).
- Body uses present tense and references things expected to be true today.
- Last entry is dated but recent code in the repo touches the same file/module (cheap check: `git log --since="<last_active>" --oneline -- <related-path>`).

## Step C — Orphan and gap scan

- **Orphaned files** — files under `workspace/kb/` that have no entry in `workspace/kb/.domain-map.md`. Report path and basename.
- **Empty/sparse** — files whose body (after stripping the header and frontmatter) is under 50 non-whitespace characters.
- **Domain map gaps** — entries in `.domain-map.md` pointing at files that don't exist.
- **Last-loaded staleness** — when `.domain-map.md` entries carry `last-loaded:YYYY-MM-DD` (see header convention in `.domain-map.md`), flag any file whose `last-loaded` is older than 60 days as a candidate for archival or removal.

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
