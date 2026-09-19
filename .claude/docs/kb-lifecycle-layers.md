# KB Lifecycle Layers

## Contents

- Four layers
- Layer findings
- Promoting a dated gotcha to Living
- Two times, always
- Status claims must be verified
- Critical entries
- Rot visibility
- Over-breadth needs a count
- Writing rules
- Unvalidated rules

> Shared rules for which layer a KB line belongs to, how a status claim earns its wording, and when an entry is usable guidance. Referenced from `/nase:kb-review`. Edit here, not in the skills.

## Four layers

Every KB line belongs to exactly one layer. Layer decides the edit rule.

| Layer | Content | Edit rule |
|---|---|---|
| Living | Current constraints, contracts, config values, topology, ownership, commands | Edit in place. Keep no prior version. |
| ADR | Why A over B, the rejected alternatives and their cost, the consequences | Immutable. A changed decision becomes a new entry. The old entry gets a `Superseded by` line and stays. |
| Dated | Measured numbers, PR or branch state at a moment, incident snapshots | Archivable, roll-off allowed. Any gotcha inside that survives re-verification MUST be promoted to Living. |
| Changelog | "PR #1234 merged, touched A, B, C" | MUST NOT be written. `git log` already holds it. |

The ADR layer maps to the `Decision` page shape in `.claude/docs/kb-template.md → Page shapes`.

## Layer findings

- Living text inside a dated block, or a dated measurement inside a Living section, is a mixing finding. The reader cannot tell whether the line still holds.
- **Two or more same-named `Recent Changes` / `Notes` / `Findings` / `Updates` sections in one file is itself a finding**, not a duplicate-content finding. It means the file has no rule for where new content lands. Report the file, the repeated heading, and the line numbers.
- An ADR entry with no rejected alternative and no stated cost is a decision record that lost its reason. Report it; do not fabricate the alternative.
- A superseded ADR that was edited in place instead of superseded is a finding. The evidence is a decision entry whose body contradicts its own dated heading.

## Promoting a dated gotcha to Living

1. Re-verify the gotcha against current `HEAD` or current config. A gotcha that no longer reproduces is archived, not promoted.
2. Rewrite it as a present-tense constraint. Drop the incident narrative.
3. Place it under the Living section that owns the subsystem.
4. In the dated block, replace the gotcha text with one line, `Promoted -> <target anchor> (YYYY-MM-DD)`.
5. Leave the dated block's remaining measurements untouched.

## Two times, always

A `Correction` or `Supersedes` link MUST carry both the recording time and the time the fact started being true.

```
**Correction** (recorded 2026-09-18, true since 2026-08-15): <what is now the case>. Supersedes <anchor>.
**Superseded by** <anchor> (recorded 2026-09-18, true since 2026-08-15)
```

When the valid time is unknown, write `true since unknown`. MUST NOT reuse the recording date as the valid time; that silently asserts the change happened the day it was noticed.

## Status claims must be verified

A status word is a claim about the world, not a label. This covers `OPEN`, `MERGED`, `CLOSED`, `FIXED`, `ENABLED`, `DISABLED`, `DEPRECATED`, `ACTIVE`, and any "currently" / "now" / "as of" phrasing.

| Claim kind | Verify with | On failure |
|---|---|---|
| PR state | `gh pr view <url> --json state,mergedAt,mergeCommit` | `unverified as of <date>` |
| Issue or ticket state | `gh issue view`, or the Jira read tool | `unverified as of <date>` |
| Config value, flag state | Read the tfvars, values file, appsettings, or variable group at a named ref | `unverified as of <date>` |
| Code behavior | Read `file:line` at a named ref | `unverified as of <date>` |
| Deployed state | Artifact content probe. Branch ancestry is not deploy evidence | `unverified as of <date>` |
| CI gate, required check | Branch-protection contexts, or the workflow file at `HEAD` | `unverified as of <date>` |

