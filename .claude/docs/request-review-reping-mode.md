# request-review: re-review-ping mode

Branch-specific procedure for `/nase:request-review --mode re-review-ping`. The entrypoint
`.claude/commands/nase/request-review.md` routes here; every other mode ignores this file.

## When this mode runs

`/nase:address-comments` Phase 9b hands off here with the handles already filtered (bots, PR
author, declined) and already chosen.

## Which steps run

Run Steps 0, 1, 4, 7, 8 (Question 2 only), and 9. Skip 2, 3, 5, 6, and Step 8's Question 1 -
it re-asks what the caller answered, and its confirmed list is the caller's handles. Question 2
still runs, because preview-and-stage is the only gate before a draft is written. Still apply
Step 3c's alumni exclusion.

## What the skipped steps carried

Load each of these directly, because the step that normally loads it does not run:

- the repo KB via `.claude/docs/repo-resolution.md` (Step 3's preamble - alumni exclusion and
  handle mappings both need it)
- `.claude/docs/slack-draft-style.md` and `.claude/docs/voice-profile-routing.md` with
  `surface=slack-dm` (Step 6)
- Step 4's second name source, `gh api users/{login} --jq .name`

Handle-guessing is the last resort.

## Opener and report shape

Step 7's ask becomes a re-review opener - `Pushed fixes for your comments on the PR - ready for
another look when you get a minute.`, or `Responded to ...` when `no_commit=true`.

Report each as `Slack DM draft staged for @{login} (Slack: {slack_handle}) - review + send
manually.`
