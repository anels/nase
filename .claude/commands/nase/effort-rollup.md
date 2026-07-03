---
name: nase:effort-rollup
description: "Generate a monthly delivered-work report from completed efforts, reconciled against live GitHub PR state and Jira status, with before→after impact metrics and a self-contained HTML report artifact. Use for monthly report, month in review, what did I ship in <month>, effort rollup, monthly retrospective, impact report, or 'make me that report again'. Distinct from /nase:efforts (present-tense active inventory), /nase:recap (prose narrative), and /nase:stats (activity counts) — this one pulls live PR/Jira data, splits delivered vs closed-without-delivery, and produces a visual report."
when_to_use: "Monthly delivered-work report from completed efforts, reconciled against live GitHub PR state and Jira status, with before→after impact and a self-contained HTML artifact. Triggers: monthly report, month in review, what did I ship in <month>, effort rollup, retrospective. Splits delivered vs closed-without-delivery; pulls live data, not frontmatter."
argument-hint: "<YYYY-MM> [--repo <name>] [--scope <v>] [--md-only]"
pattern: utility
category: Reporting
---

Produce a month-scoped report of **delivered** engineering work from the efforts closed to `workspace/efforts/done/`, grounded in live GitHub + Jira state rather than the effort docs' own frontmatter. Output is a self-contained HTML report artifact plus a Markdown source under `workspace/stats/`. Triggers: 'monthly report', 'month in review', 'what did I ship in June', 'effort rollup', 'monthly retrospective', 'impact report', 'generate that report again'.

**Why this exists (and why not just read the docs):** an effort sitting in `done/` was *closed*, which is not the same as *delivered* — some are wontfix/superseded/reopened and shipped nothing. And an effort's completion month (file mtime) is not its PRs' merge month — much of the code often merged weeks earlier. A report that trusts frontmatter inflates the numbers. The value here is the reconciliation: pull the real PR merge state and Jira status, then report only what actually shipped in the window, honestly split from the tail work.

## Step 0 — Language preflight (run first)

Follow `.claude/docs/language-config.md` → Minimum Step 0 block. Read `workspace/config.md`. Chat-facing prose (progress, the closing summary) uses `conversation:`. **The report artifact + Markdown file content use `output:` language** (this is external-shaped even though it lives locally — keep it in `output:` so it's shareable). English stays for identifiers: repo/PR/Jira refs, `file:line`, metric names.

## Input

- **Month**: `YYYY-MM` (e.g. `2026-06`). Accept `YYYY/MM` too. If the user says "last month" / "this month", resolve against `currentDate`. If ambiguous, ask.
- Optional `--repo <name>` / `--scope <value>` to filter, `--md-only` to skip the HTML artifact.

## Workflow

### 1. Inventory the month

Run the helper — it buckets `done/` efforts by mtime and pre-extracts each doc's PR + Jira refs so the extractor reads only in-scope files:

```bash
bash .claude/scripts/month-efforts.sh "$MONTH"   # e.g. MONTH=2026-06
```

If zero efforts match, say so and stop. `done/` is the source of truth for "closed" — do not scan active `efforts/*.md`.

### 2. Extract effort records (delegate — keep main context clean)

Fan the in-scope slugs to a **read-only** `nase-workspace-state-scanner` (or `general-purpose`) subagent. Ask it to return, per effort, a compact record: `slug · repo · jira key · one-line what-shipped · PR list · frontmatter status · one-line stated impact (metric/incident/coverage/severity)`. Terse facts, no prose. Batch all slugs into one agent; for 30+ efforts this is far cheaper than reading each doc in the main thread.

### 3. Pull live GitHub + Jira state (the reconciliation — this is the point)

**GitHub PRs** — collect every PR referenced by the month's efforts, group by repo (`<org>/<repo>` from the effort's `repo:` frontmatter and its KB/`.local-paths` entry), and fan out `nase-pr-metadata-reader` agents (one per repo, or per ~2 small repos). Each runs, for each PR:

```bash
gh pr view "$PR" --repo "$ORG/$REPO" --json number,title,state,mergedAt,createdAt,additions,deletions,changedFiles,baseRefName
```

Preflight `gh auth status --active` first. If your org requires a specific work account (some workspaces keep a personal default that the active `gh` account silently flips back to), switch to it before the reads — check your workspace's git/gh convention (KB or `.local-paths`). Return a table per repo: PR · state · mergedAt · +add/−del · files · baseRef · title. This confirms merge state *and* actual merge date (which decides the month split in step 4). When a doc references a fix by description but not number, have the agent `gh pr list --search`.

