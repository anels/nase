# Content-Hash Cache

Shared pattern for skipping reprocessing of unchanged content across skill invocations.

## Contents

- Cache File
- What is hashed
- Usage in Skills
- Skills Using This Pattern

## Cache File

Location: `workspace/tmp/.content-hashes`

Format (one entry per line):
```
<key>|<sha256>|<YYYY-MM-DD>
```

- **key**: one of three shapes, never anything else.
  - a fetched URL, verbatim
  - `source:<slug>` for a named feed or site that `/nase:tech-digest` fetches
  - `repo:<owner>/<repo>` for a repo that `/nase:onboard` scans
- **sha256**: 64-character lowercase hex digest. The bytes that go into it depend on
  the key shape, and *What is hashed* below is the one definition. A row that holds
  the literal `fetched-not-hashed` has no digest and never matches, so it always
  re-analyzes.
- **date**: when the content was last fully analyzed or accepted by the caller

## What is hashed

| Key shape | Bytes fed to `sha256` |
|---|---|
| URL, `source:<slug>` | the fetched response body, exactly as read, before any summarizing |
| `repo:<owner>/<repo>` | the output of `git -C {repo} rev-parse HEAD` plus its newline, followed by the working-tree `CLAUDE.md` bytes (nothing when the file is absent) |

The repo digest changes on a new commit and on an uncommitted `CLAUDE.md` edit. It does
not see other uncommitted files, so `--force` stays the way to rescan those.

Derive the repo key from the `origin` remote, keeping the last two path segments and
dropping `.git`, so `git@github.com:acme/widgets.git` and
`https://github.com/acme/widgets` are both `repo:acme/widgets`. A repo with no
`origin` uses `repo:<directory name>`. Never use the bare directory name when a remote
exists, because two owners can share a repo name. Rows written under an older shape
(`repo:widgets`, or a 40-character value that is a bare commit OID) never match a new
key, so the first run after the change is a full scan that writes the new row.

```bash
HEAD_OID=$(git -C "$REPO" rev-parse HEAD) || { echo "no HEAD; not caching" >&2; exit 1; }
HASH=$({ printf '%s\n' "$HEAD_OID"; cat "$REPO/CLAUDE.md" 2>/dev/null; } | shasum -a 256 | awk '{print $1}')
REMOTE=$(git -C "$REPO" remote get-url origin 2>/dev/null) \
  && KEY="repo:$(printf '%s' "${REMOTE%.git}" | sed -E 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')" \
  || KEY="repo:$(basename "$REPO")"
```

Store rows in `workspace/tmp/.content-hashes`. `tmp-prune.py` never deletes it.

## Usage in Skills

A key is a URL, `source:<slug>` or `repo:<owner>/<repo>`, so it carries `.`, `?`, `+` and `/`. Every lookup
below therefore compares the first `|`-separated field **literally** with `awk`.
Never match a key with `grep "^${KEY}|"`: `grep` reads the key as a regular
expression, where `.` matches any character, so one key can select another key's
row. A key containing a literal `|` cannot be stored at all; reject it rather than
writing a row that reads back as two fields.

### Writing a hash (after fetching)

```bash
# Compute hash of content (variable or file)
HASH=$(printf '%s' "$CONTENT" | shasum -a 256 | awk '{print $1}')
DATE=$(date +%Y-%m-%d)

CACHE="$WORKSPACE/workspace/tmp/.content-hashes"
mkdir -p "$(dirname "$CACHE")"
case "$KEY" in *"|"*) echo "refusing key containing |: $KEY" >&2; exit 1 ;; esac

# Drop this key's old row, then append the new one after analysis succeeds.
# The rewrite must not be `... || true`: that swallows a real failure (cache
# replaced by a directory, permission error, full disk) and the mv then publishes
# an empty file over the whole cache, losing every other key silently. Missing is
# the one tolerated case, so seed it and let any other failure stop the write.
[ -e "$CACHE" ] || : > "$CACHE"
awk -F'|' -v key="$KEY" '$1 != key' "$CACHE" > "$CACHE.tmp" || {
  echo "cache rewrite failed; leaving $CACHE untouched" >&2
  rm -f "$CACHE.tmp"
  exit 1
}
printf '%s|%s|%s\n' "$KEY" "$HASH" "$DATE" >> "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"
```

### Reading a hash (before fetching)

```bash
CACHE="$WORKSPACE/workspace/tmp/.content-hashes"
CACHED=$(awk -F'|' -v key="$KEY" '$1 == key' "$CACHE" 2>/dev/null | tail -1)
if [ -n "$CACHED" ]; then
  CACHED_HASH=$(printf '%s' "$CACHED" | cut -d'|' -f2)
  CACHED_DATE=$(printf '%s' "$CACHED" | cut -d'|' -f3)

  # Staleness is enforced here or nowhere. An entry past the window is re-analyzed
  # even when the hash still matches, so this comparison is not optional.
  AGE_DAYS=$(( ( $(date +%s) - $(date -j -f %Y-%m-%d "$CACHED_DATE" +%s 2>/dev/null \
    || date -d "$CACHED_DATE" +%s) ) / 86400 ))
  [ "$AGE_DAYS" -gt 30 ] && CACHED_STALE=1 || CACHED_STALE=0
fi
```

Skip re-analysis only when `CACHED_HASH` equals the freshly computed hash **and**
`CACHED_STALE` is `0`. A hash match with `CACHED_STALE=1` still re-analyzes once
and then refreshes the row's date.

### In Claude Code skills (non-bash)

Since skills run as Claude prompts (not bash scripts), prefer a targeted Bash lookup over reading the whole cache into context:

1. Run `awk -F'|' -v key="$KEY" '$1 == key' workspace/tmp/.content-hashes 2>/dev/null | tail -1`.
2. If found: fetch the content, compute the fresh hash via Bash, and compare.
3. If hash matches and the row's date is within 30 days: skip re-analysis, report
   "Content unchanged since {date}".
4. If hash matches but the row's date is older than 30 days, re-analyze once and
   refresh the cache.
5. If hash differs or key missing: proceed with full analysis, then update the cache via Bash.

Only read the full cache file when debugging cache corruption.

### Cache Invalidation

- Entries older than 30 days are considered stale - always re-analyze after fetching, even if the hash still matches. *Reading a hash* above is where this rule is enforced
- Skills may force-refresh by ignoring the cache (e.g., user passes `--force`)
- The cache file lives in `workspace/tmp/` and is excluded from backup

## Skills Using This Pattern

- `/nase:tech-digest` - fetches enough source content to hash, skips deep analysis for unchanged non-stale sources, and refreshes stale cache entries
- `/nase:onboard` - hashes the repo's `HEAD` OID plus `CLAUDE.md` (see *What is hashed*) to skip the full re-scan when unchanged
