# Language Config — Shared Reference

Canonical algorithm for loading and applying language settings in skills.

---

## Algorithm

1. Read `workspace/config.md` → find the `## Language` section.
2. Extract `conversation:` value (for chat, explanations, reviews) and `output:` value (for GitHub PRs/commits, Jira, Confluence, Slack).
3. Apply:
   - **Conversation language**: all chat responses, inline explanations, AskUserQuestion prompts.
   - **Output language**: PR titles/descriptions, commit messages, review comments posted to GitHub, Slack messages, Jira comments, Confluence content.
   - **Always English**: code identifiers, technical terms, file paths.

If `workspace/config.md` is missing or has no `## Language` section, default to English for both.

## When to Reference This Doc

**Every skill that produces chat-facing prose must explicitly run the algorithm above as Step 0** — including chat-only skills. CLAUDE.md inheritance is not sufficient; observed auto-drift to English on chat-only skills (see `feedback_chat-only-skill-language-preflight.md` and `feedback_language_outranks_skill.md`). Skill-bundled English examples and default-English skill defaults do NOT override the configured `conversation:` value.

Skills that touch external systems (PR, Slack, Jira, Confluence) read **both** `conversation:` and `output:` and route accordingly — chat prose in `conversation:`, externally-posted content in `output:`.

### Minimum Step 0 block for chat-producing skills

Paste this near the top of any chat-producing skill (adjust filename if the skill has other Step 0 logic):

```
### 0. Language preflight (MUST run first, non-negotiable)

Read `workspace/config.md` → `## Language` section. Extract `conversation:` value. **All chat output from this skill MUST be written in that language.** English stays only for: code identifiers, file paths, PR/Jira IDs, repo names, protocol-fixed labels.

If `workspace/config.md` missing or no `## Language` section → default English and note it once at the top of the output.
```