**Jira** — one `searchJiraIssuesUsingJql` call for all keys (cloudId + baseUrl from `workspace/config.md → ## Jira`); skip cleanly if no Jira MCP is connected:

```
jql: key in (KEY-1, KEY-2, ...) ORDER BY key
fields: key, summary, status, resolution, priority, assignee, updated
```

Read status names literally: `Merged`/`Closed`/`Resolved`/`Done` = delivered; `Reopened`/`In Progress`/`To Do` = **not** delivered.

### 4. Reconcile — two honest splits

This is where the report earns its keep. Two independent axes:

**(a) Delivered vs closed-without-delivery.** An effort counts as *delivered* only if it actually shipped. Demote to "closed w/o delivery" when the evidence says nothing shipped, using both signals:
- frontmatter `status: wontfix` / `superseded_by:` present, **and/or**
- its own PR(s) all CLOSED-not-merged, **and/or**
- Jira `Reopened` / still `In Progress`.

Where signals conflict (e.g. two PRs merged but `status: wontfix`, or a fix shipped but Jira reopened pending verification), **do not silently pick** — list it as ambiguous and state which way you counted and why. The headline count is *delivered*, with "N closed / M delivered / K without delivery". Incidents left at `Resolved` (awaiting reporter verification) count as delivered — that is a normal closed state, not a gap.

**(b) Effort-closed-this-month vs PR-merged-this-month.** Split PRs by real `mergedAt`: those merged inside the window are the month's throughput; PRs merged earlier (the effort just closed/verified this month) go in a separate "prior work" bucket and are **excluded from the month's PR/line counters**. Say this in the footer — a reader must not mistake the effort-chain total for the month's output.

Compute month-window totals: delivered efforts, PRs merged in-window, lines added (in-window merged only), incidents resolved.

### 5. Before→after impact — extract claims, then validate against live data

For efforts scoped as optimization/improvement (perf, coverage, pipeline, cost), pull the claimed baseline→result from the effort doc. Present grouped by kind — e.g. **Query performance**, **Test coverage**, **Cost & telemetry** — each metric a `before → after (delta)` row with the driving PR linked.

**Do not stop at the doc's claim — go get the real number.** A doc's stated metric is a claim, not evidence; some are estimates, projections, or stale. A well-written effort doc records *how* it should be verified — the `### Validation` section (`/nase:design` C4b) names the data source + the exact query/command. Read that method and re-run it against the live source of truth. Then tag each number:
- **✓ live-verified** — you re-ran the check and it agrees (cite the query + date).
- **⚠ doc-sourced** — the doc's own measurement, not re-derivable now (historical/pre-deploy state, a deleted export, an external portal). Say why.
- **projection vs measurement** — a "top-3 = 88% of cost" saving is a projection; a queried post-deploy value is a measurement. Never present a projection as a measured result. Ceilings ("≤30 m") are targets, not post-values.

**Generic sources (apply anywhere):**
- **PR-level claims** (line deltas, files, count of things added) → `gh pr diff <n> --repo <org>/<repo>` and count. Cheapest and most definitive — do these first.
- **Coverage %** → the coverage tool's own report on the merged branch (e.g. SonarCloud `component_tree`), not a local re-run — local and CI coverage diverge when a test project isn't wired into CI.
- **HTTP/telemetry counts, latency** → the app's telemetry backend (App Insights, Datadog, etc.) queried over an explicit time window.
- **Pipeline timings** → the CI/CD run history for the pipeline, not the doc's estimate.

**Telemetry gotchas worth knowing (learned the hard way; apply when they fit):**
- **Azure App Insights that is workspace-based** (`az monitor app-insights component show … --query ingestionMode` = `LogAnalytics`): the classic App Insights query API returns **empty** even when data exists — query the backing Log Analytics workspace directly (`az monitor log-analytics query --workspace <customerId-GUID>`, tables `AppEvents`/`AppTraces`/`AppRequests`, columns `Name`/`TimeGenerated`, not `customEvents`/`timestamp`).
- **Always pass a time window** to `az monitor` queries (`--offset 14d` or explicit UTC start/end) — with no window the default span is minutes wide, so a real metric returns a false empty.
- **Snowflake `ACCOUNT_USAGE.QUERY_HISTORY`**: set `TIMEZONE='UTC'` or literal windows are read in the session TZ; split COMPILATION vs EXECUTION time before attributing scan cost.

