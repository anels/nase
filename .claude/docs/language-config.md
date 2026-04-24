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

Only skills that produce **multi-channel output** (e.g., chat + GitHub, chat + Slack) need to explicitly reference this doc. Skills that only produce chat output inherit language rules from CLAUDE.md automatically.
