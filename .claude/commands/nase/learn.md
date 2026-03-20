---
name: nase:learn
description: Capture a tip, mistake pattern, article URL, or GitHub repo as structured knowledge. Use for quick learnings, articles worth distilling, or mistakes to avoid repeating. Also triggers on "remember this", "save this tip", "learn from this".
---

For durable codebase-specific architecture decisions or constraints, use `/kb-update` instead.

**Input:** $ARGUMENTS — one of:
- A raw tip or insight: `"always check X before doing Y"`
- A mistake pattern: `"I did X wrong, should have done Y"`
- A URL (article or GitHub repo): `https://...` — content is fetched and distilled automatically
- A URL + context hint: `https://... , what's worth learning about X`
- Empty: auto-reflect on the most recent conversation

## Steps

### 1. Detect input type

Parse $ARGUMENTS:
- **URL**: starts with `http://` or `https://` → go to Step 2 (fetch)
- **Text tip**: plain text → skip to Step 3 (categorize)
- **Empty**: auto-reflect on recent conversation → extract 1-3 learnings, then go to Step 3

### 2. Fetch and distill (URL inputs only)

**2a. Determine source type:**
- GitHub repo URL (e.g. `github.com/Org/Repo`) → fetch the README, and if present: CLAUDE.md, docs/index, key source files mentioned in README. Focus on: architecture, design patterns, novel techniques, tooling decisions.
- Article / blog post URL → fetch full content. Focus on: key insights, concrete techniques, tradeoffs discussed.
- Extract the context hint from $ARGUMENTS if provided (text after the URL and a comma/dash).

**2b. Filter for relevance** — keep only content related to the workspace's tech stack and interests. Read `work/tech-digest-config.md` for the user's configured filter topics. If unavailable, infer from `work/context.md` and existing KB files.

Discard marketing content, unrelated domains, and obvious filler.

**2c. Extract 2-5 concrete learnings** — for each, answer:
- What is the technique/pattern/insight?
- Why does it matter / what problem does it solve?
- Is it directly applicable to our stack or workflow?

Show the extracted learnings to the user, then confirm using AskUserQuestion:
```
question: "Save these learnings?"
header: "Confirm Learnings"
options:
  - label: "Yes — save all"    , description: "Write to lessons.md and KB"
  - label: "Edit"               , description: "Adjust before saving"
  - label: "No — discard"       , description: "Nothing is written"
```
- **Yes**: proceed to Step 3
- **Edit**: ask what to change, then re-confirm
- **No**: stop, nothing is written

### 3. Categorize each learning

- `workflow` — process, tools, habits, Claude Code patterns
- `code` — patterns, gotchas, best practices
- `debugging` — root causes, diagnostic techniques
- `architecture` — design decisions, tradeoffs
- `project` — project-specific context or conventions

### 4. Write to lessons.md

Ensure `work/tasks/lessons.md` exists (create with `# Lessons Learned\n` header if missing). Append one entry per learning:
```
## {category} — {YYYY-MM-DD}
**Tip:** {one-line summary}
**Detail:** {explanation, why it matters, example if relevant}
**Source:** {URL or description of what triggered this}
```

### 5. Write to KB (always runs for URL inputs)

If the input was a URL, always write learnings to the KB. Skip only for plain-text tips.

Delegate to `/nase:kb-update` with the extracted content rather than writing directly. For each learning that belongs in the KB, invoke kb-update with the topic, summary, and source URL. If learnings span multiple domains, invoke kb-update once per domain.

### 6. Flag reusable rules

If any learning is an important reusable rule or principle:
- Save to auto-memory (`~/.claude/projects/.../memory/`) as a feedback-type memory file.
- Suggest updating `.claude/docs/reference.md` under "Key Decisions & Architecture Notes" if warranted

### 7. Confirm

Report exactly what was saved and where (lessons.md entries, KB files updated, memory files created).
