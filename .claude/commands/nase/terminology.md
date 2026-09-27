---
name: nase:terminology
description: "Define, update, or look up scope-aware terminology (same term can mean different things per repo/domain), cross-linked. Use for what does X mean, add a term, or glossary entry; use kb-update/learn otherwise."
argument-hint: "<term>|list [scope:<label>]|define/update <term> scope:<label>=<def>"
category: Knowledge base
---

Maintain the terminology KB - one file per term, one `## Scope:` section per
sense, cross-linked with `> See also:` links.

**Decision rule:** a term/glossary definition (freeform "X means Y",
optionally scoped to a repo or domain) belongs here, not in
`/nase:kb-update` or `/nase:learn` - see `.claude/docs/kb-write-routing.md`
decision tree.
Follows `.claude/docs/workspace-write-guard.md` for `workspace/kb/terminology/**`
writes and `_index.md`. Use `python3 .claude/scripts/workspace-write-guard.py stage`
for every full-file durable write. Follow `.claude/docs/terminology-schema.md`
for file layout, index shape, conflict check, and retrieve/list rules.

**Input:** $ARGUMENTS

## Steps

0. **Language preflight (MUST run first, non-negotiable):** Follow
   `.claude/docs/language-config.md` → Minimum Step 0 block. Term slugs,
   scope labels, and structural headings stay English; freeform
   `**Definition:**` prose follows `conversation:` unless the term file
   already has a stronger local convention.

0a. **Confidential marker guard:** Follow `.claude/docs/confidential-marker.md`.
    Check only user-provided arguments and the definition being persisted,
    not this command file. If it contains `[CONFIDENTIAL]`, refuse to
    persist it and ask for a sanitized restatement.

1. **Parse $ARGUMENTS into an action:**
   - Empty, or `list [scope:{label}]` -> **List**
   - `{term}` alone, or `get`/`show {term}` `[scope:{label}]` -> **Retrieve**
   - `define {term} scope:{label} = {definition}`, or natural language
     ("add a term ... meaning ... in scope ...") -> **Define**
   - `update {term} scope:{label} = {definition}` -> **Update**

   Try jev first for this classification (`.claude/docs/jev-judgment-points.md`,
   point `terminology.action-parse`, `--type Choice`, criteria = the four
   actions above; state = the raw `$ARGUMENTS` string). Confidence < 0.9,
   missing, or unavailable -> match the patterns above yourself.

   Extract `{term}` (required), `scope:{label}` (freeform, defaults to
   `general` when a define/update omits it - never guess a more specific
   label), and `{definition}` (everything after `=`, or the
   natural-language equivalent). If the term or definition can't be
   identified, ask rather than guessing.

### List (read-only)

2. Follow `.claude/docs/terminology-schema.md` Part 5. Render:
   ```
   ## Terminology — {N} term(s) [{scope filter if any}]

   | Term | Slug | Scopes | Aliases | Last updated |
   |---|---|---|---|---|
   ...
   ```
   If `_index.md` does not exist: `No terms defined yet. Run /nase:terminology define {term} scope:{label} = {definition} to add one.`

### Retrieve (read-only)

3. Follow `.claude/docs/terminology-schema.md` Part 4. Render:
   ```
   ## {Term}

   ### Scope: {label}
   {definition}
   {Tags: ... — omit if none}
   {See also: ... — omit if none}
   Last updated: {date}

   ### Scope: {other label}
   ...

   ---
   Related terms: {up to 5 other terms whose own `**See also:**` link points back to this file} — omit this whole block if none
   ```
   A **fuzzy candidate** is an `_index.md` row whose slug contains the
   query as a substring, whose `Aliases` cell matches it exactly
   (case-insensitively), or whose slug is within edit distance 2 of it.
   That rule decides the branch, and the two branches do very different
   things, so apply it before choosing.
   Fuzzy candidates found: show up to 5 and ask which one, instead of
   guessing - do not research yet, a near-hit needs a human pick first.
   No match at all (no exact hit, no fuzzy candidate by that rule): go to
   Step 3a instead of reporting failure.

### Research (auto, only on a genuine no-match)

