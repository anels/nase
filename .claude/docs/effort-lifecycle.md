# Effort Lifecycle

The effort rules are split by what a caller needs, because the three parts have disjoint
readers: of the consumers that name a section, none names sections from more than one
part, and the drift machinery alone was 48 percent of this file when it held everything.

| Doc | Owns | Read it when |
|---|---|---|
| `.claude/docs/effort-model.md` | Stage Classifier, Status Vocabulary, Scope Vocabulary, Terminal Destination, Multi-Deliverable Efforts, Lifecycle (row semantics), Dependency & Discovery Fields, Single-File Invariant | Writing or validating an effort doc |
| `.claude/docs/effort-drift.md` | Drift Auto-Sync, Classifier Blind Spots, PR Reference Resolution | Reconciling a stated status against live PR or Jira state |
| `.claude/docs/effort-transitions.md` | Design Creation, Lifecycle (the block `/nase:design` writes), FSD Update, Prep-Merge Update, Wrap-Up Read Path | A specific skill is about to edit an effort doc |

Load the one part you need. A pointer to a section by name still resolves: each section
kept its heading, so `effort-model.md -> Status Vocabulary` and
`effort-drift.md -> Drift Auto-Sync` read the same as before. `Lifecycle` is the one
name two parts share: `effort-model.md` owns what a row means, `effort-transitions.md`
owns the initial block a skill writes.

Shared rules for `workspace/efforts/{slug}.md` and related `todo.md` entries.
Callers own inferring the slug; the three parts above own status names and lifecycle
edits. This file is an index and owns no rule of its own, so cite a part, never this
file, when a pointer needs a section.

All full-file writes go through `.claude/docs/workspace-write-guard.md`; each part
above restates that rule at its point of use.
