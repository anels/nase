# Closing Block — Shared Reference

## Contents

- Shape
- Name resolution
- Tint: style palette (pick one per run)
- Tint generation rules
- TLDR rules
- `deadpan` style: seed bank
- Dark / cold tint seed bank
- EOD tint variant (`/nase:wrap-up` only)

Canonical spec for the compact closing card that ends `/nase:today` and `/nase:wrap-up`. Both skills produce the same shape; only the TLDR source differs.

---

## Shape

Seven plain lines, blank line above to separate from the previous section. This card is the **last visible content** in the command output or journal file. Nothing follows it: no status line, reminder, or extra note.

```
╭─ {Name}
│
│     {TLDR}
│
│     {tint}
│
╰─
```

1. **`╭─ {Name}`** — opener line. NOT wrapped in `**...**`.
2. **`│`** — blank rail line.
3. **`│     {TLDR}`** — one sentence/fragment, ≤ 110 chars, conversation language. `·` (middot) as separator when listing items. State items, not intent — skip generic openers. Do not include a visible `TLDR:` label.
4. **`│`** — blank rail line.
5. **`│     {tint}`** — one-liner (style palette below). Memorable, not a plan summary. Do not include a visible `tint:` label.
6. **`│`** — blank rail line.
7. **`╰─`** — closing rail. No text after it.

Do NOT use blockquote `>`.

## Name resolution

`{Name}` = the `AI engineer:` value from `workspace/config.md`. Read it once at section start. If the file is missing, fall back to `nase`.

## Tint — style palette (pick one per run)

Examples are English for compactness. The actual tint is rendered in the user's conversation language (see `language-config.md`); only an attributed `quote` may keep its original-language wording.

| Style | Shape | Example |
|---|---|---|
| `quote` | Attributed line, real person; famous quotes allowed | "Programs must be written for people to read, and only incidentally for machines to execute." — Abelson and Sussman |
| `proverb` | Cultural saying, idiom | "Measure twice, cut once." |
| `original` | Your own aphorism | "A reviewer is the upstream's last sieve — the bugs it misses don't grow legs and walk away." |
| `joke` | Dry programmer humor, no setup-punchline | "Main branch put on three pounds today." |
| `dark-humor` | Gallows humor about tools/process/time, never real harm or real people | "The build passed. Clearly nobody told it about tomorrow." |
| `ice-cold` | High-cold sarcasm; elegant, brief, no cruelty | "The stale KB has entered its principal-engineer era." |
| `motivation` | Encouraging, not cheesy | "Small steps, fast. No need to wait for perfect." |
| `observation` | Wry remark on the work / day | "Waiting for a reply is like waiting for water to boil — the longer you stare, the slower it goes." |
| `zen` | Spacious, no moral, no instruction | "The PR is not merged, yet it is on its way." |
| `chuuni` | Anime-villain energy, fully committed | "The sealed compiler within my left hand stirs again. Today, it shall taste blood." |
| `absurd` | Non-sequitur, deliberately ridiculous | "Every semicolon is a tiny coffin for a thought." |
| `solemn` | Ceremonial, carved-in-stone | "Let the record show: on this day, the build was green." |
| `playful` | Cheeky, impish wink, no punchline | "The bug knows you're looking — that's why it's hiding behind the semicolon." |
| `deadpan` | Flat affect on a load-bearing line; treat the trivial as cosmic, the cosmic as trivial; self-deprecating without bitterness | "I've reopened this PR five times. The reviewer never flipped a card." |

## Tint generation rules

1. **Contextual is optional.** If a sharp hook exists (a stuck PR, a number, a stale KB), feel free to use it. If nothing fits, an off-topic line is often more memorable. Don't force.
2. **One line.** No explanation, no follow-up, no emoji unless the style calls for one.
3. **Conversation language.** See `language-config.md`. Tint goes in `conversation:` language. Exception: a `quote` may keep its original wording if translation loses the bite.
4. **Funny can be sharp, not mean.** Dark humor and sarcasm target the work, tooling, process, entropy, or the speaker's own fate. Never punch at a teammate, customer, identity, illness, layoff, death, or real-world tragedy.
5. **Quote discipline.** Use `quote` only when the quote and attribution are known. If unsure, convert it into `original` instead of guessing.
6. **Anti-AI-slop — never use these or their cousins:**
   - "stay focused" / "you got this" / "let's crush it" / "let's go!" / "keep pushing"
   - "remember to..." / "don't forget that..." / "as they say..."
   - Generic affirmation ("great work!", "amazing!")
   - Hashtag-style optimism ("#GrindMode")
   - 💪 / 🚀 / 🔥 as substitute for substance
7. **Rotate style — cheap check.** Look at the prior closing card's tint line only (one file: today → `workspace/logs/{yesterday}.md`; wrap-up → most recent `workspace/journals/*.md`). In the new format, this is the second non-empty `│     ...` content line inside the closing card. During the format migration, fall back to `│ tint:` and then the legacy `｜` line. Pick a different style. Best-effort, not a strict scan.
8. **Be willing to be weird.** A zen koan, a Lu Xun pastiche, a deadpan one-liner about the weather — these stick. Corporate-poster aphorisms do not.

## TLDR rules

- ≤ 110 chars, single sentence/fragment, conversation language.
- `·` (middot) as item separator. Concrete signal only: counts, hot PR numbers, blocker names, ticket keys, stale-KB counts.
- Skip generic openers ("today we...", "we completed..."). State items, not intent.
- **Source of items differs by skill:**
  - `/nase:today` — items lifted from Focus + blockers + PRs + Jira + stale-KB sections already drafted in this run.
  - `/nase:wrap-up` — items lifted from today's actual outcomes (Steps 1–5: completed PRs/Jira, lessons captured, KB updates, blockers hit).

## `deadpan` style — seed bank

When picking `deadpan`, draw on these as shape references (don't copy verbatim; generate fresh in context). These are English shape-references — render the actual tint in the user's `conversation:` language per rule 3.

- "I've reopened this PR five times. The reviewer never flipped a card."
- "I'm not bad at tests. I'm afraid they'll actually pass."
- "The mountain pass and this schema migration both look straight from a distance."
- "'Think this can merge?' 'Sure. Before I retire.'"
- "Ten thousand rebases for this one force-push."
- "When deploy goes red I'm the calmest in the room. Practice."
- "Leave a TODO. Leave yourself a thread to come back to."
- "It's not a bug. It's an unfinished thread between us."

Recipe: one concrete engineering action (PR / rebase / deploy / migration) + a reaction that intentionally over-reads it as a life truth. Short sentences. Negative space. No explanation.

## Dark / cold tint seed bank

Use these as shape references for `dark-humor` and `ice-cold`; do not copy verbatim.

- "The build is green. Suspiciously green."
- "The ticket is not blocked. It is enjoying a long strategic pause."
- "The flaky test has chosen violence, but only on CI."
- "The stale runbook has achieved historical landmark status."
- "Production remains undefeated."
- "The TODO survived another refactor. Nature is healing."
- "A clean diff. A rare artifact, best viewed from a distance."

Recipe: choose one mildly painful fact, give it a straight face, stop before explaining the joke.

## EOD tint variant (`/nase:wrap-up` only)

The tint may be reflective (look-back at the day) rather than forward-looking. Same palette, same anti-AI-slop rules.
