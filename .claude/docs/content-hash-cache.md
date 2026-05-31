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

### Writing a hash (after fetching)

```bash
# Compute hash of content (variable or file)
HASH=$(echo -n "$CONTENT" | shasum -a 256 | awk '{print $1}')
DATE=$(date +%Y-%m-%d)

# Remove old entry for this key (if any), then append new one after analysis succeeds
CACHE="$WORKSPACE/workspace/tmp/.content-hashes"
mkdir -p "$(dirname "$CACHE")"
grep -v "^${KEY}|" "$CACHE" 2>/dev/null > "$CACHE.tmp" || true
echo "${KEY}|${HASH}|${DATE}" >> "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"
```

### Reading a hash (before fetching)

```bash
CACHE="$WORKSPACE/workspace/tmp/.content-hashes"
CACHED=$(grep "^${KEY}|" "$CACHE" 2>/dev/null | tail -1)
if [ -n "$CACHED" ]; then
  CACHED_HASH=$(echo "$CACHED" | cut -d'|' -f2)
  CACHED_DATE=$(echo "$CACHED" | cut -d'|' -f3)
fi
```

### In Claude Code skills (non-bash)

Since skills run as Claude prompts (not bash scripts), prefer a targeted Bash lookup over reading the whole cache into context:

1. Run `awk -F'|' -v key="$KEY" '$1 == key' workspace/tmp/.content-hashes 2>/dev/null | tail -1`.
2. If found: fetch the content, compute the fresh hash via Bash, and compare.
3. If hash matches: skip re-analysis, report "Content unchanged since {date}".
4. If hash matches but `{date}` is stale for that skill, re-analyze once and refresh the cache.
5. If hash differs or key missing: proceed with full analysis, then update the cache via Bash.

Only read the full cache file when debugging cache corruption.

### Cache Invalidation

- Entries older than 30 days are considered stale — always re-analyze after fetching, even if the hash still matches
- Skills may force-refresh by ignoring the cache (e.g., user passes `--force`)
- The cache file lives in `workspace/tmp/` and is excluded from backup

## Skills Using This Pattern

- `/nase:tech-digest` — fetches enough source content to hash, skips deep analysis for unchanged non-stale sources, and refreshes stale cache entries
- `/nase:onboard` — caches repo CLAUDE.md + key file hashes to skip full re-scan when unchanged
