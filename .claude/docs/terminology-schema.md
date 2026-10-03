# Terminology Schema

## Contents

- Part 1: File Layout
- Part 2: Index
- Part 3: Conflict & Alias Check (before writing)
- Part 4: Retrieve
- Part 5: List

Schema and lookup rules for the terminology KB at `workspace/kb/terminology/`.
The rest of `workspace/kb/` is one file per repo/domain
(`.claude/docs/kb-write-routing.md`); terminology is the one KB area that is
one file per **term** instead, because the same term needs to carry several
independent, scope-tagged senses side by side (e.g. "DRI" means one thing
generally and something narrower inside a specific repo's on-call rotation).
It reuses `.claude/docs/kb-template.md`'s `<!-- Last updated: YYYY-MM-DD -->`
marker and plain `> See also: [{desc}]({relative-path})` link convention
rather than inventing new ones.

---

## Part 1: File Layout

One file per term: `workspace/kb/terminology/{slug}.md`. `{slug}` is the
term lowercased, non-alphanumeric runs collapsed to a single `-`, trimmed
(e.g. `DRI` -> `dri`, "Directly Responsible Individual" ->
`directly-responsible-individual`).

```markdown
# {term}
<!-- Last updated: YYYY-MM-DD -->

## Scope: {label}
**Definition:** {one or more sentences}
**Tags:** {comma-separated, optional}
**See also:** {comma-separated `> See also:`-style links, optional}
<!-- updated: YYYY-MM-DD -->

## Scope: {other label}
...
```

- `{label}` is freeform - a repo name, a domain, or `general` for a
  cross-cutting sense. Record whatever the caller gives; there is no fixed
  enum.
- A term with only one sense still gets one `## Scope: general` section
  rather than a scope-less body, so every term file has the same shape.
- Each `## Scope:` section carries its own `<!-- updated: -->` so a
  multi-sense file shows which sense is stale independently. The
  file-level `<!-- Last updated -->` marker always reflects the most
  recent edit across any scope in the file.
- `**See also:**` links use the same plain-markdown convention as the rest
  of the KB (`> See also: [{desc}]({relative-path})`) - do not invent a
  separate link syntax for terminology.

---

## Part 2: Index

`workspace/kb/terminology/_index.md` - one row per term:

```markdown
# Terminology Index
<!-- Managed by /nase:terminology. One row per term; Scopes lists every sense defined in that term's file. -->

| Term | Slug | Scopes | Aliases | Last updated |
|---|---|---|---|---|
| DRI | dri | general, platform | - | 2026-09-21 |
```

`Scopes` is every `## Scope:` label currently in that term's file, in file
order. `Aliases` mirrors the term file's frontmatter `aliases:`, or `-`
when empty. Rows stay sorted by `Term` (case-insensitive). `/nase:terminology`
is the only writer; create the file on the first `define` write (via
`workspace-write-guard.py`, same as any other durable target) if it does not
exist yet. Retrieve/List treat a missing index as zero terms, not an error.

`_index.md` is this store's registry, so term files never get a
`workspace/kb/.domain-map.md` entry. `kb-hygiene-scan.py --workspace-scan`
skips `workspace/kb/terminology/` in its domain-map orphan check.

---

## Part 3: Conflict & Alias Check (before writing)

Run before every `define`/`update`, after parsing the candidate term, scope
label, and definition.

1. Normalize the candidate to a slug (Part 1's rule) and look it up in
   `_index.md`.
   - **Exact slug hit, requested scope not in that term's `Scopes`** ->
     `define`: append a new `## Scope:` section to the existing file.
   - **Exact slug hit, requested scope already present** -> `update`: show
     the old -> new diff for that section only.
   - **No exact slug hit** -> continue to step 2.
2. Fuzzy/alias scan: check the candidate against every `Term` and `Aliases`
   entry using the same hyphen/space/underscore split `kb-search.sh` uses
   for its fuzzy fallback.
   - **No fuzzy hit** -> new term: draft a new file plus a new index row.
   - **Fuzzy hit that is not the exact slug** -> do not draft yet. Ask:
     "`{candidate}` looks close to existing term `{existing term}`
     (`{slug}`). Add this as a new scope/alias on `{existing term}`, or is
     it genuinely a distinct term?" Only draft once the user picks a side.

---

## Part 4: Retrieve

For a `{term}` lookup, optional `scope:{label}` filter.

1. Normalize to a slug; exact match against `_index.md` `Term`, `Slug`, or
   `Aliases`.
2. No exact match - fuzzy fallback (same split rule) across `_index.md`;
   show up to 5 candidates.
3. Read the matched term file(s).
   - **No `scope:` filter** - render every `## Scope:` section.
   - **`scope:{label}` given and present** - render only that section.
   - **`scope:{label}` given and absent** - name the scopes that do exist
     instead of returning empty.
4. Backlink scan: grep every *other* file in `workspace/kb/terminology/`
   for a `**See also:**` line whose relative path resolves to this term's
   `{slug}.md`. List up to 5 matches, each as `[{Other Term}](other-slug.md)`,
   under a trailing `---` / `Related terms:` line. No other term links back
   - omit the block entirely rather than printing an empty header. This
   surfaces incoming references without maintaining a separate backlink
   index; it costs one grep across a directory that stays small by
   design (one file per term).

---

## Part 5: List

Read `_index.md`. No filter - render the table as-is. `scope:{label}` -
keep only rows whose `Scopes` column contains that label (substring
match). Missing `_index.md` means zero terms defined - say so, don't
error.
