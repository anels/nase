# Plain Writing Guard

Cross-surface lint that strips LLM register from outbound English text and enforces readable shape. Read before finalizing any Slack, PR, Jira, Confluence, or external draft.

Every outbound draft this workspace produces is written by a model, so it inherits the model's register by default: noun-heavy, evenly paced, upbeat, specific about nothing. The cost is not embarrassment. It is that a reader who recognizes the shape stops reading for content and starts skimming for the ask.

This doc is the generic floor. `.claude/docs/voice-profile-routing.md` owns the per-surface contract and `workspace/communication-style.md` owns the voice on top of it.

**Scope:** outbound English text only. Local `workspace/` files, code, code comments, and repo docs are out of scope.

**Rules dated 2026-08-28.** Marker vocabulary decays once it is published: Kobak et al. state their own method fails when an author strips the style words, and `delve` / `intricate` / `showcasing` / `realm` measurably dropped in arXiv abstracts after they were publicly named. Re-measure by 2027-02 instead of treating the list as permanent.

## Contents

- Part 0: Order of operations
- Part 1: Shape
- Part 2: Syntax
- Part 3: Register
- Part 4: Templated shapes
- Part 5: What this guard does NOT ask for
- Part 6: Pre-send self-check
- Part 7: The mechanical pass
- Evidence

---

## Part 0: Order of operations

Shape first, then words. A structurally wrong message with clean vocabulary is still unreadable; a well-shaped message with two flagged words is fine.

1. Fix the shape (Part 1).
2. Fix the syntax (Part 2).
3. Fix the register (Part 3).
4. Delete the templated shapes (Part 4).
5. Count what is left against the threshold (Part 6), then run the script (Part 7).

---

## Part 1: Shape

### Universal

- **Bottom line first.** Purpose and conclusion in the opening sentence; background at the end or behind a link. Microsoft states the rule at sub-sentence granularity: important keywords go near the beginning of headings, table entries, and paragraphs, not only at the top of the document.
- **One purpose per artifact.** One message, one ask. One ticket, one outcome. One PR, one change.
- **Same term for the same thing, every time.** Synonym rotation across a document is a clarity defect, not variety.
- **Specifics carry the message.** Names, dates, counts, ticket ids, file paths, durations. A sentence that survives having every number removed was not saying much. This is the highest-value rule in the doc: after feedback training, generality-versus-specificity was the only stylistic cue that still predicted correct AI identification (p=0.044). Every other cue readers reach for is a stereotype they abandon once calibrated.
- **Then stop.** Microsoft's brevity rule is three steps: use short simple words, get to the point, then stop. The wrap-up paragraph that restates what was already said is the most common AI ending.

### `slack-dm` / `slack-channel`

- First line is the topic or the ask. Never a standalone greeting or ping.
- Self-contained: carry all the context the recipient needs to act. This matters most across time zones, where nobody can ask a quick follow-up.
- Structured formatting is fine in longer messages. The tell is the mechanical three-parallel-item list, not the existence of a list.
- Mechanics that break the rendered message live in `.claude/docs/slack-draft-style.md`, which stays their source of truth. `prose-lint.py` enforces three of them: no `<url|label>` embed, no bare URL ending a line whose next line is non-empty, and `- item` for bullets rather than a literal bullet character, which is plain text and never renders as a list. If this doc and Formatting Mechanics ever disagree, Formatting Mechanics wins - it describes what the draft tool does to the body.

### `github-pr-body`

- Three elements: why the change is needed, what changed, where reviewers should look. Name files and review order when the diff is wide.
- Name the verification commands actually run.
- A generated summary is a starting point that still needs the context only the author has.

### `github-review-comment` / `github-review-reply`

