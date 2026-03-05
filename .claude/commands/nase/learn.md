Capture a tip, lesson, article, or repo as structured knowledge and save it to the knowledge base.

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

**2b. Filter for relevance** — keep only content related to:
- .NET / Azure / ASP.NET Core
- Spark / Databricks / Delta Lake / data engineering
- AI/LLM engineering, agent design, MCP
- Kubernetes / container orchestration
- Claude Code workflow, hooks, skills
- General engineering principles with direct applicability

Discard marketing content, unrelated domains, and obvious filler.

**2c. Extract 2-5 concrete learnings** — for each, answer:
- What is the technique/pattern/insight?
- Why does it matter / what problem does it solve?
- Is it directly applicable to our stack or workflow?

Show the extracted learnings to the user before saving. Ask:
> "Save these learnings? (yes / no / edit)"
- **no**: stop, nothing is written
- **edit**: adjust per user feedback, then re-confirm
- **yes**: proceed to Step 3

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

1. **Identify the matching KB file** using the domain lookup logic in `/nase:kb-update` Step 1 (read `work/kb/.domain-map.md`). **Override**: if no match is found, infer the best domain name from the content (e.g. "llm", "kubernetes", "azure"), create `work/kb/general/{domain}.md` with a minimal header, and add it to `.domain-map.md` automatically — do NOT ask the user.

2. Append using the KB entry format defined in `/nase:kb-update` Step 4. Since the source is a URL, always include the `**Links:**` field.

3. If learnings span multiple domains, update all relevant files.

### 6. Flag reusable rules

If any learning is an important reusable rule or principle:
- Use `<remember>` to persist it as a behavioral directive
- Suggest updating `CLAUDE.md` under "Key Decisions & Architecture Notes" if warranted

### 7. Confirm

Report exactly what was saved and where (lessons.md entries, KB files updated, any `<remember>` tags used).
