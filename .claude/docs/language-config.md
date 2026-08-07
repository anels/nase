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

## Canonical pointer

Every skill reaches this preflight through one pointer, spelled the same way everywhere. Change the wording **here first**, then propagate; `tests/check-canonical-pointers.sh` fails the build on any other spelling.

<canonical-block name="language-preflight">

Follow `.claude/docs/language-config.md` → Minimum Step 0 block.

</canonical-block>

Rules:

- Copy the block **verbatim**, including the `→`. A leading `Follow` / `follow` / a `**Step 0 — Language preflight:**` label in front of it is fine; the pointer body itself never varies.
- Skill-specific language rules go in a **following** sentence, never as a rewrite of the pointer ("… Minimum Step 0 block. Fixed severity labels stay English.").
- Never restate the preflight rules inline. A skill that spells out "read `workspace/config.md` → `## Language`, use `conversation:` for chat …" is a second copy that drifts; point instead.
- When a skill also needs other shared docs, the pointer stands alone and the rest follow it ("… Minimum Step 0 block. Then follow `.claude/docs/skill-contract.md`."). Do not bundle this doc into a list of docs to "run first".
