---
name: nase:effort-rollup
description: "Build a monthly delivery report from live PR and Jira state. Use for effort rollup, impact report, month in review, or what did I ship."
argument-hint: "<YYYY-MM> [--repo <name>] [--scope <v>] [--md-only]"
pattern: utility
category: Reporting
---

Generate an evidence-backed monthly delivery report. Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Then follow `.claude/docs/skill-contract.md`.

## Workflow

1. Resolve `YYYY-MM`; default to the previous calendar month. Reject invalid or future-only ranges.

   **Lead with `efforts completed in the month`, not merged PRs.** After the stat strip, list efforts delivered and moved to `workspace/efforts/done/` that month. Count a row only when its canonical PR URL and live `mergedAt` resolve; include live Jira state when linked and accessible, otherwise mark the access gap. Use two counted buckets plus one process-gap list:
   - **delivered, code merged in-month** - the month's real code output;
   - **delivered, code merged earlier** - the month was the verification/release tail. Report it, and state that it must not be added to the merged-PR count;
   - **claimed delivered, unverified** - the doc cites bare `#NNNN` with no `owner/repo`, so nothing can resolve it. Name the process gap and exclude the row from the delivered headline.

   **Do not render `closed without delivery`.** Exclude `wontfix`, superseded, and unmerged PRs from both the list and headline count. Mention a dropped effort only where it explains another label.

   Merged-PR volume is supporting evidence below this section, never the headline.
2. Inventory every effort doc whose delivery intersects the month — **active and done both**. `.claude/scripts/month-efforts.sh` buckets `done/` docs by file mtime, which is a starting point, not the boundary: work delivered in-month often lives in a doc that is still active (`awaiting-deploy`) or was closed a month later, so its mtime is outside the window. To catch those, sweep the PRs cited across **all** effort docs and let the reconciled `mergedAt` (Step 4) decide membership — never let mtime alone scope the month, or you will undercount in-month merges sitting in active docs.
3. Read effort metadata through `.claude/docs/effort-lifecycle.md`. Treat frontmatter as a lead, not live truth.
4. Reconcile every structured delivery PR with `gh`. Split by actual `mergedAt` in the report month, closed without delivery, still open, or unreadable. Keep report-only and dependency PRs separate.
5. Reconcile linked Jira issues when access exists. Record access gaps; never infer Jira state from stale effort text.
6. **Mine measured impact.** For every effort delivering in the month whose scope is optimization / improvement / perf / coverage / pipeline (or whose doc states any baseline), open the doc and extract each concrete metric pair: `metric`, `from` (baseline value+unit), `to` (post value+unit), `delta`, source (Sonar / staging telemetry / pipeline timing / App Insights), and the merged PR that landed it. These numbers are the point of an impact report — carry them into the report verbatim, do not collapse them to prose. Label each value's confidence:
   - `verified` — you independently re-ran the metric this pass **and** confirmed the change mechanism is actually live (see enablement check); the observed after-value backs the claim.
   - `documented` — the doc states a measured before **and** after from a named source and the PR is merged, but the source was not reachable to re-run this pass. Fully reportable **with its numbers**; the label only flags "not re-run", never a reason to omit or vague-out the figures. State why it could not be re-run (retention rolled off, no access, metric never emitted).
   - `unverified` — target/ceiling only (e.g. "≤30 m"), or a baseline with no post-value. Never turn a target into a result; render it as a target, labelled.
   - `unrealized` — the capability merged but the live post-window contradicts the claim: the fast path takes ~0 traffic, the flag is off, the metric sits at baseline. This is a real, high-value finding — report the doc's target **and** the observed value side by side, and say the benefit has not landed yet. Do **not** massage the after-value to match the doc.

   **Actively re-measure — do not default to `documented`.** When a metric's own source is queryable for the report window, go pull it: App Insights via read-only Azure CLI KQL (latency p95, `resultCode` 499 rate, dependency/exception counts), Snowflake via `QUERY_HISTORY` / `WAREHOUSE_LOAD_HISTORY`, SonarCloud API (coverage %), ADO for pipeline wall time. Query a pre-deploy baseline window **and** a post-deploy window, pin the exact resource/warehouse/window, follow the App Insights / Snowflake query gotchas in KB before trusting an empty or truncated result.

   **Enablement check - shipped differs from realized.** A merged PR proves the capability exists, not that the benefit is live. Before crediting a before-to-after change, confirm the new path is actually exercised in the post window: the new endpoint, parameter, or route takes real traffic; the feature flag is on; or the frontend switched over. A post-window that looks identical to baseline indicates that the path may not be live yet. Classify that as `unrealized`, not as a measurement error to hide.

   Every `unrealized` row needs a mechanism and next action:
   - Compare pre/post App Insights `dependencies` by `type`/`target` for the exact `operation_Name`, including calls/request and per-call p50/p90. Check whether `calls × per-call` approximately reconstructs request latency; unchanged fan-out and per-call latency means the path did not move.
   - Read the effort investigation and shipped change site. Report the file:line, whether the measured path changed, and rollout/flag polarity. Distinguish *inert by design* (not enabled; roll it out) from *wrong lever* (enabled but flat; redesign the intervention).

   If live evidence conflicts with the effort doc, re-read its attribution, rejected alternatives, Lifecycle state, and next step, then report both the documented claim and measured correction. Name what would work and cite an in-month PR that proves the shape when available. Never stop at `flat, cause unknown`, strip documented numbers, skip a reachable live query, or credit a result without the enablement check.