- **Anchor every comment to a hunk.** 87.0% of file-level comments produced no subsequent code change against 51.9% for hunk-level; in a manual sample of 30 PR-level comments exactly one was even partially addressed, and that one named a concrete code change.
- **Short, with code.** Comment length correlates negatively with being addressed (rho = -0.24) while code-to-text ratio correlates strongly positively (rho = +0.89), multi-line code blocks at rho = +0.67. A short comment with a copy-pasteable block beats a paragraph of prose.
- **Say the concrete change.** `Suggest to test thoroughly` is a measurable failure class, not a mild one: across 16 AI review tools, 178 repositories, and 22,000+ comments, valid human comments led to code changes 60% of the time against 0.9%-19.2% for AI comments.
- **Comment on the code, never on the developer.** Google's own contrastive example rejects `Why did you use threads here` in favor of a statement about the code's properties.
- **Point out the problem; the author decides the fix.** Reviewers are not required to design the solution. This bounds the model's habit of writing a full replacement implementation in every comment.
- **No intent-label prefix.** Google's guide recommends `Nit:` / `Optional:` / `FYI:`, and this workspace deliberately does not follow it. `.claude/docs/discuss-pr-output.md` carries `kind` and `disposition` in the chat report and in the review state, so opening the posted comment with the label spends the first line restating a classification the author cannot act on. Start on the claim. The problem the prefix solves elsewhere - severity buried in softened prose - is solved here by dropping the softeners instead.
- **No courtesy opener when replying to a bot reviewer.** A bot does not read tone, so `Good catch` is pure noise in front of the evidence. Warmth stays available for human reviewers, so this is a judgment call the linter cannot make for you.

### `jira-ticket`

- Title is an imperative starting with a verb. Test it: `To complete this ticket, I need to {title}` must read as a sentence.
- Body carries Context / Scope / Acceptance / References. Acceptance criteria must be concrete and checkable.
- The defect in a bad ticket is missing information, not bad prose. The completeness bar is operational: the ticket is good when it triggers no follow-up questions.
- Pull scattered context into the ticket. The measurable cost of leaving it in Slack is developer time spent hunting for the original message.

### `confluence-doc` / `announcement`

- Open with the decision or the status, not with context-setting.
- Options get a recommendation, not a neutral survey.
- Three to seven lines is the target paragraph length, with the occasional single-line paragraph.

---

## Part 2: Syntax

Instruction-tuned models overuse a small set of constructions that add length without adding content. These are the highest-yield rewrites because, unlike vocabulary, a reader feels them without being able to name them.

| Overused construction | Measured vs human | Rewrite to |
|---|---|---|
| Trailing present-participial clause (`..., ensuring X`) | ~5.3x, d=1.38 | Full sentence, or delete |
| `That`-clause as subject (`That the pipeline failed suggests...`) | ~2.6x, d=0.77 | `The pipeline failed, which suggests...` |
| Nominalization (`perform a migration of`) | ~2.1x, d=1.23 | Verb (`migrate`) |
| Phrasal coordination (`accurate and reliable and timely`) | ~1.9x, d=0.81 | Pick the one that is load-bearing |

Two more:

- **Short sentences are nearly absent from model output.** Keep them. A three-word sentence after a long one is the cheapest readability gain available.
- **Models avoid specifics, and the syntax follows.** Human professional writing carries bare proper-name noun phrases, measure phrases, fragments, and attribution verbs. Model writing replaces those with modifier-stacked coordinated noun phrases. Replace the stacks with names, dates, measures, and attributed statements.

**Active voice is a readability rule here, not an anti-AI rule.** Models use agentless passive at roughly *half* the human rate, so passive-heavy prose is not an LLM tell and "use active voice" does not remove the AI signature. Keep the rule because dropping the actor leaves the reader unable to tell who must act - which is exactly the failure mode of a hedged review comment. Google's own guide sanctions passive in three cases: emphasizing the object, de-emphasizing blame, and when the actor is irrelevant. A blanket ban overshoots the source.

Prompting the model to "write casually" does not fix any of this. The register deviation comes from instruction tuning, not from the prompt, and it survives an explicit informal-register instruction. The fix has to be stated as concrete structural rules.

---

## Part 3: Register

The measurable LLM vocabulary shift is almost entirely **style words**: of the 379 excess style words in 2024, 66% were verbs and 14% were adjectives. Earlier vocabulary shifts (ebola, zika, covid) were content nouns, 79.2% of them. Topic nouns are not the problem. Flag the verb and adjective register.

**Tier 1 - corpus-measured excess vocabulary.** Rewrite on sight in engineering-channel text.

