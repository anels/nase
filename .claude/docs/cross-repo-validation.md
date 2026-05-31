# Cross-Repo Cross-Validation

Used by `/nase:onboard` after Single Repo Mode and after Batch Refresh Mode (Step 6) to keep the per-repo KBs consistent with each other and with the cross-project tracker.

The goal is to catch drift — a claim in one repo's KB that contradicts another's reality — and surface it to the user. **Read-only by default.** Never auto-mutates KB content; produces a diff report and asks before writing.

The three checks below are independent. Skip any that the user opts out of. In batch mode, run all three once at the end (not per-repo) so the inputs are fresh.

---

## Inputs

- All `workspace/kb/projects/*.md` files (one per repo)
- `workspace/kb/cross-project/insights-integrations.md` (or the configured cross-project tracker file)
- `workspace/context.md` (team roster + declared focus areas)
- `.local-paths` (repo paths for git operations)

Resolve repo paths via `.claude/docs/repo-resolution.md`. Pre-filter the repo list once against `.local-paths` before any git operations; repos without a local path are noted as 🟦 in the report and skipped for git-backed checks (don't discover the gap mid-loop).

**Shared KB map**: read all `workspace/kb/projects/*.md` files once into a parsed structure `{repo → {ownership, inbound, outbound, related, deployment}}` and pass that structure to 6a / 6b / 6c. The three checks read overlapping fields — re-reading per check triples I/O on a 20-repo workspace.

---

## 6a. Ownership Consistency Check

Verify that each repo's `## Ownership Map` (derived from git log in Step 3g) does not contradict the team's declared focus in `workspace/context.md`.

### Algorithm

1. For each repo with a `## Ownership Map` section in its KB, extract `(area, primary_owner, secondary_owner)` rows.
2. Read `workspace/context.md` → `## Team` section. Extract `(person, declared_focus_areas)` mappings.
3. For each repo's Primary Owner, check whether the declared focus in `context.md` mentions this repo (by name) or its domain.
4. Flag mismatches in three classes:
   - **Undeclared owner** — person is Primary Owner per git log but `context.md` does not list this repo in their focus.
   - **Phantom focus** — person's `context.md` focus lists this repo but they have 0 commits in last 6 months.
   - **Dormant primary** — declared Primary Owner has not committed to the area in 6+ months (loss of context risk).

### Output format

Append to the report:

```markdown
## Ownership consistency

### Undeclared owners (people own code per git log but it's not in their context.md focus)
- **{Name}** owns `{repo}/{area}` ({N} commits, last {date}) — not in context.md focus
- ...

### Phantom focus (context.md lists repo but no commits)
- **{Name}** has `{repo}` in focus but 0 commits in 6 months
- ...

### Dormant primaries (declared owner has gone quiet)
- `{repo}/{area}` — declared owner **{Name}** last committed {date}
- ...
```

If a section is empty, write `- (none)` under it so the report's structure is preserved.

### How to act on it

Show the report. If non-empty, prompt the user with `AskUserQuestion`:
- Update `workspace/context.md` to reflect reality (the typical fix)
- Update the offending repo's `## Ownership Map` to align with `context.md` (if git log is misleading)
- Skip (false positive, e.g. recent role change not yet reflected)

Never silently update either file — the user owns the truth-source.

---

## 6b. Auto-Update Cross-Project Tracker

Re-derive the cross-project tracker (e.g. `workspace/kb/cross-project/insights-integrations.md`) from per-repo KB content so it stays in sync with reality.

### When to run

- After batch refresh of 2+ repos that all belong to the same cross-project tracker
- After single onboard of a repo that introduces a new integration

### Algorithm

1. Read the cross-project tracker's `## Master Matrix` (capability × deployment, or whatever axes the tracker uses).
2. Read each candidate repo's KB and extract:
   - `## Overview → Purpose` line (capability declaration)
   - `## Deployment → Environments & Rollout` (deployment forms)
   - `## Related Repos` (cross-repo edges)
   - Any explicit `<!-- cross-project-key: ... -->` HTML comment hint
3. For each axis in the Master Matrix, recompute the cell value from current per-repo KB content.
4. Diff the recomputed matrix against the existing tracker file.
5. Build inverted edges from `## Related Repos` claims:
   - Source: RepoA KB says "calls RepoB for X"
   - Target: index entry `RepoB ← RepoA (X)`
6. Append the inverted index to the tracker as a `## Cross-References (auto-derived)` section.

### Output

Present diff to user via `AskUserQuestion` with three options:
- Apply diff (overwrite tracker)
- Show full diff first
- Skip (user will reconcile manually)

If applied, update `<!-- Last updated: ... -->` on the tracker.

### Constraints

- Preserve any section in the tracker that has `<!-- manual: keep -->` directly above it — do not rewrite.
- Preserve external links and prose commentary that don't appear in per-repo KBs.
- If the tracker has no `## Master Matrix` heading, skip the auto-update silently (tracker is freeform; user-owned).

---

## 6c. Contract Consistency Check

For each repo KB's outbound calls (Step 3b → `## Outbound Calls`), verify the target repo's KB advertises a matching inbound endpoint.

### Algorithm

0. **Early-exit guard** — count KBs that contain a non-empty `## Outbound Calls` table (rows beyond the header). If zero, emit one line and skip the rest of 6c:
   ```
   ## Contract consistency
   - skipped — no repos have populated `## Outbound Calls` tables yet. Re-onboard repos to populate (the new schema is in `.claude/docs/kb-template.md`).
   ```
   This avoids a wall of 🟦 Unknown during the rollout window when most KBs predate the new template.
1. Build a map of all repos with KB files: `{repo_name → kb_path}`.
2. For each repo, parse its `## Outbound Calls` table. Each row claims `(target_repo, method/topic, path/queue, payload_shape)`.
3. For each claim, open the target repo's KB and check its `## Inbound Endpoints` (REST/gRPC) or `## API Surface → message queue topics`:
   - **Route match**: target has a row with the same method + path (or queue + message shape).
   - **Auth match**: target's auth column matches the source's claim (e.g. both say JWT, or both say MSI).
   - **Payload shape**: target documents a request schema that's compatible with what source sends.
4. Classify each outbound claim:
   - ✅ **Verified** — target advertises matching endpoint with compatible auth + payload.
   - ⚠️ **Partial match** — endpoint exists but auth or payload differs.
   - ❌ **Drift** — target has no matching endpoint.
   - 🟦 **Unknown** — target repo has no KB or no `## Inbound Endpoints` section.

### Output format

```markdown
## Contract consistency

### ❌ Drift ({N} claims with no match on target)
- `{source_repo}` claims `{METHOD} {target_repo}{path}` ({source KB line ref}) — target KB has no matching endpoint
- ...

### ⚠️ Partial match ({N} mismatched auth or payload)
- `{source_repo}` → `{METHOD} {target_repo}{path}` — source says `{auth_a}`, target says `{auth_b}`
- ...

### 🟦 Unknown ({N} claims point to repos without KB)
- `{source_repo}` → `{target_repo}{path}` — no KB at `workspace/kb/projects/{target_domain}.md`
- ...

### ✅ Verified ({N} claims passed)
- (collapsed by default; show count only)
```

### How to act on it

For each `❌` and `⚠️` row, suggest concrete fixes:
- If target repo has the endpoint but it's just not in its KB → run `/nase:onboard {target_repo}` to refresh.
- If target repo genuinely no longer has the endpoint → source repo's KB is stale; re-onboard source.
- If both are current → real contract drift; open an effort doc to coordinate the cross-team fix.

Never auto-fix. The whole point is to catch drift the LLM can't safely resolve without human context.

---

## Performance

All three checks read KB files only (from the shared map built in Inputs) plus run a few `git log` queries (Step 6a only). Total cost on a 20-repo workspace: < 30s when all repos have current KBs. Add a `--skip-cross-validation` flag for users who want to bypass.

In batch mode, dispatch 6a / 6b / 6c **in parallel** — their inputs are independent. Buffer outputs and render the final report in fixed `6a → 6b → 6c` order so the user reads it top-to-bottom.

**No-change guard for `Last cross-validated` writes**: when updating each KB's `## Cross-Validation Notes` footer, skip the write entirely if the prior summary line is identical except for the date and the previous date is within 7 days. Avoids 20 single-line diffs every batch run.

---

## Failure modes & graceful degradation

- **KB missing for a referenced repo** — note as 🟦 Unknown, do not block.
- **`context.md` has no `## Team` section** — skip 6a, print one-line warning.
- **No cross-project tracker exists yet** — skip 6b silently.
- **No `## Outbound Calls` in any KB** — skip 6c silently (most repos haven't been re-scanned with the deeper schema yet; it'll populate over time).

Always emit the report header even if all sections are empty — gives the user proof the check ran.
