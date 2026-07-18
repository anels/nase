---
name: nase:init
description: "Initialize or reconfigure an idempotent nase workspace. Use for first-time setup, a new machine, missing workspace/config.md, init nase, configure, or bootstrap."
argument-hint: "[--reconfigure]"
pattern: pipeline
category: Setup & health
---

Initialize only this checkout's ignored workspace state. Existing values are defaults; reruns must be idempotent.

## Workflow

1. Inspect `workspace/config.md`, `.local-paths`, backup target, and existing workspace content. Without `--reconfigure`, ask only for missing required values.
2. Batch the required inputs: AI name, workspace name, backup target, retention, `conversation:` language, and `output:` language. Keep GitHub work/personal accounts optional.
3. If Jira or Slack configuration is requested, collect identifiers only. Never request or persist passwords, PATs, OAuth tokens, client secrets, or cookies.
4. For a fresh workspace with backup content, inspect available archives and show the exact candidate. Require explicit confirmation before `/nase:restore`; never merge an archive blindly.
5. Verify hook wiring and executable bits. Report changes needed outside the repo instead of silently editing user-level Claude configuration.
6. Create the skeleton in one bounded command:

```bash
mkdir -p workspace/kb/projects workspace/kb/general workspace/kb/people workspace/tasks workspace/efforts/done workspace/logs workspace/journals workspace/recaps workspace/stats workspace/tmp workspace/skills
```

7. Write only missing stubs and preserve existing content. Create `workspace/config.md`, `workspace/context.md`, `workspace/kb/.domain-map.md`, task/log directories, and `.local-paths` entries needed on this machine.
8. Follow `.claude/docs/workspace-runtime-config.md` for key names and `.claude/docs/language-config.md` for language behavior. Machine-specific paths stay in `.local-paths`, never tracked docs.
9. Run `/nase:doctor`. Treat failed required checks as incomplete initialization.
10. Offer the optional repository star only after setup succeeds and only with an explicit GitHub confirmation.

Finish with configured paths, languages, backup status, doctor result, and the next command. Never overwrite an existing KB, log, task, effort, skill, or local-path value without showing the change.
