# Voice Profile Routing

Use this before drafting external text on Ruilin's behalf. It is a routing layer, not a second source of truth.

Source of truth: `workspace/communication-style.md`.

## Algorithm

1. Classify the output surface before drafting.
2. Read the capsule for that surface below.
3. Read the full `workspace/communication-style.md` when the draft is high-stakes, user-facing beyond the immediate team, ambiguous, or the capsule does not cover the surface.
4. Draft from facts gathered by the workflow; do not invent names, scope, ownership, deadlines, or test evidence.
5. Final pass: remove greetings, AI-flavor words, unsupported praise, and hidden URL embeds. Defer AI attribution to `.claude/docs/ai-attribution.md`; this routing layer does not decide attribution.

## Surface Capsules

| Surface | Load | Shape |
|---------|------|-------|
| `slack-dm` | Slack + AI checklist sections from `workspace/communication-style.md` when needed | No opener, very short, raw URL, `pls` in informal asks, English unless the recipient is a Chinese-native colleague. For PR asks, write `Could you help review {url} - {TLDR}` or `{url} @{reviewer} pls help review`; do not write `review this?` when the URL is already present. |
| `slack-channel` | Slack + incident / announcement rules | English, direct context first, bullets for technical updates, `cc:` / mentions for affected people, no blame. Incident shape: symptom -> cause -> current status -> action request. |
| `github-pr-body` | PR body rules + AI banned list | Follow `.claude/docs/pr-creation-pattern.md` for template/default structure and `.claude/docs/ai-attribution.md` for attribution. Keep reviewer-facing prose concise and concrete. Never mention local workspace paths. |
| `github-review-comment` | Review/comment rules + no-blame rules | One to two sentences. Lead with the concrete failure mode, cite the path or behavior, and include a fix direction only when it is clear. Avoid vague asks like `consider improving this`. |
| `github-review-reply` | Review/comment rules + no-blame rules | For declines or reply-only threads, stay direct and non-defensive. Cite concrete evidence for this thread. Keep each reply at three lines or less. **When the reviewer is a bot / AI (Copilot, Codex/`chatgpt-codex-connector`, `claude`, CodeRabbit, Sonar, any `*[bot]`), skip courtesy openers entirely — no "good catch", "nice catch", "good job", "thanks for bringing this up". A bot does not read tone, so the opener is pure noise that buries the evidence and reads as AI filler. Open on the substance: the finding, the disagreement, or the fix. Warmth stays available for human reviewers.** |
| `jira-ticket` | Jira + external doc rules | Context -> evidence -> scope -> acceptance -> references. Include full Jira/GitHub/Confluence URLs. Make the ticket directly actionable without chat history. |
| `confluence-doc` | Confluence / RFC / strategy rules | Metadata, TLDR, tradeoffs, open questions, decision owners, and proof gates. Credit named contributors when summarizing shipped work. |
| `announcement` | People/process announcement rules | Background -> process/change -> time/scope -> optionality. Warmth goes up for people/team events; do not use generic farewell or celebration copy. |

## Caller Contract

- Shared docs should point to this routing doc instead of duplicating long style rules.
- Workflow commands should name the surface at the output boundary, for example `surface=github-pr-body` before PR body generation.
- If a user edits a draft in a way that generalizes, follow `.claude/docs/style-delta-capture.md`; do not update `workspace/communication-style.md` silently.
