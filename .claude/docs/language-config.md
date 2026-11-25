# Language Config

`.claude/hooks/session-start.sh` reads `workspace/config.md` `## Language` and adds one line to the session context on startup, resume, clear, and compaction:

`[language] conversation: {value}; output: {value}; code identifiers: English.`

Apply it like this:

1. Use `conversation:` for chat, explanations, reviews, and user questions.
2. Use `output:` for GitHub, commits, Jira, Confluence, and Slack.
3. Keep identifiers, technical terms, file paths, repo names, and PR/Jira IDs in English.
4. A value that reads `English (fallback: ...)` means the key is missing or unusable: use English and note the fallback once.
5. With no `[language]` line in context (a subagent, or a missing `workspace/config.md`), read `workspace/config.md` `## Language` yourself, and use English if it is not there.
6. Skill examples never override the configured language.
