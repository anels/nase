---
name: nase:learn
description: Capture a tip, mistake pattern, article URL, or GitHub repo as structured knowledge. Use for quick learnings, articles worth distilling, or mistakes to avoid repeating. Also triggers on "remember this", "save this tip", "learn from this".
---

This skill extracts knowledge from any source (URL, tip, keyword, lesson, conversation), then goes deeper by researching related materials online — finding discussions, alternative approaches, and community insights — before persisting everything directly to the KB. The goal is real understanding, not just note-taking.

**Decision rule:** is this a general tip, article, or pattern that could apply across projects? → here. Is it a hard constraint or architectural decision specific to one codebase? → use `/kb-update` instead.

If `$ARGUMENTS` contains `--auto-accept`, skip all AskUserQuestion prompts and use best judgment for decisions. This flag is used by automated callers like `/nase:wrap-up`.

**Input:** $ARGUMENTS — one of:
- A raw tip or insight: `"always check X before doing Y"`
- A mistake pattern: `"I did X wrong, should have done Y"`
- A URL (article or GitHub repo): `https://...` — content is fetched and distilled automatically
- A URL + context hint: `https://... , what's worth learning about X`
- A keyword or topic: `"structured concurrency"` — triggers web research directly
- Empty: auto-reflect on the most recent conversation

## Setup

Use `ToolSearch` to fetch `AskUserQuestion` before starting — it's a deferred tool used in Step 4 for confirming the knowledge entry. Skip if `--auto-accept` is in $ARGUMENTS.

## Steps

### 1. Detect input type

Parse $ARGUMENTS:
- **URL**: starts with `http://` or `https://` → go to Step 2 (fetch & extract)
- **Keyword/topic**: short phrase without URL, looks like a concept rather than a tip (e.g. `"structured concurrency"`, `"CQRS patterns"`, `"eBPF observability"`) → go to Step 3 (research) directly, using the keyword as the research seed
- **Text tip / lesson**: plain text describing a specific insight or mistake → go to Step 4 (synthesize), using it as a pre-extracted learning
- **Empty**: auto-reflect on recent conversation → extract 1-3 learnings, then go to Step 4

### 2. Fetch and Extract (URL inputs)

**2a. Determine source type:**
- GitHub repo URL (e.g. `github.com/Org/Repo`) → fetch the README, and if present: CLAUDE.md, docs/index, key source files mentioned in README. Focus on: architecture, design patterns, novel techniques, tooling decisions.
- Article / blog post URL → fetch full content. Focus on: key insights, concrete techniques, tradeoffs discussed.
- Extract the context hint from $ARGUMENTS if provided (text after the URL and a comma/dash).

**2b. Filter for relevance** — keep only content related to the workspace's tech stack and interests. Read `workspace/tech-digest-config.md` for the user's configured filter topics. If unavailable, infer from `workspace/context.md` and existing KB files.

Discard marketing content, unrelated domains, and obvious filler.

**2c. Extract key knowledge** — for each insight found, capture:
- What is the technique/pattern/insight?
- Why does it matter / what problem does it solve?
- Is it directly applicable to our stack or workflow?
- What are the tradeoffs or limitations?

Produce a list of 2-5 concrete knowledge items. These become the seed for Step 3.

### 3. Deep Research (secondary learning)

This is the step that turns a single source into real understanding. The goal: find how the community discusses, critiques, and applies this knowledge — not just parrot the original source.

<parallel>

**3a. Search for related discussions and materials:**
Using WebSearch, find 3-5 high-quality related sources. Search for:
- The core concepts/techniques extracted in Step 2 (or the keyword from Step 1)
- Add qualifiers to find diverse perspectives: `"{topic} tradeoffs"`, `"{topic} vs alternatives"`, `"{topic} production experience"`, `"{topic} best practices {year}"`
- Prefer: official docs, engineering blog posts, conference talks, GitHub discussions, Stack Overflow answers with high votes, HN/Reddit discussions with substance

**3b. Cross-reference with existing KB:**
Read `workspace/kb/.domain-map.md` and check if any existing KB files already cover related topics. If so, read the relevant sections — the new knowledge may extend, contradict, or refine what's already there.

