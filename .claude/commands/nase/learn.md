---
name: nase:learn
description: "Deep-dive a tip, URL, repo, or cross-project pattern into structured KB knowledge. Use for remember this, save this tip, learn from this, deep dive on X, article URL, or general programming insights. For one-repo constraints, API contracts, or naming rules, use /nase:kb-update."
argument-hint: "<tip/url/repo/topic>"
when_to_use: "Deep-dive a tip, URL, repo, or cross-project pattern into structured KB knowledge. Use for remember this, save this tip, learn from this, deep dive on X, article URL, or general programming insights. For one-repo constraints, API contracts, or naming rules, use /nase:kb-update."
pattern: expert-pool
category: Learning & reflection
---

This skill extracts knowledge from any source (URL, tip, keyword, lesson, conversation), then goes deeper by researching related materials online — finding discussions, alternative approaches, and community insights — before persisting everything directly to the KB. The goal is real understanding, not just note-taking.

**Decision rule:** follow `.claude/docs/kb-write-routing.md` — if the insight is repo-internal (API contract / build constraint / naming rule / decision) use `/nase:kb-update` instead. If it is a general programming pattern, a stack idiom, or a web-sourced article that could apply across repos, stay here.

If `$ARGUMENTS` contains `--auto-accept`, skip all AskUserQuestion prompts and use best judgment for decisions. This flag is used by automated callers like `/nase:wrap-up`.

If `$ARGUMENTS` contains `--exa` (optionally with `--depth fast|deep|deep-reasoning`, default `fast`; and `--category research_paper|news|company|github|financial_report`), Step 3a switches to Exa-powered neural search instead of `WebSearch` + `WebFetch`. Use it for academic papers, competitive intelligence, code examples requiring broad coverage, or when result highlights are enough and full-page fetches would add cost. Falls back to `WebSearch` silently if Exa MCP is not installed. See Step 3a Exa branch.

**Input:** $ARGUMENTS — one of:
- A raw tip or insight: `"always check X before doing Y"`
- A mistake pattern: `"I did X wrong, should have done Y"`
- A URL (article or GitHub repo): `https://...` — content is fetched and distilled automatically
- A URL + context hint: `https://... , what's worth learning about X`
- A keyword or topic: `"structured concurrency"` — triggers web research directly
- Empty: auto-reflect on the most recent conversation

## Steps

### 0. Language preflight (MUST run first, non-negotiable)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. The KB entry written in Step 6 follows `.claude/docs/kb-template.md` (structural headers English; freeform body follows `conversation:`).
Follow `.claude/docs/confidential-marker.md` — check only user-provided input and the session content being used as the learning seed, not this command file or policy docs. If that content contains `[CONFIDENTIAL]`, refuse to seed research from it and ask for a sanitized restatement.
Follow `.claude/docs/workspace-write-guard.md` for staged KB writes and final mtime/hash drift checks.

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
- **Signal bucket** — which one carries the value: `actionable` (changes how I code/work right now), `insightful` (changes my mental model of how something works), or `reference` (worth knowing, look up when needed). This drives ordering in Step 4 — actionable leads.

Produce a list of 2-5 concrete knowledge items. These become the seed for Step 3. Prefer depth over breadth: three takeaways that each clear the notability bar beat eight that restate the source.

### 3. Deep Research (secondary learning)

**3.0. URL-already-cited pre-check (URL inputs only).** Before any web research, grep the KB for the bare input URL: `grep -rnF -- "<url>" workspace/kb/`. If an existing entry already cites it as a source, the learn is guaranteed-KNOWN — skip 3a/3b entirely and jump to the Step 4.0 skip path (output the notability-skip message, reason "already-cited KB source"). This is a deterministic short-circuit, distinct from the post-research KB Delta (3e) and notability bar (4.0): the most common wasted-research case is re-learning a canonical primer the KB was already built from.

**Skip this entire step** if the input was **Empty** (auto-reflect mode) AND the learnings were derived from the current session rather than an external URL or keyword. Session-derived patterns already have full context — running WebSearch against them adds cost with minimal gain. Proceed directly to Step 4.

This is the step that turns a single source into real understanding. The goal: find how the community discusses, critiques, and applies this knowledge — not just parrot the original source.

<parallel>

**3a. Search for related discussions and materials:**

**Default (no `--exa` flag):** use `WebSearch` to find 3-5 high-quality related sources. Search for:
- The core concepts/techniques extracted in Step 2 (or the keyword from Step 1)
- Add qualifiers to find diverse perspectives: `"{topic} tradeoffs"`, `"{topic} vs alternatives"`, `"{topic} production experience"`, `"{topic} best practices"` (append the current year, e.g. `"best practices 2026"`, to get recent results)
- Prefer: official docs, engineering blog posts, conference talks, GitHub discussions, Stack Overflow answers with high votes, HN/Reddit discussions with substance

