# Language Config

Run this preflight before any chat output:

1. Read `workspace/config.md` `## Language`.
2. Use `conversation:` for chat, explanations, reviews, and user questions.
3. Use `output:` for GitHub, commits, Jira, Confluence, and Slack.
4. Keep identifiers, technical terms, file paths, repo names, and PR/Jira IDs in English.
5. If the section is missing, use English and note the fallback once.

## Minimum Step 0 block

Read `workspace/config.md` `## Language` before any chat output. Use `conversation:` for chat and questions. For an external-output workflow, also use `output:` for the external artifact. Keep identifiers and technical terms in English. If the section is missing, use English and note the fallback once.

CLAUDE.md inheritance does not replace this preflight; skill examples must not override the configured language. A chat-only skill may read only `conversation:`. Any external-output skill reads both values.
