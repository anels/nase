# MS Learn Grounding — Shared Reference

Read-only verification step that grounds KB claims about Azure / .NET / Microsoft SDK behavior against authoritative Microsoft Learn documentation.

Used by `/nase:onboard` Step 3j and any future skill that writes durable claims about Microsoft technology surfaces.

---

## Server

- **Endpoint:** `https://learn.microsoft.com/api/mcp`
- **Auth:** none (anonymous)
- **Config:** `.mcp.json` at workspace root, server name `ms-learn`
- **Activation:** requires Claude Code session restart after `.mcp.json` is added. `claude mcp list` should show `ms-learn: ... ✓ Connected` once active.

Scope per upstream announcement (Microsoft DevBlogs, 2026-05-28): Microsoft Learn documentation, code samples, and guidance. Practical coverage spans Azure SDKs, .NET API reference, Microsoft Graph, and broader Learn content; explicit boundary list is not published.

## When to Invoke

Run grounding **only when the repo's stack touches Microsoft technology**. Skip silently otherwise.

Trigger if any of these signal a Microsoft surface:

- `.csproj` / `.sln` / `Directory.Packages.props` present
- Package references match `Azure.*`, `Microsoft.Azure.*`, `Microsoft.Extensions.*`, `Microsoft.AspNetCore.*`, `Microsoft.EntityFrameworkCore.*`, `Microsoft.Graph.*`, `Microsoft.ApplicationInsights.*`, `Microsoft.OpenApi.*`
- Bicep / ARM templates / `azure-pipelines.yml` / `azure-functions-*.json` present
- KB Stack section lists Azure Functions, AKS, Service Bus, App Insights, Cosmos DB, Key Vault, Managed Identity, Azure Storage, Cognitive Services, OpenAI on Azure
- Repo CLAUDE.md mentions any of the above

Pure Go / Rust / Python / JS repos with no Microsoft dependencies: skip grounding entirely.

## What to Ground

Ground specific factual claims, not the full KB. Target the kinds of statements that go stale fastest:

- **SDK method behavior** — "method X returns Y under Z condition" / "default timeout is N ms"
- **API contract** — "endpoint requires header X" / "version W deprecates field Y"
- **Configuration semantics** — "setting X overrides Y" / "default sampling rate is Z%"
- **Service tier behavior** — "tier T has limit L" / "feature F requires SKU S"
- **Deprecation / EOL** — "feature F retires on date D"
- **Auth model** — "scope X grants permission Y"

Do **not** ground:

- Repo-local architecture decisions (Microsoft Learn cannot know your repo)
- Internal naming conventions
- Code-style choices
- Anything already directly grep-confirmable in the repo

## Algorithm

```
1. Collect candidates — walk the Step 3 self-study output. For each fact about a
   Microsoft technology, capture: (claim, source-file:line in repo, confidence).
   Cap candidates at 8 per onboard run.

2. For each candidate, call ms-learn MCP with a targeted query:
     query = "{microsoft-technology} {method-or-feature} {specific aspect}"
   Example: "Azure Application Insights ITelemetryInitializer DI registration"

3. Compare ms-learn result against the candidate claim:
   - MATCH    — Learn doc corroborates the claim verbatim or near-verbatim
   - REFINE   — Learn doc adds nuance the claim missed (e.g. version-specific)
   - CONFLICT — Learn doc contradicts the claim
   - NO-COVERAGE — Learn returns no relevant result (claim may be repo-internal)

4. Apply outcomes:
   - MATCH    → append " [verified against Microsoft Learn YYYY-MM-DD]" to the KB line
   - REFINE   → rewrite the KB line with the refined nuance + cite Learn URL
   - CONFLICT → DO NOT silently overwrite. Log to onboard report under
                ## MS Learn Grounding Conflicts, include both versions, leave the
                original line untouched in the KB, surface as Open Question.
   - NO-COVERAGE → no change to KB; do not annotate (annotation noise > value)

5. Cap the per-onboard grounding pass at 8 candidates and 16 MCP calls total.
   If the candidate list exceeds the cap, prioritize: CONFLICT-prone claims
   (version numbers, default values, deprecation dates) before nuance claims.
```

## Failure Modes

- **MCP unavailable** (server not in `claude mcp list` or returns connection error): skip the entire grounding pass silently. Log one line in the onboard report: `MS Learn grounding skipped — ms-learn MCP not connected.` Do not block the onboard.
- **MCP returns malformed / empty consistently**: after 3 consecutive empty results across 3 different queries, abort the pass for this onboard run. Same skip-log line.
- **Rate limit**: not documented by Microsoft. If a 429 or equivalent surfaces, abort the pass and log it.

## Out of Scope

- **Auto-amending other repos' KBs** — grounding only annotates the repo currently being onboarded.
- **External docs other than Microsoft Learn** — AWS docs, GCP docs, generic OSS docs. Future grounding sources land as separate shared docs (e.g. `aws-docs-grounding.md`).
- **Replacing CLAUDE.md or codebase reading** — Learn is a corroboration source, not a substitute for actually reading the repo.

## Audit Trail

Each onboard run that triggers grounding writes the grounding outcomes to the detailed onboard report at `workspace/tmp/onboard-{domain}-{YYYY-MM-DD}.md` under a `## MS Learn Grounding` section:

```
## MS Learn Grounding

Candidates: 6
- MATCH: 4
- REFINE: 1
- CONFLICT: 0
- NO-COVERAGE: 1

### Verified
- `workspace/kb/projects/<domain>.md:142` — Azure Functions cold-start timing claim
  [verified against https://learn.microsoft.com/en-us/azure/azure-functions/...]

### Refined
- `workspace/kb/projects/<domain>.md:201` — was "default timeout 30s", Learn doc
  specifies "default 230s for HTTP-triggered functions on Consumption plan"
  [refined per https://learn.microsoft.com/en-us/azure/azure-functions/...]

### Conflicts (DO NOT auto-apply)
- (empty)

### No coverage
- `workspace/kb/projects/<domain>.md:88` — claim about an internal helper class;
  Learn returns no relevant doc (expected — repo-internal)
```

Conflicts also surface in the Step 8 confirm output as Open Questions.

## Relation to Other Validation

- **Step 6c Contract consistency** verifies this repo's outbound calls against other repos' inbound endpoints. Internal cross-validation.
- **Step 3j MS Learn grounding** verifies this repo's Microsoft-technology claims against external authoritative docs.

Both can run; they target different drift sources. Step 6c remains required; Step 3j is conditional on the Microsoft-stack trigger.
