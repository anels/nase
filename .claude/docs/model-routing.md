# Model Routing (subagents) - Shared Reference

Read this when spawning an ad hoc subagent or choosing a role. `CLAUDE.md` keeps only the survey-delegation rule.

Project-level subagent prompts live in `.claude/agents/`. `.claude/roles.yaml` defines lightweight local role names for ad hoc subagent routing.
Use the persisted agents when a workflow names them; use roles.yaml when a workflow only needs `lookup`/`worker`/`verifier`/`checker`/`architect` model and effort routing.
The only enforced tool whitelist for a subagent is the `tools:` frontmatter of a persisted agent in `.claude/agents/*.md`. A role in `roles.yaml` supplies `model`, `effort`, and a `prompt_prefix` as advisory metadata, and this Claude Code build's Agent tool has no `tools` parameter, so a spawn site names the role and passes `model` and `effort` without claiming a whitelist. `lookup`, `verifier`, and `checker` are read-only by their prompt prefix, not by enforcement. Default `worker`; do not use `architect` for lookup work.
