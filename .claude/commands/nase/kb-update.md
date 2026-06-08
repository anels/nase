---
name: nase:kb-update
description: "Persist durable repo-specific knowledge — architecture, constraints, API contracts, naming conventions tied to one codebase. Example: 'the Insights repo requires OrderBy before Skip in EF queries' → /kb-update. For general or cross-project patterns, use /nase:learn instead. Triggers: 'update KB', 'add to knowledge base', 'document this pattern', '记录到KB'."
pattern: pipeline
---

The KB is the workspace's long-term memory — it outlives individual sessions.

**Decision rule:** follow `.claude/docs/kb-write-routing.md` — repo-internal facts (API contract, migration constraint, naming convention, architectural decision) belong here; general patterns / web-sourced articles belong in `/nase:learn`; cross-service contracts go in `workspace/kb/cross-project/`; ops/runbooks go in `workspace/kb/ops/`.
Follows `.claude/docs/workspace-write-guard.md` for target KB files, `.domain-map.md`, cross-reference edits, and split/move operations. Use `python3 .claude/scripts/workspace-write-guard.py stage` for every full-file durable write.

**Input:** $ARGUMENTS
(If empty, reflect on recent work and identify what's worth capturing.)

## Steps

0. **Language preflight (MUST run first, non-negotiable):** Follow `.claude/docs/language-config.md` → Minimum Step 0 block. KB structural headings stay English; freeform KB prose follows `conversation:` unless the target file already has a stronger local convention.

0a. **Confidential marker guard:** Follow `.claude/docs/confidential-marker.md`. Check only user-provided arguments and the session content being persisted, not this command file or policy docs. If that content contains `[CONFIDENTIAL]`, refuse to persist it and ask the user for a sanitized restatement.

1. Identify the domain from $ARGUMENTS or recent context:

   Follow `.claude/docs/repo-resolution.md` Part 2 (KB File Loading): derive the domain key from the repo or topic name, read `workspace/kb/.domain-map.md`, and locate the target KB file.

   **Fallback (if Part 2 finds no match):** Infer the best category:
   - Deployment/ops runbooks → `workspace/kb/ops/{deployment-type}.md`
   - General stack patterns → `workspace/kb/general/{domain}.md`
   - Project-specific → `workspace/kb/projects/{repo}.md`
   - Cross-project (spans multiple repos) → `workspace/kb/cross-project/{topic}.md`
   Create the file with a minimal header, add to `.domain-map.md`, then proceed.

2. Read the target KB file to understand current state.

2a. **Conflict check** — before writing, search for similar content:
   - Extract 2–3 key terms from what you're about to add (domain names, function names, error messages, pattern keywords)
   - Grep the entire `workspace/kb/` directory for those terms, case-insensitive, excluding `.domain-map.md`:
     ```bash
     grep -rni --include='*.md' --exclude='.domain-map.md' -e '{term1}' -e '{term2}' workspace/kb/
     ```
   - **Hits in other KB files:** show the matching snippets and ask — "Similar content exists in `{file}` — duplicate, update, or distinct pattern?"
   - **Hits only in the target file:** consider updating the existing entry instead of appending a new one; surface the existing entry to the user before proceeding
   - **No hits:** proceed silently

3. Determine what to add:
   - New patterns or gotchas discovered
   - Architectural decisions made
   - Constraints clarified
   - Tools or techniques found useful

4. Build the proposed complete target file under `workspace/tmp/`, then run `python3 .claude/scripts/workspace-write-guard.py stage --target {target} --content-file {proposed} --skill kb-update`. Show the helper diff, apply only after the gate or documented auto path, then append to the appropriate section using this format:
```
### YYYY-MM-DD — {topic}
**What:** {one-line summary}
**Why it matters:** {context and impact}
**Details:** {specifics, examples, code snippets if relevant}
**Links:** {PR, Jira, Confluence, pipeline, or official doc URLs}
**Tags:** {comma-separated from: gotcha | architecture | api-contract | deployment | performance | security | workflow | debugging}
**Applies-to:** {comma-separated repo names}
**Confidence:** medium | low
```

**Field rules — omit fields that add no value:**
- `**Links:**` — omit if no relevant URLs; include because future sessions can't search conversation history
- `**Tags:**` — include when ≥1 tag applies; skip for entries with no filtering value. Tag vocabulary:
  - `gotcha` — non-obvious pitfall or surprise
  - `architecture` — structural decision or constraint
  - `api-contract` — external API behavior, method signatures, parameters
  - `deployment` — CI/CD, infra, release process
  - `performance` — latency, throughput, resource usage patterns
  - `security` — auth, secrets, vulnerability patterns
  - `workflow` — dev process, tool usage, habits
  - `debugging` — diagnostic technique, root-cause pattern
- `**Applies-to:**` — only when the insight is narrower than the KB file's scope (e.g., a `general/` file entry that only applies to `insights` and `uipathctl`); omit if obvious from the file's context
- `**Confidence:**` — `medium` for web-sourced or single-observation patterns; `low` for unverified hypotheses; omit entirely for well-tested, directly observed patterns (high confidence is the default)

5. If the learning is cross-cutting (affects multiple KB files), update all relevant files.

6. **Size check — split if needed:**

   Count the lines in the target file after writing.

   If the file exceeds **400 lines**, evaluate whether a split makes sense:
   - Identify top-level `##` sections and their line counts
   - A split is worthwhile when: there are 2+ sections each >150 lines AND they represent distinct sub-domains that would logically be consulted independently (e.g., "alert patterns" vs "runbook procedures" vs "escalation contacts")
   - If no clean semantic boundary exists, skip splitting

   **How to split:**
   - Prefer a **subfolder** when the domain will likely grow (e.g., `ops/oncall/` containing `alerts.md`, `procedures.md`, `escalation.md`)
   - Prefer a **flat sibling file** for a one-off split (e.g., `oncall.md` + `oncall-runbooks.md`)
   - Name files after the content, not the structure: `alerts.md` not `part1.md`

   **Split procedure:**
   1. Create the new file(s) with a header referencing the parent domain
   2. Move the relevant sections; keep a short index with `See also:` links in each file
   3. If using a subfolder: rename the original to `{name}/index.md` or keep it as a routing stub
   4. Update `workspace/kb/.domain-map.md` with the new file paths — use the format `- {domain-key} -> {relative-path}` matching existing entries, under the same category section
   5. Update any existing `See also:` references in other KB files that pointed to the original

7. **Internal links — wire up cross-references:**

   After writing (and after any split), check whether the new content references concepts covered in *other* KB files:
   - Grep `workspace/kb/` for the key terms from the new entry
   - If a hit exists in another file and the connection is genuinely useful (not incidental), add a `> See also: [{description}]({relative-path})` line near the relevant section — both in the file you just wrote *and* in the other file
   - Only add links that would actually help a reader navigate — don't link everything to everything

   Common link-worthy connections:
   - An alert in `oncall.md` referencing a runbook procedure now in `oncall-runbooks.md`
   - A project KB noting a Snowflake pattern that's detailed in `general/snowflake.md`
   - A deployment note in one project KB referencing a shared ops pattern

8. **Frontmatter sync** — keep file-level metadata current after every write:

   Read the YAML block at the very top of the file (between `---` delimiters), if any.

   **If no frontmatter exists**, prepend one before the first line:
   ```yaml
   ---
   domain: {domain-key from .domain-map.md}
   tags: [{aggregate unique **Tags:** values from all entries in the file, sorted}]
   related: [{domain keys collected from any > See also: links in the file}]
   status: active
   updated: {today YYYY-MM-DD}
   ---
   ```

   **If frontmatter already exists**, update in-place:
   - `updated:` → today's date
   - `tags:` → merge new tags from the entry you just wrote; keep list unique and sorted
   - `related:` → append domain keys from any `> See also:` links added in step 7; keep unique
   - Leave `status:` unchanged — only `/nase:kb-review` changes it

9. Confirm what was added, where, whether the file was split, and what links were added.

## Error Handling

If the target KB file doesn't exist, create it with a basic header and the new content. If `.domain-map.md` has no matching domain, ask the user which KB file to use.