</parallel>

**3c. Fetch and distill the best sources:**
If no relevant sources were found in Step 3a, skip this step and proceed to Step 4 with only the original extraction. Note in the output that deep research found no additional materials.

From the search results, pick the 2-3 most valuable sources (prioritize: practical experience > theory, recent > old, in-depth > surface-level). Use WebFetch to read them. Extract:
- **Complementary insights**: things the original source didn't cover
- **Counterpoints**: criticisms, failure cases, "it depends" nuances
- **Practical examples**: real-world usage, production stories, gotchas
- **Related tools/libraries**: alternatives or companions worth knowing about

**3d. Build a sources list** for attribution:
```
- [{title}]({url}) — {one-line why it's relevant}
```

### 4. Synthesize and Confirm

Combine the original extraction (Step 2) with the deep research (Step 3) into a unified knowledge summary. Structure it as:

```
## {Topic Title}

### Core Insight
{What this is and why it matters — 2-3 sentences}

### Key Takeaways
1. {takeaway with detail}
2. {takeaway with detail}
...

### Tradeoffs & Limitations
- {what to watch out for}

### Practical Application
{How this applies to our stack/workflow — be specific}

### Sources
- {attributed list from Step 3d}
```

Show the synthesis to the user, then **immediately invoke the `AskUserQuestion` tool** (do not present the options as plain text):

```
question: "Save this to the knowledge base?"
header: "Confirm Knowledge Entry"
options:
  - label: "Yes — save"          , description: "Write to KB"
  - label: "Edit"                 , description: "Adjust before saving"
  - label: "No — discard"        , description: "Nothing is written"
```
- **Yes**: proceed to Step 5
- **Edit**: ask what to change, then re-confirm
- **No**: stop, nothing is written

### 5. Categorize and determine KB target

Map each knowledge item to a KB domain. Read `workspace/kb/.domain-map.md` to get the current domain list first. Use the following as fallback categories only if no existing domain matches:
- `workflow` — process, tools, habits, Claude Code patterns → `workspace/kb/general/workflow.md`
- `debugging` — root causes, diagnostic techniques → `workspace/kb/general/debugging.md`
- `architecture` / `system-design` — design decisions, tradeoffs → `workspace/kb/general/system-design.md`
- `tech-trends` — emerging tech, industry shifts → `workspace/kb/general/tech-trends.md`
- **New domain**: if no existing domain fits, create a new KB file and register it in `.domain-map.md` under `## General`

If the knowledge spans multiple domains, write to each relevant KB file (the overlapping parts, not duplicates — each file gets domain-specific framing).

### 6. Write to KB

For each target KB file:
- If the file exists: read it, find the right section, and **append or merge** the new knowledge. Don't duplicate content that's already there — enrich it instead. Add a date comment: `<!-- Added: YYYY-MM-DD -->`
- If the file doesn't exist: create it with a header and the synthesized content, then register in `.domain-map.md`

Use the synthesized format from Step 4, adapted to fit the existing file's structure.

### 7. Flag reusable rules

If any learning is an important reusable rule or principle:
- Save to the auto-memory directory as a feedback-type memory file.
- Suggest updating `.claude/docs/reference.md` under "Key Decisions & Architecture Notes" if warranted

### 8. Update daily log and confirm

Append to `workspace/logs/YYYY-MM-DD.md`:
```
- Learned: {topic} — {one-line summary} (sources: {N} articles researched) → wrote to {kb-file(s)}
```

Report to user:
- What knowledge was captured (topic + key takeaways)
- Where it was written (KB file paths)
- How many external sources were researched
- Any new KB domains created

If user specify conversation language in config.md, use the conversation to output summary.

## Error Handling

- If WebSearch/WebFetch fails: proceed with whatever was extracted from the original source. Note in the output that deep research was skipped and suggest trying again later.
- If KB files referenced in domain-map are missing: create them rather than failing.
- If the original URL is inaccessible: fall back to treating the URL's topic as a keyword and go to Step 3 (research) directly.
