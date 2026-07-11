# PR Next-Step Handoff

Load this only when a PR workflow reaches a user choice about what should happen next.

## Address-Comments Handoff

Skip the handoff if every thread was declined, because reviewer conversations remain open. Otherwise prompt:

```
question: "What should I do next for this PR? {pr_url}"
header: "Next Step"
options:
  - label: "Prep merge"
    description: "Invoke /nase:prep-merge {pr_url} to squash/finalize the PR"
  - label: "Request review"
    description: "Invoke /nase:request-review {pr_url} to find reviewers and stage Slack DM drafts"
  - label: "Stop here"
    description: "Do nothing else; leave follow-up for later"
```

Do not auto-run prep-merge or request-review. The former can rewrite history and the latter stages human pings. Invoke only the option the user selected; stop on "Stop here".
