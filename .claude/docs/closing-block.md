# Closing Block - Shared Reference

Canonical spec for the compact closing card that ends `/nase:today` and `/nase:wrap-up`. Both skills produce the same shape; only the TLDR source differs.

## Shape

Seven lines, with a blank line above to separate the card from the previous section. This card is the **last visible content** the user sees. Nothing follows it: no status line, reminder, or extra note. The questions a skill asks after the card, and the notes that report their outcome (the `/nase:today` todo review), are interaction, not content.

**Where it renders.** A skill that produces its result in chat (`/nase:today`) ends its chat reply with the card. A skill that writes its result to a file (`/nase:wrap-up`) puts the card at the end of that file **and** echoes it as the final block of its chat reply - the journal path plus highlights come first, the card comes last. Writing the card only into the file is a bug: the user closing the day never opens the file, so the card never shows.

**Render inside a fenced code block.** A Markdown viewer treats each `│` rail as its own paragraph and blows the card open with blank lines; the fence keeps the box tight and monospaced.

````
```
╭─ {Name}
│
│     {TLDR}
│
│     {tint}
│
╰─
```
````

- `{Name}` is the `AI engineer:` value from `workspace/config.md`, read once at section start. If the file is missing, use `nase`. Do not wrap it in `**...**`.
- `{TLDR}` is one sentence or fragment, at most 110 chars, in the `conversation:` language (see `language-config.md`). Use `·` between items. State concrete signal only: counts, hot PR numbers, blocker names, ticket keys, stale-KB counts. Skip generic openers ("today we...") and the visible label `TLDR:`.
- `{tint}` is one short line in the `conversation:` language, no visible `tint:` label. Use a real quote only when the quote and its attribution are known; otherwise write a plain dry remark about the work. Never aim it at a teammate, customer, identity, illness, or real-world tragedy. No motivational filler ("you got this", "stay focused"), no emoji.
- Do not use a blockquote `>`.

## TLDR source

- `/nase:today` - items from the Focus, blockers, PRs, Jira, and stale-KB sections already drafted in this run.
- `/nase:wrap-up` - items from today's actual outcomes (Steps 1-5: completed PRs and Jira, lessons captured, KB updates, blockers hit). The tint may look back at the day instead of ahead.
