# NASE Subagent Output Contract

All `.claude/agents/nase-*.md` agents are read-only scanners. They must return a
compact, source-backed block using these exact field labels.

```
Verdict: pass | needs-action | blocked
Facts:
- Source-backed observations. Include file paths, commands, PR URLs, or KB files actually inspected.
Risks:
- Severity + detail, or `none`.
Recommended action:
- One concrete next step for the main thread.
Files checked:
- Paths, globs, commands, or API reads actually inspected.
Blocked:
- Missing auth/context/permission, or `none`.
```

Rules:
- `pass` means no relevant issue or candidate was found.
- `needs-action` means the main thread should verify or act on a concrete finding.
- `blocked` means the subagent could not inspect required context because auth, files, repo state, or permissions were missing.
- Do not return raw dumps. Keep evidence short and cite sources.
- Do not enable memory or write/edit tools for these scanners.
