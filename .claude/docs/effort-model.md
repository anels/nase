# Effort Model

The vocabulary and invariants an effort doc has to satisfy: what the stages and
statuses mean, where a finished effort goes, and the one-file rule. Read this to
write or validate an effort doc. The sync machinery is in `effort-drift.md` and the
per-skill procedures are in `effort-transitions.md`.

## Contents

- Stage Classifier
- Status Vocabulary
- Scope Vocabulary
- Terminal Destination
- Multi-Deliverable Efforts
- Lifecycle
- Dependency & Discovery Fields
- Single-File Invariant

Shared rules for `workspace/efforts/{slug}.md` and related `todo.md` entries.
Callers own inferring the slug; this doc owns the status and scope vocabulary and
the structural invariants an effort doc has to satisfy.

All full-file writes use `.claude/docs/workspace-write-guard.md` and
`workspace-write-guard.py`. Auto-write modes only skip human confirmation; they
never skip final drift checks.

---

## Stage Classifier

`/nase:today` and `/nase:efforts` classify an active effort through:

```bash
python3 .claude/scripts/effort-state.py --file workspace/efforts/{slug}.md
```

The JSON result is the only stage contract. It scans the whole document for checked
canonical labels in monotonic order: `Implementation started`, `PR opened`,
`Merged`, then `Deployed`. It ignores unrelated plan and grill checkboxes, falls
back to frontmatter only when no canonical label is checked, and flags frontmatter
conflicts with `needs_live_verification`. A deployed effort with pending
`Follow-up:` checkboxes is `follow_up_only`.

## Status Vocabulary

Frontmatter `status:` for `workspace/efforts/{slug}.md`. This is the authoritative
list; `/nase:kb-review` validates it under *Deep review -> Authoritative state*.

**Active** (file lives directly in `workspace/efforts/`):

| status | meaning |
|---|---|
| `planned` | design approved, implementation not started |
| `in-progress` | implementation underway (set by `/nase:fsd`) |
| `needs-revision` | PR open but review/CI sent it back for changes |
| `blocked` | progress halted on an external dependency |
| `merge-ready` | review passed, awaiting human merge (set by `/nase:prep-merge`) |
| `awaiting-deploy` | PR merged; awaiting deploy + post-deploy validation before close |
| `tracked` | tracking-only effort someone else implements |
| `ready` | reserved alias for `merge-ready`/`planned`-complete states |

**Done** (file moved out of `workspace/efforts/` - see *Terminal Destination* below):

| status | meaning |
|---|---|
| `completed` | shipped and verified |
| `wontfix` | closed without shipping |

`awaiting-deploy` is set by the Drift Auto-Sync rule (`effort-drift.md → Drift
Auto-Sync`) when delivery PRs merge,
or by hand when needed, paired with `- [x] Merged` in the Lifecycle block. The
effort leaves `workspace/efforts/` as `completed` only after deploy validation passes.
Status describes the effort, not its code: one that shipped PRs but dropped its verdict is
`wontfix` **plus** `partial_delivery` (`.claude/docs/effort-doc-audit.md`).

## Scope Vocabulary

Frontmatter `scope:` for `workspace/efforts/{slug}.md`. This is the authoritative
list; `/nase:kb-review` validates it alongside `status:`.

`scope` answers **how big is this**, not **what kind of change is it**. A bug fix
is `quick-fix` or `feature` depending on its size; `bug`, `fix`, `bugfix`,
`audit`, `investigation`, `roadmap`, and `security-hardening` are all category
errors against this axis and have been normalized away.

| scope | meaning |
|---|---|
| `quick-fix` | one PR, bounded blast radius, no design surface to speak of |
| `feature` | a deliverable with its own design and success criteria; usually 1-2 PRs |
| `initiative` | multi-PR programme, often with child efforts and phases |
| `exploration` | investigation or spike whose deliverable is an answer, not shipped code |

## Terminal Destination

A terminal transition files the effort into one of two directories, and
`effort-state.py` decides which - read `transition.destination_dir` rather than
hard-coding `done/`:

| `tracking_only:` | destination | why |
|---|---|---|
| absent / false | `workspace/efforts/done/` | this workspace delivered the work |
| `true` | `workspace/efforts/archive/{current year}/` | someone else delivered it |

`done/` is the record of what this workspace shipped - `/nase:effort-rollup` reads it
as the month's delivery and `/nase:efforts` counts it. An effort this workspace only
*watched* would inflate both, so it skips `done/` and lands directly in the year
archive that time-expired `done/` efforts eventually reach anyway.

