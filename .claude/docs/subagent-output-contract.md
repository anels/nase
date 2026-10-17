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

Search discipline (these are review/lookup lanes, not open-ended exploration):
- Start from the concrete artifact (diff, PR metadata, named file/path) and form a specific question before searching. Do not widen a search to "understand the area."
- Narrow before reading: use Grep/Glob to locate exact paths/ranges first, then Read only those ranges. Do not read whole files to browse.
- Batch discovery (multiple greps/globs) before reads; batch the focused reads. Do not alternate one search / one read.
- On a failed search, retry with a simpler query or pivot to Glob. Never guess neighboring paths - path-guessing accumulates junk context and cascades into exploration loops.
- Every tool result is costly persistent context. Pull evidence, not background.
- Rationale: [GitHub's 2026-07-10 analysis](https://github.blog/ai-and-ml/github-copilot/better-tools-made-copilot-code-review-worse-heres-how-we-actually-improved-it/) found that generic exploration instructions made reviews costlier and less effective; review-specific instructions then cut average cost about 20% at held quality. This discipline is scoped to review/verification; open-ended tasks legitimately search broad.

## Fan-out slices

When a skill dispatches several scanners over disjoint KB domains or repos:

- Brief each slice for facts only: path, line, quoted text. Do not ask it to triage, classify, or write a report. `Risks` and `Recommended action` in the return block are leads for the main thread, not findings.
- Cap each slice by file count in its brief, because a slice cannot see its own turn counter. Set the cap to about half the `maxTurns` in its agent frontmatter (read that value when briefing, do not copy a number). Tell the slice to return what it has when it hits the cap: `Verdict: needs-action`, the facts so far, `Files checked:` for what it read, and a `Risks:` line that says the cap was reached and names what is unread. A slice that runs out of turns returns nothing, and a slice that returns nothing is a failed slice for the main thread to re-dispatch or read itself.
- The main thread classifies the facts and re-checks each claim against source before any write or report line, including file counts, files-read coverage, and any report that a shared doc is missing. Expect some slices to need correction.