```
delve(s/d/ing), deep dive, underscore(s/d/ing), showcase(s/d/ing), boasts,
garner(ed), intricate, intricacies, surpass(es/ed/ing), realm, groundbreaking,
advancements, align(s) with, emphasizing, crucial, pivotal, seamless(ly),
nuanced, leveraging, meticulous(ly), tapestry, testament, palpable, camaraderie,
amidst, foster(s/ed/ing), bolster(s/ed/ing), interplay, landscape, vibrant,
enduring, holistic, transformative
```

**Tier 2 - house-style bans**, independent of any AI framing. These hold even if no model were involved.

| Flagged | Use instead |
|---|---|
| `leverage` | `use`, `build on` |
| `utilize` | `use` |
| `commence` | `start` |
| `unpack` | `explain` |
| `in order to` | `to` |
| `allows you to` | `lets you` |
| `please note` | delete |
| `easily`, `simply` | delete - it is not easy for everyone |

**Tier 3 - empty intensifiers.** Delete outright: `absolutely`, `completely`, `totally`, `really`, `quite`, `very`, `robust`, `valuable`, `enhance`, `highlight`.

**Register caveat.** The problem is genre fit, not the words in the abstract. A Tier 1 word is unremarkable in fiction and conspicuous in an engineering channel. In a Jira comment it is never right.

**Separate distinctive tells from ordinary vocabulary.** `significant`, `additionally`, `potential`, and `findings` all appear in the excess-vocabulary data but kept rising in frequency even after LLM-marker lists circulated, because they are also normal professional words. They are deliberately absent from the tiers above. A ban list that does not make this distinction produces false positives on real writing.

---

## Part 4: Templated shapes

Delete on sight.

- **Fixed openers and closers.** `Certainly,` `Moreover,` `In conclusion,` `Overall,` `I hope this helps.` `Let me know if you have any questions.` `Great question.` A closing line that would fit any message is not carrying information.
- **Antithesis frame.** `It's not just X, it's Y.` `Not A, but B.` `No X, no Y, just Z.` Drop the contrast and assert the point.
- **Rule of three.** Mechanical three-item parallel lists and three-adjective runs. The function is to make shallow content look complete. If the third item exists to finish the rhythm, cut it.
- **Hedging preamble.** `It's worth noting that`, `Generally speaking`, `It's important to note that`. A hedge often sits in front of something unchecked: verify the claim, then delete the preamble.
- **Significance inflation.** `plays a crucial role`, `stands as a testament`, `a game changer`.
- **Vague attribution.** `experts argue`, `industry reports suggest`, `it is widely recognized`. Name the source or drop the sentence.
- **False agency.** `the data tells us`, `the decision emerges`, `the market rewards`. Name the actor, or address the reader as `you`.
- **Redundant restatement.** A sentence that repeats the previous one in different words. Common at paragraph boundaries.
- **Formatting tells.** Boldface on more than a few words per screen; emoji as bullet markers; a vertical list where every item begins with a bolded inline header; title-case headings; curly quotes.
- **Em dash.** Banned as house style. It is *not* reliable evidence of AI authorship: Microsoft prescribes the unspaced em dash as correct house style, GPT-5.1 was tuned to suppress it, and a July 2026 study found only Claude exceeded professional-writer rates while ChatGPT used fewer. Ban it because it is house style, not because it proves anything.

---

## Part 5: What this guard does NOT ask for

Overcorrection produces its own kind of bad writing. These are explicit non-rules.

