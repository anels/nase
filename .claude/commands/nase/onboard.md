---
name: nase:onboard
description: "Onboard or refresh repo context in the workspace KB. Use before repo work or for onboard, refresh KB, refresh all repos, add repo, a repo path, or a GitHub URL."
argument-hint: "[repo-path-or-url|--force]"
category: Knowledge base
---

Build or refresh compact repo knowledge without dumping the repository into context. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/workspace-write-guard.md`, `.claude/docs/kb-write-routing.md -> Shared admission contract`, and `.claude/docs/kb-template.md`.

## Mode

- No repo argument: batch-refresh every valid repo in `workspace/context.md`. **Valid** excludes any repo whose domain-map
  entry carries `retired:` per `.claude/docs/repo-resolution.md -> Retired entries`; report those under a separate retired
  count rather than as skips, so a permanent exclusion never reads as a transient failure.
- `--group <name>`: scope the batch to one project group from `.claude/docs/repo-resolution.md -> Project groups`. Accepts a
  repeated flag or a comma-separated list. Match group names case-insensitively; an unknown name is an error that lists the
  available groups, never a silent full run.
- No repo argument and no `--group`: before enumerating, offer the groups through `AskUserQuestion` (multi-select, plus an
  all-groups option) so a routine refresh does not default to the whole map. Skip the prompt when the caller is
  non-interactive or already passed `--group`.
- Path or GitHub URL: resolve one repo through `.claude/docs/repo-resolution.md`.
- `--force`: bypass the content-hash skip, never safety or drift gates. It does not authorize a no-op KB write. It does not
  un-retire an entry either: retiring is a durable statement about the upstream, not a stale cache.

A group scope narrows **which repos are refreshed**. It never narrows the gates applied to a repo that is in scope, and it
never suppresses a finding about an out-of-scope repo that the in-scope work surfaced.

## Shared gates

1. Validate the repo path, git state, default branch, upstream, and access. Never change a dirty or non-default checkout during onboarding.
2. Read the repo's `CLAUDE.md`, README, build manifests, and docs before broad code scans.
3. Probe tools once with:

```bash
python3 .claude/scripts/tool-availability.py --group baseline --group repo --group ci --format json
```

Use available tools per `.claude/docs/cli-tooling.md`, and never write this machine-local availability into the repo KB.
4. Run `.claude/scripts/kb-hygiene-scan.py` before updating an existing entry, then classify each finding with `.claude/docs/kb-hygiene.md`. That doc owns which facts this command may auto-fix from repo `HEAD` and which must be reported instead of rewritten; a scanner finding is not by itself permission to edit.
5. Compute the content hash per `.claude/docs/content-hash-cache.md`; skip unchanged repos unless forced. When the repository yields no durable knowledge change, keep every KB target file byte-identical even under `--force`.

## Single repo

1. Map purpose, architecture, entry points, data/control flow, tests, CI, deployment, ownership, operational boundaries, brittle edges, and current workbench commands.
2. Cite exact files and commands. Separate confirmed facts, inferred relationships, and unknowns. Apply `.claude/docs/kb-template.md -> Verification triad` to every new durable claim; V2 and V3 are admission gates.
3. For Microsoft technologies, apply `.claude/docs/ms-learn-grounding.md`. For ADO pipelines, use `.claude/docs/azure-pipeline-kb-extract.md`.
4. Reconcile current-state sections in place, then draft only the focused project KB, domain-map, or context changes supported by new durable evidence. Do not add dated refresh blocks, HEAD/count/status heartbeats, hygiene summaries, or placeholders. Stage each changed full file, show diffs, and apply only after mtime/hash/staged-hash checks.
5. Run `.claude/docs/cross-repo-validation.md` against any shared claim before promoting it to general KB. Keep the validation receipt in the command output or report; do not add a status-only footer to the KB file.

## Batch refresh

Resolve all configured repos first, apply the group scope when one is set, then process independent clean repos in bounded parallel slices. Skip missing, inaccessible, dirty, or unchanged repos with explicit reasons. Each repo keeps an independent staged diff and drift check; one failure does not invalidate successful siblings.

Finish with refreshed/skipped/retired/failed counts, changed KB paths, evidence gaps, and the next scheduled refresh. Name the group scope and the groups left untouched, so a partial refresh is never mistaken for a full one. Append the daily-log entry.
