---
name: nase:tech-debt-audit
description: "Audit a repo for tech debt, architecture gaps, modernization, and AI verification debt. Use for tech debt audit, architecture review, or modernization."
argument-hint: "<repo-path>"
pattern: pipeline
category: Security & maintenance
---

Produce an evidence-backed audit without editing the target repository. Run `.claude/docs/language-config.md`, `.claude/docs/confidential-marker.md`, and `.claude/docs/skill-contract.md` first.

## Workflow

1. Resolve the repo with `.claude/docs/repo-resolution.md`; load its CLAUDE.md, README/docs, KB, dependency manifests, CI, tests, and recent history.
2. Establish scope, languages, generated/vendor exclusions, and required build/test commands. Reject an invalid or unreadable target.
3. Run an Optional scanner seed pass after probing:

```bash
python3 .claude/scripts/tool-availability.py --group repo --group security --group ci --format json
```

Use installed tools only. Typical seeds include `semgrep`, `trivy`, `actionlint`, `shellcheck`, and language-native analyzers. Scanner output is a lead, never a finding by itself.
4. Inspect architecture boundaries, duplication, obsolete dependencies, unsafe defaults, reliability/observability gaps, testability, operational toil, and modernization opportunities.
5. Apply `.claude/docs/ai-code-verification-debt.md` to AI-shaped or weakly verified code. Do not attribute authorship without evidence.
6. For every candidate, trace callers/config/runtime impact and collect `path:line`, command, test, or source evidence. Drop unverified candidates.
7. If Codex MCP is configured, follow `.claude/docs/codex-review.md → Prerequisite` and run the read-only tech-debt review mode. If unavailable, skip cleanly and keep the local evidence pass.
8. Validate report citations with `.claude/docs/citation-validator.md`. Rank only confirmed issues by impact, breadth, recurrence, and remediation sequence.
9. Write the full audit to `workspace/recaps/tech-debt-{repo}-{YYYY-MM-DD}.md`; chat returns the pointer and top findings.
10. Any proposed KB update is separate, previewed, and applied through `.claude/docs/workspace-write-guard.md`.

Report scanner/tool/access gaps separately from repository defects. No finding may rely only on a pattern match, age, style preference, or remembered best practice.