- **No AI-detector gate.** Never run a draft, or anyone's writing, through an AI-text detector and treat the score as a verdict. Seven widely used detectors produced a 61.22% average false-positive rate on human-written TOEFL essays, and 97.80% of those essays were flagged by at least one. The bias falls hardest on non-native English writers. Worse for our purpose: simplifying native US 8th-grade essays raised the false-positive rate from 5.19% to 56.65%, so plain language itself scores as AI. What detectors measure is low perplexity, not authorship. The acceptance test is whether a colleague can restate the message or act on it, not a score.
- **No readability-grade target.** Calibrate to the audience's knowledge. Writing down to an engineering audience reads worse.
- **No jargon purge.** Domain terms are the shortest accurate way to say the thing to people who share the domain. Expand an uncommon acronym once on first use in a cross-team or upward message.
- **No blanket ban on lists or structure.** Scannable formatting reduces follow-up questions. The tell is the mechanical triad, not the bullet.
- **No manufactured personality.** Do not add rhetorical questions, forced humor, or performative uncertainty to sound human. Specificity is what reads as human; decoration is not.
- **Do not treat readable as human-sounding.** Readers judge AI text as *more* readable than human text - human text won only ~30% of paired comparisons - while simultaneously believing the more readable text of a pair is the human one. Polishing for smoothness does not remove the AI signature; the two targets are separate.
- **Do not treat a clean word-list pass as proof.** The word list catches a lower bound. The signature lives largely in high-frequency function words and sentence rhythm, which no vocabulary swap removes. That is why Part 1 and Part 2 come before Part 3.
- **Do not claim a draft is or is not AI-written.** Untrained readers score 55.4% on a side-by-side pair, 65.1% after feedback training. Nothing in this doc is evidence of authorship.

---

## Part 6: Pre-send self-check

No single marker is decisive. Co-occurrence is what a reader registers.

- [ ] Opening sentence carries the point, not context or a greeting
- [ ] Every claim that needs a name, number, date, or link has one
- [ ] At least one short sentence, and sentence lengths visibly vary
- [ ] No trailing `-ing` clause doing the work of a sentence
- [ ] No Tier 1 or Tier 2 word (Part 3)
- [ ] No fixed opener or closer, no antithesis frame, no mechanical triad
- [ ] No hedging preamble in front of a verified claim
- [ ] Same term for the same concept throughout
- [ ] Ask, owner, and next step each stated once and unambiguously
- [ ] Surface contract from `voice-profile-routing.md` satisfied

**Threshold:** 0-1 unchecked is fine. 2 means read it again. 3 or more means rewrite rather than patch - patched model prose reads worse than a rewrite, because the edits land on vocabulary while the shape stays intact.

---

## Part 7: The mechanical pass

```bash
python3 .claude/scripts/prose-lint.py --surface slack-channel --file draft.md
python3 .claude/scripts/prose-lint.py --surface github-review-comment --file comment.md --format json
python3 .claude/scripts/prose-lint.py --list-rules
```

Two classes of finding:

- **gate** - a mechanical defect with a concrete failure and near-zero false-positive rate. An embed link renders wrong; a trailing bare URL swallows the next line; a literal bullet character never becomes a list. Gates fail the run. A rule earns this only when the text alone proves the defect: a courtesy opener is right for a human reviewer and wrong for a bot, and whether a comment is attached to a hunk lives in the API payload, so neither can be decided from the body and neither blocks.
- **marker** - register, vocabulary, template, and rhythm signals, counted by tier and judged against a threshold (default 5). Never decisive individually.

Fenced blocks, inline code, and URLs are masked before matching. Quoted prose from someone else is not, so read the hits before acting.

Two enforcement points call the script automatically:

- `.claude/hooks/prose-lint-guard.sh` on `slack_send_message_draft`. Escape hatch `NASE_PROSE_LINT=0`, for when the flagged text is a quote from someone else.
- `.claude/scripts/external-write-action.py` on payload files, gate findings only. It covers both `gh pr create|edit|comment|review` and `gh api` calls against a `/pulls/` or `/issues/` endpoint, which is how a review with inline comments is actually submitted. For a JSON payload it lints each `body` value rather than the serialized envelope.

Both fail open when the linter is missing or crashes. A broken quality check must not block a write.

---

## Part 8: Interaction with the style profile

This guard defines the floor. `workspace/communication-style.md` defines the voice on top of it. Where they conflict, the style profile wins: a documented personal habit is not a marker to strip.

When the user corrects a draft in a way that implies a reusable rule, follow `.claude/docs/style-delta-capture.md`. Rules about the configured engineer's voice go to `workspace/communication-style.md`; generic readability rules belong here.

---

## Evidence

`verified` means the claim survived a three-vote adversarial check against the primary source. `extracted` means it was quoted directly from the primary document but never attacked. `manual` means it was fetched and confirmed verbatim during the 2026-08-28 research run after the automated verifier misfired.