**With `--exa` flag (Exa-powered branch):**

Load Exa tools via `ToolSearch` query `"select:mcp__plugin_exa_exa__web_search_exa,mcp__plugin_exa_exa__web_fetch_exa"`. If neither tool is reachable, log `Exa MCP not available — falling back to WebSearch` and run the Default branch above. If only `authenticate` / `complete_authentication` is found, prompt OAuth, then retry.

Once Exa is loaded:
- Run **2-3 searches** on the core topics from Step 2 (or the Step 1 keyword) using `mcp__plugin_exa_exa__web_search_exa`. **Query-writing rule:** describe the ideal page, not keywords (e.g. `"engineering blog post about EF Core bulk insert performance tradeoffs 2026"` — not `"EF Core bulk insert"`).
- Use category prefix inline when relevant: `category:company`, `category:research_paper`, etc. (the tool only takes `query` + `numResults`).
- `numResults: 5` (default 10 wastes context; 5 is enough for research).
- **Use highlights as primary content** — they're pre-extracted excerpts and are often enough for first-pass research. Only call `mcp__plugin_exa_exa__web_fetch_exa` when a result looks critical but its highlight is too short.
- With `--depth deep` or `--depth deep-reasoning`: run 4-5 searches across different angles (main topic + tradeoffs + production experience + alternatives). Synthesize manually — depth here means more search coverage, not API-level deep mode.

Note in Step 6's `**Research method:**` field which mode was used (`WebSearch` vs `Exa fast / deep / deep-reasoning`).

**3b. Cross-reference with existing KB:**
Read `workspace/kb/.domain-map.md`, then read the relevant sections of any KB file that plausibly covers the topic. This is not optional skimming — you cannot classify a takeaway as new knowledge without first proving the KB doesn't already hold it. Pull the exact current wording of any overlapping entry so Step 3e can compare against it, not against your memory of what the KB "probably" says.

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

**3e. Classify each takeaway against the KB (KB Delta).**

The point of cross-referencing is not to avoid duplicates — it's to know what this learning *does to your existing understanding*. For each takeaway from Steps 2-3, assign one verdict and cite the evidence (KB file + section, and what it currently says):

| Verdict | When | What it means for you |
|---------|------|------------------------|
| 🆕 **NEW** | No KB file covers this | Fills a gap — knowledge you didn't have |
| 🔄 **REFRESH** | KB covers it, but this adds nuance, a newer version, a confirming data point, or a missing edge case | Sharpens what you already knew |
| ⚠️ **CONTRADICT** | KB states something this learning shows is wrong, outdated, or now suboptimal | Changes what you should do — the highest-value verdict, because acting on stale belief is worse than not knowing |
| 💤 **KNOWN** | KB already fully covers this, no delta | No value — do not rewrite an entry to say the same thing |

Rules that make the verdict trustworthy:
- A NEW verdict requires that you actually read the candidate KB sections in 3b and found nothing — not that you didn't look.
- A CONTRADICT verdict must quote the specific KB sentence it contradicts and state why the new evidence wins (newer source, production experience, primary doc, reproduced failure). A vague "this seems to update X" is a REFRESH, not a CONTRADICT.
- KNOWN takeaways are dropped from the synthesis — they feed the notability check in Step 4.0.

### 4. Synthesize and Confirm

**4.0. Notability bar check (abort gate).**

Before drafting, ask: does the extracted knowledge clear the notability bar (see `.claude/docs/kb-template.md → Writing Conventions`)?

**Clear** = at least one takeaway is one of: a decision with rationale, a gotcha discovered through failure, a cross-cutting flow spanning multiple files, a hidden constraint or invariant, or a subsystem/integration referenced by multiple places.

**Fails the bar** = takeaways are exclusively any of:
- Every takeaway came back 💤 KNOWN from Step 3e (KB already covers all of it)
- Restating what code, README, or product docs already say in equivalent words
- Pure speculation or inference without a concrete signal
- Generic best-practice platitudes already covered in existing KB
- Marketing / vendor positioning content
- Restatement of widely-known facts (e.g. "HTTPS encrypts traffic")

**If it fails the bar**: do not write a KB entry. Output:
```
Skipped — content does not clear notability bar.
Reason: {one-line — restates docs / pure speculation / generic / vendor / already-known}
```
If deep research was skipped or failed and a retry is the only concrete useful action, jump to Step 9 with only that deep-dive retry candidate. Otherwise stop. Silence is a valid outcome.

**If it clears the bar**: continue with the synthesis below.

**4.1. Auto-accept quality gate.**

