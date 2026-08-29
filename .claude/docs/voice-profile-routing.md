# Voice Profile Routing

Use this before drafting external text on Ruilin's behalf. It is a routing layer, not a second source of truth.

Source of truth: `workspace/communication-style.md` for voice, `.claude/docs/plain-writing-guard.md` for the readability floor that applies to every surface.

## Algorithm

1. Classify the output surface before drafting.
2. Read the capsule for that surface below.
3. Read the full `workspace/communication-style.md` when the draft is high-stakes, user-facing beyond the immediate team, ambiguous, or the capsule does not cover the surface.
4. Draft from facts gathered by the workflow; do not invent names, scope, ownership, deadlines, or test evidence.
5. Final pass, in this order: shape, syntax, register, templated shapes - `plain-writing-guard.md` Parts 1 to 4. Remove greetings, unsupported praise, and hidden URL embeds. Defer AI attribution to `.claude/docs/ai-attribution.md`; this routing layer does not decide attribution.
6. Mechanical pass: `python3 .claude/scripts/prose-lint.py --surface <surface> --file <draft>`. Gate findings must reach zero. Markers above the threshold mean the shape needs a rewrite, not a word swap - go back to step 5, not to the vocabulary. The script is a pattern counter and is never evidence of authorship.

## Surface Capsules

| Surface | Load | Shape |
|---------|------|-------|
| `slack-dm` | **`.claude/docs/slack-draft-style.md` → Formatting Mechanics + Quick Checklist (mandatory)**, plus AI checklist sections from `workspace/communication-style.md` when needed | No opener, very short, raw URL, `pls` in informal asks, English unless the recipient is a Chinese-native colleague. For PR asks, write `Could you help review {url} - {TLDR}` or `{url} @{reviewer} pls help review`; do not write `review this?` when the URL is already present. |
| `slack-channel` | **`.claude/docs/slack-draft-style.md` → Formatting Mechanics + Quick Checklist (mandatory)**, plus incident / announcement rules | English, direct context first, bullets for technical updates, `cc:` / mentions for affected people, no blame. Incident shape: symptom -> cause -> current status -> action request. |
| `github-pr-body` | PR body rules + AI banned list | Follow `.claude/docs/pr-creation-pattern.md` for template/default structure and `.claude/docs/ai-attribution.md` for attribution. Keep reviewer-facing prose concise and concrete. Never mention local workspace paths, and never carry plan-internal labels (`Phase 0`, `case C`, `Option 2`, `REQ-003`) into the body or title - name what they denote instead. |
| `github-review-comment` | Review/comment rules + no-blame rules + `plain-writing-guard.md` Part 1 | One to two sentences. Lead with the concrete failure mode, cite the path or behavior, and include a fix direction only when it is clear. **Anchor to `path:line`** - file-level comments produce no code change 87.0% of the time against 51.9% for hunk-level, and a PR-level summary comment is close to dead on arrival. Prefer a short comment plus a copy-pasteable code block: comment length correlates negatively with being addressed (rho = -0.24), code-to-text ratio positively (rho = +0.89). Avoid vague asks like `consider improving this`. Label severity with `Nit:` / `Optional:` / `FYI:` rather than softening the prose. Comment on the code, never on the developer; point out the problem and let the author choose the fix. |
| `github-review-reply` | Review/comment rules + no-blame rules | For declines or reply-only threads, stay direct and non-defensive. Cite concrete evidence for this thread. Keep each reply at three lines or less. **When the reviewer is a bot / AI (Copilot, Codex/`chatgpt-codex-connector`, `claude`, CodeRabbit, Sonar, any `*[bot]`), skip courtesy openers entirely — no "good catch", "nice catch", "good job", "thanks for bringing this up". A bot does not read tone, so the opener is pure noise that buries the evidence and reads as AI filler. Open on the substance: the finding, the disagreement, or the fix. Warmth stays available for human reviewers.** |
| `jira-ticket` | Jira + external doc rules | Context -> evidence -> scope -> acceptance -> references. Include full Jira/GitHub/Confluence URLs. Make the ticket directly actionable without chat history. |
| `confluence-doc` | Confluence / RFC / strategy rules | Metadata, TLDR, tradeoffs, open questions, decision owners, and proof gates. Credit named contributors when summarizing shipped work. |
| `announcement` | People/process announcement rules | Background -> process/change -> time/scope -> optionality. Warmth goes up for people/team events; do not use generic farewell or celebration copy. |

## Why the Slack rows name a second doc

The Slack rows hard-require `slack-draft-style.md` because its Formatting Mechanics describe what
the draft tool and Slack's renderer do to the message body - a separate failure mode from voice,
and one that lands as a visibly broken message the sender has to repair by hand.

`tests/scripts/test-slack-draft-templates.sh` enforces those mechanics, but **only against fenced
templates committed to the repo**. It cannot see a body assembled on the fly for a one-off
`slack_send_message_draft` call, so for an ad-hoc draft the Quick Checklist is the only gate.

## Caller Contract

- Shared docs should point to this routing doc instead of duplicating long style rules.
- Workflow commands should name the surface at the output boundary, for example `surface=github-pr-body` before PR body generation.
- If a user edits a draft in a way that generalizes, follow `.claude/docs/style-delta-capture.md`; do not update `workspace/communication-style.md` silently.
