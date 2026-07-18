---
name: nase:onboard
description: "Onboard or refresh repo context in the workspace KB. Use before repo work or for onboard, refresh KB, refresh all repos, add repo, a repo path, or a GitHub URL."
argument-hint: "[repo-path-or-url|--force]"
pattern: pipeline
category: Knowledge base
sub-patterns: [fan-out]
---

Build or refresh compact repo knowledge without dumping the repository into context. Follow `.claude/docs/language-config.md`, `.claude/docs/workspace-write-guard.md`, and `.claude/docs/kb-template.md`.

## Mode

- No repo argument: batch-refresh every valid repo in `workspace/context.md`.
- Path or GitHub URL: resolve one repo through `.claude/docs/repo-resolution.md`.
- `--force`: bypass the content-hash skip, never safety or drift gates.

## Shared gates

1. Validate the repo path, git state, default branch, upstream, and access. Never change a dirty or non-default checkout during onboarding.
2. Read the repo's `CLAUDE.md`, README, build manifests, and docs before broad code scans.
3. Probe tools once with:

```bash
python3 .claude/scripts/tool-availability.py --group baseline --group repo --group ci --format json
```

Use available tools per `.claude/docs/cli-tooling.md`, and never write this machine-local availability into the repo KB.
4. Run `.claude/scripts/kb-hygiene-scan.py` before updating an existing entry.
5. Compute the content hash per `.claude/docs/content-hash-cache.md`; skip unchanged repos unless forced.

## Single repo

1. Map purpose, architecture, entry points, data/control flow, tests, CI, deployment, ownership, operational boundaries, brittle edges, and current workbench commands.
2. Cite exact files and commands. Separate confirmed facts, inferred relationships, and unknowns.
3. For Microsoft technologies, apply `.claude/docs/ms-learn-grounding.md`. For ADO pipelines, use `.claude/docs/azure-pipeline-kb-extract.md`.
4. Draft one focused project KB entry plus domain-map/context changes. Stage each full file, show diffs, and apply only after mtime/hash/staged-hash checks.
5. Run `.claude/docs/cross-repo-validation.md` against any shared claim before promoting it to general KB.

## Batch refresh

Resolve all configured repos first, then process independent clean repos in bounded parallel slices. Skip missing, inaccessible, dirty, or unchanged repos with explicit reasons. Each repo keeps an independent staged diff and drift check; one failure does not invalidate successful siblings.

Finish with refreshed/skipped/failed counts, changed KB paths, evidence gaps, and the next scheduled refresh. Append the daily-log entry.