If `--auto-accept` is active, the notability bar is necessary but not sufficient. Auto-save only when all are true:
- target KB domain is unambiguous from `.domain-map.md` or the routing rules
- source quality is concrete: at least two independent credible sources, or one official/primary source, or a session-derived failure/decision with direct repo evidence
- the entry is not a generic best-practice restatement already covered by existing KB
- no new KB domain is required

If any condition fails, write only the draft to `workspace/tmp/learn-draft-{slug}.md`, report the failed quality condition in one line, and stop without mutating durable KB files.

**CONTRADICT in `--auto-accept` is never auto-applied.** Correcting an existing KB entry overturns something you already believed and must not happen unattended. When a takeaway is ⚠️ CONTRADICT under `--auto-accept`: auto-write the NEW/REFRESH takeaways as normal, but for the contradiction, write the proposed correction to `workspace/tmp/learn-draft-{slug}.md`, append a `[KB-CONTRADICT]` line to the daily log naming the stale KB entry, and leave the old entry untouched for the user to resolve interactively later. Do not silently overwrite.

Combine the original extraction (Step 2) with the deep research (Step 3) into a unified knowledge summary using this structure (this is the **file content**, not chat output):

```
## {Topic Title}

### Core Insight
{What this is and why it matters — 2-3 sentences}

### Key Takeaways
{Order by signal bucket from Step 2c — actionable first, then insightful, then reference. Tag each with its bucket and its Step 3e verdict so the value is legible at a glance.}
1. [actionable · 🆕 NEW] {takeaway with detail}
2. [insightful · 🔄 REFRESH] {takeaway with detail — name the KB file/section it refreshes}
...

### KB Delta
{The verdict table — what this learning does to your existing understanding. Omit 💤 KNOWN rows.}
- ⚠️ **CONTRADICT** — `{kb-file → section}` currently says "{quoted stale claim}"; this learning shows {why it's wrong/outdated}, per {source}. → correct the old entry.
- 🆕 **NEW** — no KB coverage for {sub-topic}. → new entry in `{target file}`.
- 🔄 **REFRESH** — `{kb-file → section}` gains {the added nuance}.

### Tradeoffs & Limitations
- {what to watch out for}

### Practical Application
{How this applies to our stack/workflow — be specific. Lead with the actionable takeaways: what would I change in my next PR / review / design because of this?}

### Sources
- {attributed list from Step 3d}
```

**Write this synthesis to a draft file** — do NOT paste the full block in chat (high output cost). Steps:

1. Slugify the topic title to a kebab-case basename (e.g. "Structured Concurrency" → `structured-concurrency`).
2. Write the full synthesis above to `workspace/tmp/learn-draft-{slug}.md` (create `workspace/tmp/` if missing). Overwrite if it already exists.
3. In chat, output ONLY:
   - `Draft saved → workspace/tmp/learn-draft-{slug}.md`
   - **Topic:** `{Topic Title}` — `{one-sentence Core Insight}`
   - **Takeaways:** `{N}` · **Sources:** `{N}`
   - **KB Delta:** `{X new · Y refresh · Z contradict}` — if Z > 0, list each contradiction on its own line (`⚠️ {kb-file → section}: was "{stale}", now "{correct}"`) so it cannot be missed.

If `--auto-accept` is active and Step 4.1 passed, skip the confirmation and proceed directly to Step 5 (auto-save) — no draft file needed in that path; write straight to KB.

Otherwise, after emitting the draft summary above, **immediately invoke the `AskUserQuestion` tool** (do not present the options as plain text):

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

Map each knowledge item to a KB domain. Read `workspace/kb/.domain-map.md` to get the current domain list first. If no existing domain matches, follow the fallback logic in `/nase:kb-update` Step 1 (which handles ops, general, and project-specific categorization and creates new files as needed).

If the knowledge spans multiple domains, write to each relevant KB file (the overlapping parts, not duplicates — each file gets domain-specific framing).

### 6. Write to KB

Write behavior follows the Step 3e verdict for each takeaway:
- 🆕 **NEW** / 🔄 **REFRESH** — append or merge into the target file (per-file rules below).
- ⚠️ **CONTRADICT** (interactive run) — **do not write until the user confirms.** Invoke `AskUserQuestion` showing the stale claim, its KB location, the new claim, and the source. On confirm: edit the old entry in place — replace the wrong text and append `<!-- Superseded YYYY-MM-DD: was "{old claim}" — corrected per /nase:learn ({source}) -->` so the correction is auditable, not a silent overwrite. On decline: leave the entry, note the unresolved contradiction in the daily log. (Under `--auto-accept`, follow the Step 4.1 report-only path instead — never reach this prompt.)
- 💤 **KNOWN** — write nothing.

