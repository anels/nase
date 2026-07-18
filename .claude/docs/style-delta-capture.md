# Style Delta Capture Protocol

## Contents

- When to capture
- Daily Log Line Format
- Inline vs Batch Decision
- Section Mapping
- Wrap-up Consolidation (Step 4e)
- Anti-pollution Guards

Self-triggered learning loop. When the user corrects wording on a draft you produced, log the correction as a pending `[STYLE-DELTA]` line in the daily log. `/nase:wrap-up` Step 4e batches pending deltas into proposed edits to `workspace/communication-style.md` under a Tier B approval gate.

## When to capture

Capture a delta when **all** of the following hold:

1. **Surface** is one of: Slack draft, PR description/body, PR inline/review comment, external doc/announcement.
2. **You produced the draft first** — capture applies to corrections of AI output, not to user-original content.
3. **User intervened** via one of these patterns:
   - Replaces wording: "change X to Y" / "instead say X" / "改成 X" / "换成 X"
   - Removes wording: "drop X" / "remove X" / "don't say X" / "去掉 X" / "不要说 X"
   - Tightens: "shorter" / "more concise" / "terser" / "太长了" / "精简"
   - Tone shift: "too AI" / "too formal" / "less formal" / "sounds AI" / "AI 味"
   - Future rule: "next time..." / "from now on..." / "下次..." / "以后..."
   - Direct rewrite: user pastes the rewritten version back.
4. **Generalizable** — the correction implies a rule that applies to future drafts of similar artifacts. Skip one-off factual fixes such as a wrong name, wrong ticket id, or stale link.

Skip code changes, code comments, and internal KB/workspace docs; those follow normal repo/KB correction handling.

## Daily Log Line Format

Append to `workspace/logs/{YYYY-MM-DD}.md -> ## Sessions` immediately after the correction, following `.claude/docs/daily-log-format.md`:

```markdown
- {HH:MM} | style-delta: [STYLE-DELTA] surface={slack|pr-description|pr-review|external-doc|announcement} | before="{<=80 chars excerpt or summary}" -> after="{<=80 chars excerpt or summary}" | rule={one-line generalizable rule} | confidence={high|low}
```

Rules:

- One delta per line. Multi-edit corrections -> multiple lines.
- `before` / `after` excerpts: trim to <=80 chars; ellipsize middle if longer. Never dump multi-sentence drafts here.
- `rule`: phrase as a future directive, e.g. `Slack DM opening should not use "Quick one."`.
- `confidence=high` for unambiguous rule-level corrections; `confidence=low` for stylistic preference or one-off feel.
- CONFIDENTIAL: if the corrected artifact carried `[CONFIDENTIAL` content, do not quote `before`/`after`; replace both with `[redacted]` and keep only the rule.
- Pending deltas use the exact marker `[STYLE-DELTA]`. When a delta is applied or discarded, rewrite that same source line's marker to `[STYLE-DELTA-APPLIED]` or `[STYLE-DELTA-DISCARDED]`; do not append a second terminal line while leaving the original pending marker.

## Inline vs Batch Decision

- **`confidence=high` AND single self-contained rule**: log the delta, then ask whether to apply immediately.

  ```
  AskUserQuestion: "Apply this style rule to communication-style.md now?"
    - Apply now — open targeted edit in the matching section
    - Defer — leave in daily log; wrap-up will batch it
    - Discard — mark the source delta discarded; no style-doc change
  ```

  On Apply now: insert as a single bullet/example under the mapped section, then rewrite the source marker to `[STYLE-DELTA-APPLIED]`. On Discard: rewrite the source marker to `[STYLE-DELTA-DISCARDED]`. On Defer: leave `[STYLE-DELTA]` unchanged.

- **`confidence=low` OR cluster of related deltas**: skip the inline gate; rely on wrap-up.

- **3+ deltas in one session, regardless of confidence**: skip inline gates after the first; let wrap-up consolidate.

## Section Mapping

Map each `rule` to the right section of `workspace/communication-style.md` before drafting an edit. If a rule fits multiple sections, pick the most specific. New rules that fit none -> propose a new sub-bullet under the closest match; never invent new top-level sections without explicit user approval.

| Rule kind | Target |
|-----------|--------|
| Values, credit, no-blame framing | `## 核心原则` |
| Tone, greeting, register, language switching | `## 一、语言风格` |
| Surface-specific tone for Slack / PR description / PR review / external docs / announcements | `## 二、场景速查` |
| Habits such as cc, root-cause framing, scope-first, meeting hygiene | `## 三、固定习惯` |
| Technical phrasing patterns, review-comment shape, link + @ + ask format | `## 四、技术表达` |
| Terminology, fixed substitutions, abbreviations, emoji | `## 五、常用术语和语用` |
| AI-draft checklist additions | `## 六、AI 起草 checklist` |
| Stable baseline traits | `## 七、跨年度 baseline` |
| Anti-patterns | `## 八、不要做` |
| Banned AI wording or formatting | `## 九、AI 味 banned list` |

If the target surface does not exist in the scene table, add a new row with the surface name, register, and one canonical example.

## Wrap-up Consolidation (Step 4e)

`/nase:wrap-up` Step 4e:

1. Grep today's log for pending `\[STYLE-DELTA\]` lines only. Ignore `[STYLE-DELTA-APPLIED]` and `[STYLE-DELTA-DISCARDED]` terminal markers.
2. If none, set `style-delta=skipped-no-deltas`. Stop.
3. Cluster deltas by target section. Within each cluster, dedup near-identical rules using substring match or shared key phrase.
4. For each cluster, draft a concrete style-doc edit: added bullet, amended example, or banned-list entry. Cite daily-log lines as evidence (`source: log {time}, {time}`).
5. Show the consolidated style-doc diff in chat. Do not re-quote the original artifact text.
6. Gate the write with the Tier B approval question:

   ```
   AskUserQuestion: "Apply these style updates to communication-style.md?"
     - Apply all — write all clustered edits; mark source deltas applied
     - Apply selected — write selected clusters; mark selected source deltas applied; leave unselected pending
     - Edit — collect corrections, redraft, re-ask
     - Discard all — no write; mark source deltas discarded
   ```

7. On apply: write changes, update the `<!-- Last updated: YYYY-MM-DD -->` header if present, append one `style` lesson to `workspace/tasks/lessons.md` per `.claude/docs/lessons-format.md`, and rewrite processed source markers to `[STYLE-DELTA-APPLIED]`.
8. On discard: rewrite processed source markers to `[STYLE-DELTA-DISCARDED]` so the next wrap-up does not ask again.

## Anti-pollution Guards

- **No silent writes.** The shared doc only drafts; the user approves.
- **No duplicate bullets.** Before writing, grep the target section for the rule's key phrase. If present, skip with `existing-rule-already-covered` in chat.
- **No drift from existing voice.** Match the section's existing bullet/table style.
- **No new top-level sections without approval.**
- **Capture, not enforcement.** Future drafts still must follow `.claude/docs/voice-profile-routing.md`; this loop only updates the source profile at `workspace/communication-style.md`.