**MUST NOT pick a status when verification fails.** Write `unverified as of <date>` and keep it as a finding. A silent guess is worse than an unverified marker, because the marker is searchable and the guess is not.

When the KB contradicts code, config, or live state, the executable source wins and the KB entry gets repaired. A zero exit, a green validator, or a merged PR is evidence about that check only, never about the claim written above it.

## Critical entries

An entry is critical when acting on it changes a system or misleads an operator. Concretely, it names a command to run, a config value to set, a state to trust, a contract to depend on, or a boundary to touch.

Every critical entry carries:

- `Verified: <YYYY-MM-DD> via <method>` or an explicit `unverified as of <YYYY-MM-DD>`.
- A change trigger, meaning the one thing whose change makes this entry false.
- Its boundary, meaning where the guidance stops applying. `.claude/docs/kb-template.md → State the boundary for actionable guidance` already requires this.

An entry missing all three is not usable guidance. Downgrade it to a finding rather than acting on it.

Review cadence stays the single set of thresholds in `.claude/docs/kb-staleness.md → Step B`. Do not add per-type periods here without changing that table.

## Rot visibility

Ask of every critical entry, "if this rotted, how long until someone notices?" An answer of "never" means the entry MUST either shrink until the rot is visible on the page, or carry `Verified:` so the date exposes it. A long file fails the same test by hiding its expired content in the middle.

**Each curation round MUST net-shrink the content files it touches.** A round that ends longer is a failed round unless the report names the added high-value content and why it clears `.claude/docs/kb-template.md → Verification triad` V2 and V3. Indexes and registries such as `.domain-map.md` are exempt, because repairing one adds entries.

A file-top marker MUST be a semantic index, covering what is in the file, where it lives, and how fresh it is. Process archaeology belongs nowhere. What the last scan found and how many findings it produced are recoverable from git and tool output; a semantic index is not. This is the same defect as `.claude/docs/kb-staleness.md → Step D2` accretion, seen from the top of the file.

## Over-breadth needs a count

Over-breadth is invisible without counting, because a term reads as normal regardless of how many entries carry it. Never delete a term for looking generic; count first.

Counts, from `grep` so no new dependency is introduced:

- `grep -rc '\*\*Confidence:\*\* high' workspace/kb/` against the total entry count per file. Do not anchor the pattern to line start; the marker also appears mid-line.
- Per domain-map section, the occurrence count of each `topics:` term against that section's entry count.

Thresholds:

- A `topics:` term on more than 30% of its domain-map section's entries carries no retrieval value. Drop it from the entries, or promote it to the section name.
- A term on one or two entries is the valuable kind. Keep it.
- `**Confidence:** high` is the default in `.claude/docs/kb-template.md → V1`. A default carries no information, so it MUST NOT be written. Strip it when it exceeds 80% of a file's entries and keep only `medium` and `low`.

## Writing rules

These govern repair proposals and rule text. KB prose itself follows `.claude/docs/kb-template.md → Writing Conventions`.

- Use `MUST`, `MUST NOT`, `SHOULD`, `MAY`, `DO NOT`. Drop "consider", "you might want to", "it may be worth".
- Banned openers, because they announce instead of stating: "It's worth noting that", "This is important because", "It should be noted that", "Note that".
- One idea per sentence.

❌ "You might want to consider validating the coverage field before publishing the report, as this could potentially help prevent issues down the line."
✅ "MUST NOT report a file as reviewed when only part of it was read."

## Unvalidated rules

Inferred when this doc was written, not carried over from an existing shared doc. Confirm or correct them in use.

- The 30% `topics:` and 80% `**Confidence:** high` thresholds. Both come from the inverse-document-frequency argument, not from counts taken on this workspace.
- `.claude/docs/kb-template.md` defines the `Decision` page shape but carries no ADR immutability rule and no `Superseded by` format. Both live here instead, one file away from the other writing-side rules.
- Whether `kb-hygiene-scan.py` can produce the over-breadth counts directly. The `grep` path is the no-new-dependency fallback.
