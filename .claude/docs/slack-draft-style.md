---
name: slack-draft-style
description: Style rules for Slack messages drafted on behalf of the EM. Read before finalizing any Slack DM or channel message draft.
---

Before finalizing any Slack draft, follow `.claude/docs/voice-profile-routing.md` with `surface=slack-dm` or `surface=slack-channel`. Read `workspace/communication-style.md` when the routing capsule says the full profile is needed or the message is high-stakes.

After the user corrects a draft, follow `.claude/docs/style-delta-capture.md`. Log a `[STYLE-DELTA]` line when the correction implies a generalizable rule; `/nase:wrap-up` Step 4e batches pending deltas into approved style-doc edits.

## Quick Checklist

Apply before presenting the draft to the user:

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