7. Write `workspace/recaps/effort-rollup-{YYYY-MM}.md`. Unless `--md-only`, also write a self-contained HTML report with the same facts and no remote assets.

   **The HTML must be VISUAL - charts, not converted tables.** Do not generate it by running the Markdown through a converter; that produces a table dump and silently drops every chart. Hand-author the HTML (or template it) and read the previous month's `workspace/recaps/effort-rollup-*.html` first as the visual reference to carry forward: masthead + stat strip, before→after bar rows, incident cards, theme cards, collapsible per-repo appendix.

   Build the charts with self-contained HTML and CSS:
   - **Every Step-6 metric pair gets a paired bar**: grey `before` above and accent `after` below, plus the exact `from → to → delta` numbers and the confidence chip. A metric pair that appears only as a table row is incomplete.
   - **Scaling:** shrink-is-better metrics (latency, volume, noise, cost) scale against that row's own `before` = 100%; percent metrics (coverage, hit rate) use the natural 0–100% scale. State which is which in the footer; mixed scales must be labelled.
   - **`unrealized` rows get two near-equal bars in the critical color.** Flatness is the finding; make it visible.
   - Use distinct colors for the accent, the `before` neutral against its track, and the status trio. Direct-label every bar with its numbers and retain the full table view below.
   - Light **and** dark tokens, both stamped (`prefers-color-scheme` + `:root[data-theme=…]`).
   - Self-contained: zero `<script>` / `<link>` / `src=` / `@import`; verify tag balance.
   - **Render and look at it before claiming done** - screenshot with headless Chrome in both themes and confirm that filled bars remain distinguishable from their tracks.

   If the user asks for a shareable link, use an approved publishing destination available in that session. **Scrub credentials and audience-restricted data first** - including subscription GUIDs, resource IDs, customer, tenant, and resource names, internal URLs, and tokens - from both the Markdown and the HTML. Keep stable redacted labels where the comparison needs identity continuity.
8. **Classify then narrate — the report is not just bookkeeping tables.** Bucket every delivered effort by work type, reading `scope:` frontmatter + the linked Jira issuetype + the merged PRs' conventional-commit prefix (`feat`/`fix`/`perf`/`test`/`ci`/`chore`) + any `SRE-*` / customer-escalation reference. Then render every section that has content (skip an empty one, but never silently drop a populated one):
   - **`Measured impact — before → after`** — the Step-6 metric pairs grouped by category (query perf, coverage, CI/CD, cost, …); each row `metric · from → to · delta · confidence-label · PR link`.
   - **`Production incidents resolved`** — one card per `SRE-*` / customer-escalation effort, each with **Problem → Root cause → Fix**, live Jira status, and the PR(s). This is the highest-signal section for on-call/customer work; mine the doc's RCA and fix narrative, don't reduce it to a table row.
   - **`New features & capabilities`** — efforts scoped `feature` or led by `feat()` PRs, one line each: what shipped + user-facing effect + PR.
   - **`What shipped, by theme`** — a compact grouped index (incident resolution, features, perf, coverage, security, CI/CD, docs, …) with effort names + PR shorthands, so the reader sees the month's shape at a glance.
   - **`PR appendix — merged in {month}`** — the full reconciled list of in-month merged PRs, **grouped by repo** (collapsible `<details>` per repo in HTML), each row: PR number (linked), state, `mergedAt` date, and title. This is the auditable backing for the counts above; every PR the report leans on appears here as a clickable link.
   - Bookkeeping: **delivery totals**, **active carryover**, **verification gaps**, **per-effort source links**.

   Order the narrative sections (impact, incidents, features, themes) above the bookkeeping tables — a reader scanning the top should see *what changed and what it was worth*, not raw PR counts.

   **Every PR and Jira reference is a clickable link.** Never emit a bare `#4664` or `IN-13355` as plain text — render PRs as `https://github.com/{owner}/{repo}/pull/{n}` and Jira keys as `{baseUrl}/browse/{KEY}` (baseUrl from `workspace/config.md`), in **both** the Markdown and the HTML. The report is a navigation surface: a reader clicks straight through to the PR diff or the Jira ticket. The PR appendix guarantees full PR coverage; inline mentions in impact/incident/feature rows link too.
9. Append the daily-log entry using `.claude/docs/daily-log-format.md` and return only the artifact pointer plus up to five highlights.

Do not mutate effort lifecycle, PRs, Jira, or GitHub. A PR merged outside the month stays outside the in-month merged-PR count. An effort completed during the month may still appear under `delivered, code merged earlier` after its PR and Jira evidence are reconciled.
