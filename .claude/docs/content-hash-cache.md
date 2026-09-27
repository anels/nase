# Content-Hash Cache

Shared pattern for skipping reprocessing of unchanged content across skill invocations.

## Cache File

Location: `workspace/tmp/.content-hashes`

Format (one entry per line):
```
<key>|<sha256>|<YYYY-MM-DD>
```

- **key**: URL or `repo:<repo-name>` identifier
- **sha256**: hex digest of the fetched/read content
- **date**: when the content was last fully analyzed or accepted by the caller

## Usage in Skills

A key is a URL or `repo:<name>`, so it carries `.`, `?`, `+` and `/`. Every lookup
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
- `/nase:onboard` - caches repo CLAUDE.md + key file hashes to skip full re-scan when unchanged
