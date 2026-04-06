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
- **date**: when the hash was last computed

## Usage in Skills

### Writing a hash (after fetching)

```bash
# Compute hash of content (variable or file)
HASH=$(echo -n "$CONTENT" | shasum -a 256 | awk '{print $1}')
DATE=$(date +%Y-%m-%d)

# Remove old entry for this key (if any), then append new one
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

Since skills run as Claude prompts (not bash scripts), the hash check is done conceptually:

1. Read `workspace/tmp/.content-hashes` via Read tool
2. Look up the key (URL or `repo:<name>`)
3. If found: fetch the content, compute hash mentally (or via `echo -n "..." | shasum -a 256` in Bash), compare
4. If hash matches: skip re-analysis, report "Content unchanged since {date}"
5. If hash differs or key missing: proceed with full analysis, then update the cache via Bash

### Cache Invalidation

- Entries older than 30 days are considered stale — always re-fetch
- Skills may force-refresh by ignoring the cache (e.g., user passes `--force`)
- The cache file lives in `workspace/tmp/` and is excluded from backup

## Skills Using This Pattern

- `/nase:tech-digest` — caches source content hashes to skip unchanged sources
- `/nase:onboard` — caches repo CLAUDE.md + key file hashes to skip full re-scan when unchanged
