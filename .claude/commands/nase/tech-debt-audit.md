---
name: nase:tech-debt-audit
description: "Audit a repo for tech debt, architecture gaps and shallow modules, modernization, and AI verification debt. Use for a tech debt audit or deepening opportunities."
argument-hint: "<repo-path>"
category: Security & maintenance
model: sonnet
effort: high
disable-model-invocation: true
---

Produce an evidence-backed audit without editing the target repository. Follow `.claude/docs/confidential-marker.md` and `.claude/docs/skill-contract.md`.

## Workflow

1. Resolve the repo with `.claude/docs/repo-resolution.md`. With no `$ARGUMENTS`, resolve the current checkout and name it back to the user before scanning; ask only when resolution is ambiguous. Then load its CLAUDE.md, README/docs, KB, dependency manifests, CI, tests, and recent history. Delegate the file-reading half of that orientation pass to `nase-repo-state-scanner`, which is read-only and returns the structure summary rather than the file dumps. It is `Read, Grep, Glob` with no Bash by design, so run the history reads (`git -C {repo} log`, tags, churn) in the main thread and pass the output into its prompt as supplied evidence, exactly as `.claude/agents/nase-repo-state-scanner.md` states. Do not widen the agent.
2. Establish scope, languages, generated/vendor exclusions, and required build/test commands. Reject an invalid or unreadable target. Then decide where to look first, because deepening a module pays off where change lands. If the request names a direction (a module, a subsystem, or a pain point), scan that first and skip the inference. Otherwise take the hot spots from the churn reads in step 1 (the command below counts them), drop the excluded paths, lockfiles, and generated files from that list, and weight the sweep toward the top ones. If changes are scattered with no clear hot spot, widen the sweep.

```bash
git -C {repo} log --since="6 months ago" --name-only --pretty=format: | grep -v '^$' | sort | uniq -c | sort -rn | head -30
```
3. Run an Optional scanner seed pass after probing:

```bash
python3 .claude/scripts/tool-availability.py --group repo --group security --group ci --format json
```

Use installed tools only. Typical seeds include `semgrep`, `trivy`, `actionlint`, `shellcheck`, and language-native analyzers. Scanner output is a lead, never a finding by itself.
4. Inspect architecture boundaries, duplication, obsolete dependencies, unsafe defaults, reliability/observability gaps, testability, operational toil, and modernization opportunities. This is the audit's breadth sweep and its answer is a candidate list, so split it by concern and fan out to read-only **verifier** agents (role `verifier` per `.claude/roles.yaml`: `model=sonnet`, `effort=medium`). Keep ranking and the write-up in the main thread. Pass the hot-spot paths from step 2 into each sweep prompt as supplied evidence.

   Include shallow modules in the architecture concern, using the terms in `.claude/docs/design-principles.md → Module shape`. Friction signals to look for are these.
   - Understanding one concept means bouncing between many small modules.
   - An interface is nearly as complex as its body.
   - Pure functions were extracted only for tests, while the real bugs hide in how they are called.
   - Tightly coupled modules leak across a seam.
   - Code is hard to test through its current interface.

   Apply the deletion test to every shallow-module suspect before it becomes a candidate. If deleting it makes the complexity vanish, or merging the cluster concentrates it in one place, record the candidate and what the test showed. If the complexity would reappear across several callers, the module earns its place, so drop it. This is the same test as `design-principles.md → Module shape`.
5. Apply `.claude/docs/ai-code-verification-debt.md` to AI-shaped or weakly verified code. Do not attribute authorship without evidence.
6. For every candidate, trace callers/config/runtime impact and collect `path:line`, command, test, or source evidence. Drop unverified candidates. A candidate that contradicts a documented decision (an ADR, a KB constraint, or CLAUDE.md) is kept only when the friction is real. Mark it `contradicts {source}`, and do not list every refactor that a decision forbids.
7. Run the `tech-debt-review` sanity pass from `.claude/docs/review-mode-tech-debt.md` in one fresh-context read-only subagent (role `verifier` per `.claude/roles.yaml`: `model=sonnet`, `effort=medium`, prompt prefixed with that role's `prompt_prefix`). The prefix is what keeps the pass read-only, because the Agent tool has no tool whitelist for a role, so say "do not edit files" in the prompt. A pass that re-reads the candidates without the audit's own reasoning is what catches a candidate the audit talked itself into.
8. Validate report citations with `.claude/docs/citation-validator.md`. Rank only confirmed issues by impact, breadth, recurrence, and remediation sequence. Keep the `--format json` payload for step 9.
9. Write the full audit to `workspace/recaps/tech-debt-{repo}-{YYYY-MM-DD}.md`; chat returns the pointer and top findings. Then persist the payload from step 8 as `workspace/recaps/tech-debt-{repo}-{YYYY-MM-DD}.md.receipt.json` per `.claude/docs/citation-validator.md → Persist the receipt`.
10. Any proposed KB update is separate, previewed, and applied through `.claude/docs/workspace-write-guard.md`.

Name modules with the repo's own domain terms (KB terminology or its `GLOSSARY.md`), and describe their shape with the Module shape terms. The audit proposes no new interface. When the user wants to pursue a deepening candidate, hand it to `/nase:design`, which owns the interface choice.

Report scanner/tool/access gaps separately from repository defects. No finding may rely only on a pattern match, age, style preference, or remembered best practice.
