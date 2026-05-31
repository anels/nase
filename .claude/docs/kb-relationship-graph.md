# KB Relationship Graph — Algorithm & Output Shape

Used by `/nase:kb-review` Step 3b. Builds a cross-file reference graph over a set of in-scope KB files, then surfaces hubs, orphans, clusters, and missing backlinks.

---

## Signal Types

**Explicit links** — count existing `> See also:` lines in each file. Parse the markdown link target to identify which KB file is referenced. Record inbound and outbound counts per file.

**Implicit mentions** — for each KB file, extract its basename without extension (e.g., `insights-monitoring` from `insights-monitoring.md`). Then scan every OTHER file's content for that basename string (case-insensitive). A match means the other file implicitly references this one. Exclude:

- Self-references (file mentioning its own basename)
- Matches inside `> See also:` lines (already counted as explicit)
- **Basenames shorter than 5 characters** (e.g., `cli`, `sre`) — these produce too many false positives. Short-named files are tracked via explicit `> See also:` links only.

---

## Per-File Records

For each file, record:

- **Outbound explicit** — count of `> See also:` links FROM this file
- **Outbound implicit** — count of other-file basenames mentioned in this file's body
- **Inbound explicit** — count of `> See also:` links in OTHER files pointing TO this file
- **Inbound implicit** — count of other files whose body mentions THIS file's basename

---

## Output: Relationship Summary

Each subsection is capped to prevent output bloat. The caller parses `--verbose` from `$ARGUMENTS` to remove caps.

```markdown
## Relationship Graph

### 🔗 Hub files (top 5 by total connections)
| File | In (explicit) | In (implicit) | Out (explicit) | Out (implicit) | Total |
|------|--------------|--------------|----------------|----------------|-------|
| projects/insights.md | 5 | 12 | 9 | 3 | 29 |
| ... | ... | ... | ... | ... | ... |

### 🏝️ Orphans (zero inbound references — max 10)
- `general/spark-scala.md` — 0 inbound links, 2 outbound. Consider: is this file discoverable?
- ...

### 🔄 Clusters (groups of 3+ mutually-referencing files — max 5)
- **insights-* family:** insights.md ↔ insights-monitoring.md ↔ insights-containerimages.md ↔ insights-dashboarding.md ↔ insights-ops.md
- ...

### ➡️ Missing reciprocal links (A links to B, but B doesn't link back — max 10)
| From | Links to | But missing backlink |
|------|----------|---------------------|
| general/debugging.md | ops/oncall.md | ops/oncall.md → general/debugging.md |
| ... | ... | ... |
```

If any section exceeds its cap, append: `({N} more — run /nase:kb-review --verbose for full list)`.

---

## How Callers Use the Output

- **Missing reciprocal links** → "Quick Fix" candidates (add `> See also:` backlinks)
- **Orphans** → "Cleanup" candidates (review for relevance or removal)
- **Clusters** with overlapping content → consolidation candidates feeding back into the consolidation pass