Workspace-specific validation recipes (which telemetry resource backs which service, CLI access ladders, PIM/subscription notes) live in your workspace KB and CLI docs — read `.claude/docs/cli-tooling.md` for the tooling baseline and the workspace's own KB (e.g. cloud/resource-link notes) for the concrete resource names. Preflight `az account show` / `gh auth status`. If a number genuinely cannot be re-derived (deleted export, historical pre-deploy prod state, a subscription behind PIM you can't reach), say so plainly — an honest ⚠ beats a confident restatement.

### 6. Build the report artifact

Load the `artifact-design` skill first, then build a **utilitarian data-report** (not an editorial hero) — this is a scan-and-operate document. Self-contained per the Artifact CSP: inline CSS, no external fonts (system stack + tabular-nums for figures), no remote assets. Keep the palette to a considered neutral + one accent + semantic good/warn/bad for status. Recommended sections, summary before detail:

1. **Masthead + stat strip** — delivered/closed counts, in-window PRs merged, lines added, incidents resolved. Headline the honest number (delivered, in-window). Lead the strip with a live-verified figure where you have one.
2. **Measured impact — before → after**, grouped by kind (§5), with PR/Jira links and a per-number verification tag (✓ live-verified with query+date, ⚠ doc-sourced, or *projection*). A short "Live verification" note under the group should cite the actual query and what it returned. **Render each metric as a before→after row with a two-bar visualization, not a plain text line** — a group header (`KIND · N metrics · scope · verification tag`), then per metric: label + sub-line (driving PR/Jira ref), a right-aligned `before → after` where the after value is the emphasized figure plus a delta chip (`+55.9 pt` / `−98%` / `eliminated` / `gate met`), and **below it two stacked horizontal bars on a faint track — a grey `before` fill and an accent/good `after` fill, widths proportional to the values** (normalize per metric to a sensible max; for reduction metrics the shrinking `after` bar reads as the win). This bar treatment is the section's signature; do not drop it for a bare table. The verification tag still gates honesty — a *projection* group (targets verified only post-rollout) keeps the bars but must be labeled `projection`, never shown as a measured result.
3. **Production incidents** — one card each: *Problem · Root cause · Fix* + severity/status chips + fix PRs. This is what makes the report read as real engineering, not a commit list. If the month had none, skip the section rather than padding it.
4. **Tracked delivery items** — Jira table with live status chips; flag Reopened/In-Progress.
5. **Delivered-vs-closed callout** — name the closed-without-delivery efforts and why (§4a).
6. **What shipped, by theme** — cards grouping the efforts.
7. **PR appendix** — in-window merged PRs per repo, every PR number linked to `github.com/<org>/<repo>/pull/<N>`; a collapsed "prior work (merged earlier)" table (§4b).
8. **Footer** — data sources, pull date, the month split, and a **per-number verification status** block: what was live/source-verified (with tool) vs what stays doc/CSV-sourced and why it can't be re-derived.

Write the file to `workspace/stats/<month>-efforts-report.html`, then publish with the `Artifact` tool. Also keep a Markdown source at `workspace/stats/<month>-efforts-rollup.md` for diffable history. `--md-only` skips the artifact.

### 7. Log + summarize

Append one line to `workspace/logs/YYYY-MM-DD.md` per `.claude/docs/daily-log-format.md`:
```
- {HH:MM} | effort-rollup: {month} — {delivered}/{closed} delivered, {prs} PRs in-window, {incidents} incidents
```

Then per `.claude/docs/skill-contract.md`: chat reply is the artifact link + a bounded summary (delivered count, top impact metric, incidents, and any reconciliation surprises — e.g. "3 closed w/o delivery", "21 PRs merged in prior months"). Full detail lives in the artifact.

## Notes

- **Read-only on lifecycle.** This skill reports; it never moves efforts between `done/` and active — that is `/nase:today`'s job (`.claude/docs/effort-lifecycle.md`). If reconciliation shows a `done/` effort that reopened, surface it and suggest `/nase:today`; don't mutate.
- **External writes stay gated.** The report is local; no Jira/Slack/GitHub writes. Links only.
- **Honesty over impressiveness.** The whole reason to pull live data is to avoid a rosy report. If the delivered number is lower than the closed number, that *is* the finding — say it plainly.
