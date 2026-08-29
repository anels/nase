---
name: slack-draft-style
description: Style rules for Slack messages drafted on behalf of the EM. Read before finalizing any Slack DM or channel message draft.
---

Before finalizing any Slack draft, follow `.claude/docs/voice-profile-routing.md` with `surface=slack-dm` or `surface=slack-channel`. Read `workspace/communication-style.md` when the routing capsule says the full profile is needed or the message is high-stakes. (Arriving here *from* that routing table? You are in the right place - read Formatting Mechanics and the Quick Checklist below and do not bounce back.)

After the user corrects a draft, follow `.claude/docs/style-delta-capture.md`. Log a `[STYLE-DELTA]` line when the correction implies a generalizable rule; `/nase:wrap-up` Step 4e batches pending deltas into approved style-doc edits.

`.claude/hooks/prose-lint-guard.sh` enforces three Formatting Mechanics rules below (`- item` bullets, no `<url|label>` embed, no bare URL ending a line whose next line is non-empty) on every `slack_send_message_draft` call. **This doc stays their source of truth**: if `prose-lint.py` and Formatting Mechanics ever disagree, fix the linter.

## Formatting Mechanics

The rest of this doc governs what to say. This section governs what survives
`slack_send_message_draft`, which is a separate failure mode: a message with the right voice
still reads as broken when the tool mangles its structure, and the user is the one who has to
repair it in the composer before sending.

The MCP accepts Markdown-style text. Its installed Slack plugin documents `- item` as the
bulleted-list syntax, while Slack's own `mrkdwn` has no dedicated list syntax and instead
uses regular text plus line breaks. The runtime may convert the Markdown before Slack renders
it.

- **Write `- item` for bullets, never a literal `•`.** A literal `•` is plain text; the
  Markdown-converting draft path uses `- item` to produce a list.
- **Never end a line with a bare URL when the next line is non-empty.** The auto-linker eats the
  URL, the newline, and the start of the next line as one span - whatever follows, not only
  bullets. A bullet next renders `<https://…\n•>`; prose next renders `<https://…\nChild>` with
  the closing `>` stranded mid-sentence. Put content after the URL on the same line, which means
  writing a link list as sentences rather than `Label: {url}` rows:
  `Parent https://example.com/a covers sections 0-3` / `Merged in https://example.com/b - fixed.`
  A blank line after the URL is also a valid boundary and survives, but only outside a bullet
  block - see the next rule.
- **Do not rely on a blank line after a bullet block for separation.** A blank line immediately
  after a bullet block is dropped by the current draft conversion, so the next section runs into
  the list. Separate sections with a non-empty text line instead.
- **Keep bare URLs.** The workspace style rejects destination-hiding labels; Slack also
  auto-links direct URLs.

Verifying a draft is only possible through the user: there is no list-drafts or read-draft tool,
and per `.claude/docs/external-mutation-policy.md` sending a test message is not an option. So
treat these as the rules that make a first attempt correct, and when structure matters, say
explicitly what the draft should look like so the user can spot a mismatch at a glance.

## Quick Checklist

Apply before presenting the draft to the user:

- [ ] Bullets are `- item`, not a literal `•` (see Formatting Mechanics - a literal `•` never indents)
- [ ] No line ends with a bare URL while the next line is non-empty (bullet *or* prose) - put content after the URL on the same line
- [ ] No opening greeting ("Hi", "Hello", "Hope you're well") — jump straight to content
- [ ] No AI filler words ("certainly", "absolutely", "I'd be happy to", "I wanted to reach out") — delete
- [ ] Technical content: use bullets, not prose paragraphs
- [ ] Can the message be cut by 30%? If yes, cut it
- [ ] DM to non-Chinese-native colleagues: 100% English
- [ ] DM to Chinese-native colleagues (e.g., Haowen): Chinese is OK
- [ ] Public channels: always English, never Chinese
- [ ] Use `pls` not `please` in informal DMs; `can you` not `please` in requests
- [ ] PR review request format: `[link] @reviewer1 @reviewer2 pls help review / pls take a look` or `Could you help review [link] - [TLDR]`
- [ ] No redundant `this?` after a PR URL in review requests
- [ ] Reassignment / change notifications: cc all affected people, add "let me know if anything breaks"
- [ ] Personnel change messages: include a specific memory or detail — no generic templates
- [ ] Incident update format: symptom → cause → current status → action request; cc TL/PM

## Key Rules

- Lead with the information, not pleasantries
- Short is correct for technical DMs ("let me see" / "done" / "merged" are complete messages)
- For people events (onboarding, offboarding, anniversaries): add warmth and specific details
- For technical/process updates: concise bullets, root cause first, no band-aid
- `cc:` or `@mention` everyone who may be affected — transparency is the default