3a. The term is missing, not merely unindexed - look it up instead of
    telling the user to define it themselves. Search in this order,
    stopping as soon as a source gives a clear, attributable definition:
    1. Onboarded repo KB (`workspace/kb/`, via `.domain-map.md`) -
       delegate to `nase-context-kb-researcher`.
    2. Local repos on disk, via `.local-paths` - grep source, docs, and
       README for the term. Delegate to a **lookup** agent
       (`model=haiku`, `effort=low`, `tools=[Read, Grep, Glob, Bash]`).
    3. Confluence/Jira/Slack, if those MCPs are configured - search for
       the term. These stay in the main thread; they need live connector
       context.
    4. WebSearch/WebFetch for public/vendor documentation, as a last
       resort.

    Sources 1 and 2 are sweeps whose answer is one sourced definition,
    not the files they read, so they go to subagents; run them in
    parallel and stop as soon as either returns a citable hit.

    Every candidate definition needs a citable source (file path, page
    URL, or message link) - per the global evidence rule, an unsourced
    assertion is a guess, not a definition. Run Step 0a's confidential-marker
    guard on whatever text research pulls back before drafting anything
    from it.
    - Sources disagree on what the term means across repos/domains ->
      draft one `## Scope:` section per sense, each citing its own
      source, rather than one blended definition.
    - Nothing credible turns up anywhere -> fall back to:
      `No term found for "{term}" (checked KB, local repos, Confluence/Slack, and the web). Run /nase:terminology define {term} scope:{label} = {definition} to add it.`
    - Something credible turns up -> continue into Define Steps 4-6,
      using the researched text as `{definition}` and its source as a
      `**See also:**` link (or a `**Tags:**` note when the source has no
      linkable URL, e.g. a Slack DM). The write still stages, diffs, and
      gates with `AskUserQuestion` exactly like a user-authored Define -
      research changes where the definition comes from, not whether the
      write gets confirmed.

### Define

4. Follow `.claude/docs/terminology-schema.md` Part 3. If it surfaces a
   fuzzy/alias collision, fold that question into the Step 6
   `AskUserQuestion` as a second entry in the same `questions` array
   rather than asking it on its own - `.claude/docs/skill-contract.md`
   rule 4 wants one batched ask, and the collision is a drafting choice,
   not a mutation gate that has to fire on its own. Draft both readings
   so the batch can present either.
5. Build the proposed complete target file under `workspace/tmp/`:
   - **New term:** full file content (frontmatter + `# {term}` +
     `<!-- Last updated -->` + one `## Scope:` section), plus the
     `_index.md` row (creating `_index.md` with its header if it does not
     exist).
   - **New scope on an existing term:** the existing file with the new
     `## Scope:` section appended and the file-level `<!-- Last updated -->`
     marker refreshed, plus the `_index.md` `Scopes` cell diff.
6. Stage and show the diff per `.claude/docs/workspace-write-guard.md`
   (`workspace-write-guard.py stage`, then `diff`), for both the term file
   and, if changed, `_index.md`. Gate with `AskUserQuestion`:
   ```
   Define '{term}' (scope: {label})?
     - Save — write as staged
     - Edit — collect corrections, redraft, and re-stage before asking again
     - Cancel — abort; nothing written
   ```
   (Update step 9 gates with the same three options.)
   **Save:** apply the term file first, `_index.md` second, each with its
   own drift recheck immediately before `apply`. **Edit:** fold the
   corrections into Step 5, re-stage, and re-ask - don't reuse the old
   staged diff. **Cancel:** apply nothing and report `Term not defined.`

### Update

7. Follow `.claude/docs/terminology-schema.md` Part 3 - this must resolve
   to the "existing scope" branch. If it instead resolves to "new scope"
   or "new term," switch to the Define steps instead; `update` never
   silently creates.
8. Build the exact old -> new diff for that `## Scope:` section's
   `**Definition:**` / `**Tags:**` / `**See also:**` lines and the
   refreshed `<!-- updated: -->` / file-level `<!-- Last updated -->`
   markers. `_index.md` changes only if `Aliases` changed.
9. Stage and diff the same way as Define step 6, then gate with the same
   three-option `AskUserQuestion` as Define step 6 (question line: `Update
   '{term}' (scope: {label}) with this diff?`).
   **Save:** apply with the drift recheck immediately before `apply`.
   **Edit:** fold the corrections into Step 8, re-stage, and re-ask.
   **Cancel:** apply nothing and report `Term not updated.`

## Notes

- `scope:` is freeform, not an enum - reuse an existing label exactly
  (case-sensitive) when the same sense applies again, so `Scopes` in
  `_index.md` stays meaningful.
- List/Retrieve never write anything.
- A term that means the same thing everywhere gets one `## Scope: general`
  section rather than repeating the identical definition under several
  labels.

## Error Handling

If a Define/Update write's drift check fails (target changed since
staging), stop and report the staged file path per
`.claude/docs/workspace-write-guard.md`; do not retry automatically.
