---
name: nase:skill-usage
description: Surface skill invocation frequency and recency from `workspace/stats/skill-usage.jsonl`. Lists every `/nase:*` skill with total uses, 30/7-day windows, last-used date, and flags candidates for deprecation (0 uses in 60+ days). Cross-references against `.claude/commands/nase/*.md` + `workspace/skills/*.md` so newly added skills with no uses still appear. Use when asked "which skills do I use", "deprecate skills", "skill usage", "skill stats", "废 skill", "skill 使用率", or before pruning the skill catalog. Read-only — never writes to skill files. Output goes to `workspace/stats/skill-usage-{YYYY-MM-DD}.md` (full table) + 5-line chat summary.
---

Read-only skill usage report. Aggregates `workspace/stats/skill-usage.jsonl` and cross-references the on-disk skill catalog.

**Input:** `$ARGUMENTS` (optional)
- `--window <N>` — recency window in days (default `60`); skills with 0 uses inside the window are flagged
- `--verbose` — also print full table inline in chat (otherwise file-only per skill-output discipline)
- `--top <N>` — limit summary line to top N skills (default `10`)

## Steps

<workflow>

### Step 0: Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Report table headers may stay English when they are protocol-fixed field names.

### Step 1: Locate the JSONL

```bash
NASE_ROOT=$(git rev-parse --show-toplevel)
JSONL="$NASE_ROOT/workspace/stats/skill-usage.jsonl"
[ -f "$JSONL" ] || { echo "No skill usage data — has track-skill.sh ever run?"; exit 0; }
```

If absent, surface a friendly note (`track-skill.sh` may have never fired; `jq` may be missing) and stop.

### Step 2: Aggregate by skill

Parse JSONL with `jq`. Each entry has at minimum `{skill, ts}` and (post-2026-05) optional `{status}` plus optional `{source}` (`skill` or `prompt`). Treat missing `status` as `success` for backward compatibility.

Produce a per-skill record:
- `total` — all-time invocations
- `last_30d` — invocations in trailing 30 days
- `last_7d` — invocations in trailing 7 days
- `last_used` — most recent `ts` (ISO date)
- `days_since_last` — today − `last_used`
- `success_rate` — `success / total` (only meaningful if status field present)

```bash
TODAY=$(date -u +%Y-%m-%d)
jq -r --arg today "$TODAY" '
  . as $e | {skill, ts, status: (.status // "success")}
' "$JSONL" \
| jq -s 'group_by(.skill)[] | {
    skill: .[0].skill,
    total: length,
    last_used: (max_by(.ts) | .ts[0:10]),
    last_30d: (map(select(.ts > (now - 30*86400 | strftime("%Y-%m-%dT%H:%M:%SZ")))) | length),
    last_7d:  (map(select(.ts > (now - 7*86400  | strftime("%Y-%m-%dT%H:%M:%SZ")))) | length),
    success_rate: ((map(select(.status == "success")) | length) / length)
  }'
```

### Step 3: Discover skills with zero uses

Walk the on-disk catalog and append entries for any skill not present in the JSONL:

```bash
for f in "$NASE_ROOT"/.claude/commands/nase/*.md; do
  base=$(basename "$f" .md)
  [ "$base" = "skill-usage" ] && continue   # don't self-list before first run
  echo "native:$base"
done
for f in "$NASE_ROOT"/workspace/skills/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .md)
  echo "workspace:$base"
done
```

For skills with no JSONL entries: emit `total=0, last_used=never, days_since_last=∞`.

### Step 4: Score and flag

For each skill, compute a usage tier:
- **hot** — `last_7d >= 3`
- **active** — `last_30d >= 1`
- **cold** — `total > 0` but `days_since_last >= window` (default 60)
- **unused** — `total == 0`

Resolve `--window` from `$ARGUMENTS` (default 60).

### Step 5: Write the full report

Path: `workspace/stats/skill-usage-{YYYY-MM-DD}.md`. Sections:

```markdown
# Skill Usage — {YYYY-MM-DD}

## Summary
- Total skills on disk: N (native: X, workspace: Y)
- Skills with ≥1 use: N
- Skills unused: N
- Skills cold (no use in {window}d): N

## Hot (last 7d)
| Skill | Total | 7d | 30d | Last used |
|---|--:|--:|--:|---|
...

## Active (last 30d, not hot)
...

## Cold (>={window}d since last use)
...

## Unused (total = 0)
| Skill | Source |
|---|---|
| {name} | native / workspace |
...

## Suggested deprecation candidates
- {name} — {reason: cold N days / unused since on-disk M days}
...
```

### Step 6: Chat summary

Per `.claude/docs/skill-contract.md`. Chat format:

```
Skill usage saved → workspace/stats/skill-usage-{YYYY-MM-DD}.md
Hot: {N} · Active: {N} · Cold: {N} · Unused: {N}
Top {top}: {s1} ×{N}  {s2} ×{N}  ...
Deprecation candidates: {N} (see file)
```

</workflow>

## Notes

<error_handling>

- **JSONL absent** — surface "No skill usage data" and exit; do not error.
- **`jq` missing** — print the install hint from `CLAUDE.md` (Runtime Dependencies) and exit 0.
- **`status` field absent** — treat as `success` (backward compatibility with entries written before 2026-05).
- **Skills with non-ASCII names** — `jq` handles UTF-8 natively; no special case needed.
- **Read-only** — never edit a skill file. Deprecation is suggested, not enforced. The user runs `git rm` themselves after review.
- **Self-listing** — once `/nase:skill-usage` has run at least once, it appears in its own report. Cosmetic, intentional.

</error_handling>
