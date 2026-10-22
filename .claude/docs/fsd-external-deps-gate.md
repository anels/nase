# FSD External-Dependency Research Gate

Loaded from `.claude/docs/fsd-implementation-loop.md` Phase 3.5 only when the task depends on an external API, library, framework, SDK, CLI, service, or platform behavior. KB and `CLAUDE.md` can satisfy familiar repo patterns, but not current external facts.

1. **Pin the version** from manifests, lockfiles, SDK config, or the service tier/config. An unpinned lookup is a guess about which behavior applies.
2. **Choose a source** in this order: `ms-learn` / `context7`, then official docs, then pinned source or changelog, then issue trackers. Follow `.claude/docs/design-research.md → Part A: External Research` for the ladder's details.
3. **Extract** method signatures, required parameters, return types, version constraints, and common pitfalls.
4. **Hold it** for Phase 4. Do not write it to KB yet; Phase 8c owns persistence.

Record every finding as `research_gate_findings`, even when obvious, so a later step does not re-research it:

```
research_gate_findings:
  - {LibraryName}: key method signatures, required params, return types, pitfalls, doc URL
```

Direct and phase-isolated runs keep the block in context. Team runs also write it to `workspace/tmp/fsd-research-{branch_slug}.md` for Phase 8c and the subagent prompts.