For each target KB file:
- Apply `.claude/docs/workspace-write-guard.md`: stage the final target content to `workspace/tmp/`, diff it, and re-check target mtime/hash immediately before writing. In `--auto-accept`, skip the prompt only if Step 4.1 passed; never skip the final drift check.
- If the file exists: read it, find the right section, and **append or merge** the new knowledge. Don't duplicate content that's already there — enrich it instead. Add a date comment: `<!-- Added: YYYY-MM-DD -->`
- If the file doesn't exist: create it with a header and the synthesized content, then register in `.domain-map.md`

Use the synthesized format from Step 4, adapted to fit the existing file's structure. Condense into a dated `### YYYY-MM-DD — {topic}` entry and attach metadata:
- `**Tags:**` — classify using the standard vocabulary: `gotcha`, `architecture`, `api-contract`, `deployment`, `performance`, `security`, `workflow`, `debugging`
- `**Confidence:** medium` — always include for web-sourced knowledge (not yet validated in production)
- `**Links:**` — include all source URLs from Step 3d
- Omit `**Applies-to:**` for general KB files (implicit from the file's scope)

### 7. Flag reusable rules

If any learning is an important reusable rule or principle:
- Save to the auto-memory directory as a feedback-type memory file.
- Suggest updating `.claude/docs/reference.md` under "Key Decisions & Architecture Notes" if warranted

### 8. Update daily log and confirm

Append to daily log following `.claude/docs/daily-log-format.md` (tag: `learn`).
Log: `{topic} — {one-line summary} (sources: {N} articles researched) → wrote to {kb-file(s)}`

Report to user:
- What knowledge was captured (topic + key takeaways)
- Where it was written (KB file paths)
- How many external sources were researched
- Any new KB domains created

Follow .claude/docs/language-config.md for conversation vs output language.

### 9. Offer proactive next actions

Skip this entire step when:
- `--auto-accept` is active
- The user selected **No — discard** in Step 4
- Step 4.0 failed the notability bar, unless deep research was skipped/failed and a retry is the only concrete useful action

Build up to three `next_action_candidates` from saved-learning signals, source gaps, and KB-routing results. Keep only executable candidates with a named target, ordered by likely value:

1. **Deep dive: `{topic}`** — use when a source gap, unresolved counterpoint, version-specific behavior, or production-readiness question remains. Research that angle, then write `workspace/tmp/learn-deep-dive-{slug}.md` with sources, findings, and recommended follow-up.
2. **Write KB: `{target}`** — use when Step 5 showed a repo-specific, cross-project, or ops facet not covered by the general KB entry. Follow `.claude/docs/kb-write-routing.md`; write only the missing facet to `workspace/kb/projects/`, `workspace/kb/cross-project/`, or `workspace/kb/ops/`.
3. **Create/update skill: `{name}`** — use when the learning describes a repeatable workflow, tool sequence, review checklist, or failure-recovery procedure. Follow `/nase:extract-skills` Step 5 and Step 6b plus `.claude/docs/skill-authoring-contract.md` anti-overlap rules: create/update `workspace/skills/{name}.md` and the wrapper `.claude/commands/nase/workspace/{name}.md`.
4. **Discuss: `{decision}`** — use when adoption depends on a user preference or tradeoff that cannot be resolved from sources or KB.

Do not include generic items like "learn more", "review later", or "consider using this". If no candidates remain, end after Step 8.

If candidates exist, **immediately invoke `AskUserQuestion`** after the Step 8 summary. For the Step 4.0 retry-only path, invoke it after the notability-skip message instead. Use the conversation language from Step 0.

```
question: "I found a few concrete follow-ups. What should I do next?"
header: "Next Actions"
multiSelect: true when more than one independent action exists; otherwise false
options:
  - label: "{Action type}: {specific target}" , description: "{exact path/topic/source/skill name that will be acted on}"
  - label: "Skip"                             , description: "Stop here — KB write and daily log are already done"
```

Menu rules:
- Present at most four options total: up to three candidates plus `Skip`.
- Labels must name the specific target; descriptions must name the concrete path, topic, URL, or skill.
- If `Skip` is selected, stop without further work.
- Execute selected actions in this order: deep dive, KB write, skill create/update, discussion.
- For **Discuss**, ask one focused `AskUserQuestion` with 2-3 concrete options and the recommended option first.
- Gate external-visible mutations through `.claude/docs/external-mutation-policy.md`.
- Report each executed action with the output path or explicit skip reason.

## Error Handling

- If WebSearch/WebFetch fails: proceed with whatever was extracted from the original source. Note in the output that deep research was skipped and suggest trying again later.
- If KB files referenced in domain-map are missing: create them rather than failing.
- If the original URL is inaccessible: fall back to treating the URL's topic as a keyword and go to Step 3 (research) directly.