`tracking_only: true` is deliberately separate from `status: tracked`. Status is
overwritten by every transition (`tracked` -> `in-progress` -> `awaiting-deploy`
-> `completed`); ownership is not, so a flag that must survive to the terminal move
cannot live in `status:`. Set `tracking_only: true` alongside `owner:` when a
different engineer owns code delivery and this workspace only tracks, reviews, and
unblocks.

Efforts already in `done/` age out to `workspace/efforts/archive/{YYYY}/` after 60
days via `pre-compact-archive.sh`, so both paths converge - the flag only decides
whether the effort passes through the delivery record on its way there.

## Multi-Deliverable Efforts

Most efforts ship as one PR, and the delivery-PR set describes them completely. An
effort that plans several PRs does not have that property: until PR 2 is opened it
may exist only as prose (`Target PR count: 3`, an SE/phase table). The classifier
compares the highest declared `Target PR count` with the live structured delivery-PR
set so legacy docs fail closed instead of reading "1 of 1 merged" when the truth is
"1 of 3".

**Give every planned deliverable its own unchecked `## Lifecycle` row.** That row is
the only thing standing between a half-finished initiative and the `done/` pile:

```markdown
## Lifecycle
- [x] Design approved - 2026-01-15
- [x] Implementation started - 2026-01-16 (PR1 only)
- [x] PR opened - PR1 https://github.com/acme/platform/pull/101
- [ ] PR2 - cache the health probe
- [ ] PR3 - add deployment verification
- [ ] Investigation - identify the remaining caller (no PR)
- [ ] Deployed (if applicable)
```

Tick each row as its PR lands. `effort-state.py` treats a remaining unchecked row as
an owed deliverable and refuses the `awaiting-deploy` transition.

Rows that stay unchecked *because* the effort is waiting on a deploy do not count, or
nothing could ever transition: `Deployed...`, `Merged`, `Review passed`, `Outcome: ...`,
`Effort doc moved...`, `Follow-up: ...` (which has its own `pending_followups` path),
and explicit status rows beginning with `Post-deploy`, `Verified`, `Validated`,
`Validation complete`, or an environment plus `validation complete`. Checkboxes
**outside** every `## Lifecycle` section are implementation-plan steps that
authors routinely leave unticked after the work lands, so they are ignored entirely.

A trailing clause on a *checked* row (`PR opened — PR-1 #173; PR-1b + PR-2 still
pending`) is also honoured, since older docs record outstanding work that way. Prefer
separate rows — the clause match only covers a few phrasings ("still pending", "not
started", "remains pending", "yet to be opened") and a novel wording will slip past it.

**When the gate fires on a row that is not actually owed** — a plan step that drifted
into `## Lifecycle`, or a row nobody ticked after the work shipped — fix the document:
tick it, reword it, or move it out of the section. Do not work around the gate; the
row is the contract, and a wrong row will mislead the next reader too.

## Dependency & Discovery Fields

Two optional frontmatter keys make dependencies first-class instead of prose buried
in the body, so `/nase:efforts` can compute an unblocked-work view without parsing
each doc body. Both are optional — omit when not applicable.

| field | value | meaning |
|---|---|---|
| `blocked-by` | effort slug, PR reference, Jira key, or short free text | this effort cannot proceed until the referent clears |
| `discovered-from` | effort slug, PR reference, or incident/ticket ref | this effort was spun off while working the referent (captures work that would otherwise be noticed and lost) |

`blocked-by` may be a single value or a YAML list. Clearing the blocker: remove the
key (or set `status:` off `blocked`). A blocker counts resolved when an effort slug is
no longer active - `workspace/efforts/done/{slug}.md` **or** any
`workspace/efforts/archive/*/{slug}.md` exists, since a tracking-only blocker closes
into the archive - a PR is merged, or a Jira issue is Done. Short free text has no
resolver, so it stays unresolved until removed. A `blocked-by` whose value reads as
"nothing" (`none`, `n/a`) is still free text with no resolver and will read as blocked:
delete the key instead of writing a placeholder into it.

**Computed "unblocked" view** (read-only, no stored field): an active effort is
*unblocked* when `status:` is not `blocked` **and** it has no unresolved `blocked-by`.
This is distinct from the `ready` status token above (which is a manual alias). Callers
must compute unblocked from `status` + `blocked-by`, never store it.

## Single-File Invariant

One effort = one file: `workspace/efforts/{slug}.md`. Do **not** spawn per-phase
sidecar files (`{slug}-phase-2.md`, `{slug}-plan-v3.md`, etc.) — that is the failure
mode that decays into hundreds of orphan plan files. All phase progress appends to the
single doc: check the `## Lifecycle` boxes, add `phase_*_pr:` frontmatter pointers for
per-phase PRs, and append notes in-place. A restarting agent re-reads the one doc rather
than reconstructing intent from a pile of stale siblings.

