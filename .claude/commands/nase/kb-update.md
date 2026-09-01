---
name: nase:kb-update
description: "Persist durable knowledge tied to one repo. Use for update KB, add a repo constraint, or document an API contract; use /nase:learn for shared patterns."
argument-hint: "<repo/topic/fact>"
pattern: pipeline
category: Knowledge base
---

The KB is the workspace's long-term memory — it outlives individual sessions.

**Decision rule:** follow `.claude/docs/kb-write-routing.md`, including its Shared admission contract. Repo-internal facts (API contract, migration constraint, naming convention, architectural decision) belong here; general patterns / web-sourced articles belong in `/nase:learn`; cross-service contracts go in `workspace/kb/cross-project/`; ops/runbooks go in `workspace/kb/ops/`.
Follows `.claude/docs/workspace-write-guard.md` for target KB files, `.domain-map.md`, cross-reference edits, and split/move operations. Use `python3 .claude/scripts/workspace-write-guard.py stage` for every full-file durable write. Format entries per `.claude/docs/kb-template.md → Writing Conventions`.

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
     rg -n -i -g '*.md' -g '!.domain-map.md' -e '{term1}' -e '{term2}' workspace/kb/
     ```
   - **Hits in other KB files:** show the matching snippets and ask — "Similar content exists in `{file}` — duplicate, update, or distinct pattern?"
   - **Hits only in the target file:** update the existing current-state section instead of appending a duplicate; surface the existing entry to the user before proceeding
   - **No hits:** proceed silently

3. Determine what to add:
   - New patterns or gotchas discovered
   - Architectural decisions made
   - Constraints clarified
   - Tools or techniques found useful

   Classify the knowledge before writing:
   - **Current-state fact:** reconcile the existing section in place and remove superseded wording.
   - **Durable dated event:** append only when the date matters to a decision, incident, migration, or gotcha.
   - **No-op/status fact:** for unchanged HEAD, commit counts, scan status, or routine hygiene, write nothing.
   - **Unknown or follow-up:** omit it from the KB or route actionable work to `workspace/tasks/` or `workspace/efforts/`. Never write placeholders such as `FILL_IN`, `TBD`, or `TO_BE_FILLED`.
   - Apply `.claude/docs/kb-template.md -> Verification triad`. V2 and V3 are admission gates. If either fails, keep the evidence in the originating log, recap, report, or effort instead of the active KB.

4. Build the proposed complete target file under `workspace/tmp/`. For current-state facts, edit the existing section in place. Use the dated format below only for durable events whose date is material:
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
- `**Applies-to:**` — only when the insight is narrower than the KB file's scope (e.g., a `general/` file entry that only applies to `platform` and its CLI); omit if obvious from the file's context
- `**Confidence:**` — `medium` for web-sourced or single-observation patterns; `low` for unverified hypotheses; omit entirely for well-tested, directly observed patterns (high confidence is the default)

5. If the learning is cross-cutting (affects multiple KB files), update all relevant files.

6. **Size check — split if needed:**

   Count the lines in the complete proposed file before applying it.

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

   After building the proposal (and after any proposed split), check whether the new content references concepts covered in *other* KB files:
   - Grep `workspace/kb/` for the key terms from the new entry
   - If a hit exists in another file and the connection is genuinely useful (not incidental), add a `> See also: [{description}]({relative-path})` line near the relevant section — both in the file you just wrote *and* in the other file
   - Only add links that would actually help a reader navigate — don't link everything to everything

   Common link-worthy connections:
   - An alert in `oncall.md` referencing a runbook procedure now in `oncall-runbooks.md`
   - A project KB noting a Snowflake pattern that's detailed in `general/snowflake.md`
   - A deployment note in one project KB referencing a shared ops pattern

8. **Domain-map sync** - prepare a separate guarded proposal for `workspace/kb/.domain-map.md`, the file-level metadata authority:

   - Update `last-updated` only when durable content in the target file changes.
   - Add or change the mapping only when a file is created, split, or moved.
   - Do not add frontmatter solely for KB metadata. Preserve existing frontmatter unless the target file already defines its own local metadata contract.
   - Do not write read/access timestamps into `.domain-map.md`; usage telemetry owns access history.

9. Stage every complete changed file separately with `python3 .claude/scripts/workspace-write-guard.py stage --target {target} --content-file {proposed} --skill kb-update`. Show each helper diff and apply only after the gate or documented auto path. Apply KB content files first and `.domain-map.md` last, so metadata never claims a content change that did not land. Then confirm what was added, where, whether the file was split, and what links were added.

## Error Handling

If the target KB file doesn't exist, create it with a basic header and the new content. If `.domain-map.md` has no matching domain, ask the user which KB file to use.