| Source | Status | Used for |
|---|---|---|
| Kobak, Gonzalez-Marquez, Horvat & Lause, *Delving into LLM-assisted writing in biomedical publications through excess vocabulary*, Science Advances 11:eadt3813, 2025 | verified | Excess vocabulary is style words (66% verbs, 14% adjectives); 13.5% lower bound on 2024 abstracts; the method's own evadability caveat |
| Reinhart et al., *Do LLMs write like humans?*, PNAS 122:e2422455122, 2025 | verified | Participial clauses ~5.3x (d=1.38), nominalization ~2.1x (d=1.23), that-subject ~2.6x, phrasal coordination ~1.9x; agentless passive at ~0.5x; instruction tuning as the cause; informal-register prompts do not remove it |
| Liang, Yuksekgonul, Mao, Wu & Zou, *GPT detectors are biased against non-native English writers*, Patterns, 2023 | verified | 61.22% detector false-positive rate; 5.19% to 56.65% when plain language is applied; perplexity as the operative signal |
| arXiv:2505.01877, human identification of LLM text (n=254) | verified | 55.4% untrained / 65.1% trained accuracy; specificity as the only cue surviving training (p=0.044); AI text judged more readable |
| AI code-review effectiveness study (16 tools, 178 repos, 22,000+ comments) | extracted | Hunk vs file anchoring (51.9% vs 87.0% unaddressed); comment length rho=-0.24; code ratio rho=+0.89; human 60% vs AI 0.9-19.2% |
| Microsoft Writing Style Guide, *Scannable content* and *Top 10 tips* | manual | Three to seven line paragraphs; get to the point then stop; front-load keywords per structural unit; verb-first statements; contractions; unspaced em dash as house style |
| Google engineering practices, *Code Review Comments* | manual | Comment on the code never the developer; author owns the fix. Its severity-prefix recommendation is quoted accurately and deliberately not adopted, see below |
| Google developer documentation style guide, *Voice and tone* | extracted | Active voice with a named actor, and its three sanctioned passive exceptions; conditions before instructions; list semantics by type |
| Conventional Comments | manual | Severity declared by an enumerated token rather than by softened prose (format itself not adopted here) |
| Wikipedia:Signs of AI writing / WikiProject AI Cleanup | extracted | Words-to-watch list; antithesis frame; formatting tells; detector output rejected as grounds for action; tell lists decay as models change |
| Federal Plain Language Guidelines | extracted, source moved | Write for your audience first; hidden verbs; same-term consistency; reader-based testing over readability formulas |

**Claims deliberately not used.** Recorded so they are not reintroduced.

- **Google's `Nit:` / `Optional:` / `FYI:` severity prefixes.** Quoted correctly from the source, adopted here at first, and wrong for this workspace: `.claude/docs/discuss-pr-output.md` and `workspace/communication-style.md` had already ruled the prefix out with a dated rationale, and because `voice-profile-routing.md` runs this guard as the final pass, the imported rule would have won every time. The general failure is worth more than the specific fix: an external style guide is evidence about its own house, so grep for a local rule on the same behaviour before importing one. The same mistake shipped the inverted Slack bullet gate.
- **"Passive voice is an LLM tell."** The opposite is measured: models use agentless passive at about half the human rate. Active voice stays in Part 1 as a readability rule only.
- **Google's alleged "second person over first-person plural" rule.** Flagged by two independent extraction runs, refuted by both verification passes, never confirmed by hand. Not a rule here.
- **GitLab's 15-word sentence ceiling and the 150/250-word paragraph limits from plainlanguage.gov.** Both source pages are gone: the GitLab handbook page was deleted 2025-12-01 and plainlanguage.gov/guidelines now redirects. Re-confirm from an archive before adopting either.
- **Per-word frequency ratios as a ranked ban list.** The ratios are real; ranking a ban list by them is an inference the papers do not support.
- **Burstiness thresholds (`sd/mean` of 0.6-1.2 human vs 0.2-0.4 model) and the 82% single-cadence claim.** Practitioner blog numbers with no published method. Part 2 uses the short-sentence rule instead.
- **The "negative instructions above 40% of a prompt degrade the model" threshold.** A self-deposited preprint comparing three versions of one instruction set, with no sample size, trial count, or statistical method disclosed. The 3:1 positive-to-negative ratio is followed here anyway, because every rule above carries a rewrite target at no cost.
