# Discuss PR - Submit Mechanics

Loaded from `.claude/docs/discuss-pr-output.md` Step 8. Read it **before** the gate: the payload and its manifest have to exist before the question shows them. The state rules, body rules, and inline-comment contract stay in that file; this one holds the write mechanics.

## Build the review payload and execute

One `external-write-action.py` manifest covers the whole review: a GitHub review with inline comments and a state is a single POST. Everything above the marker runs **before** the gate; after the answer, only `authorize` and `execute`.

```bash
# Private 0700 payload dir - see external-mutation-policy.md -> Private payload directory.
REVIEW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pr-review-{number}-XXXXXXXX")
REVIEW_FILE="$REVIEW_DIR/review.json"
trap 'rm -rf "$REVIEW_DIR"' EXIT
# Build with jq from the confirmed state, body, and drafted inline comments:
#   {"event":"APPROVE|COMMENT|REQUEST_CHANGES","body":"...","comments":[{"path":"...","line":N,"side":"RIGHT","body":"..."}]}
jq -n --arg event "$STATE" --arg body "$REVIEW_BODY" --argjson comments "$INLINE_COMMENTS_JSON" \
  '{event:$event, body:$body, comments:$comments}' > "$REVIEW_FILE"
MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
  --system github --summary "submit {STATE} review on {owner}/{repo}#{number}" -- \
  gh api "repos/{owner}/{repo}/pulls/{number}/reviews" --method POST --input "$REVIEW_FILE" | jq -r .manifest)
jq . "$MANIFEST"
# --- show the jq output, $REVIEW_BODY, and the inline-comment count in the gate
# --- question. After the answer approves this manifest:
python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
```

On a deviation from the recommended state, rebuild with that `event`, show the new manifest and body, and take one fresh confirmation - never execute a manifest the user did not see. On "Keep in chat" or "Discard", do not authorize; the prepared manifest is abandoned unspent.

## Reactions, replies, and resolves

After the review submits, post any Step 3 batched reactions/replies the user agreed to. Each reaction/reply/resolve is its own manifest with its own one-shot token.

- Replies: `.claude/docs/github-queries.md -> Reply To A Review Thread` - jq-built `--input` payload, integer `databaseId`, mandatory read-back check.
- Resolves: `.claude/docs/github-queries.md -> Resolve Review Threads`.
- Reactions: `gh api "repos/{owner}/{repo}/pulls/comments/{comment_id}/reactions" --method POST --raw-field content="+1"`, wrapped in the same manifest gate.

Honor the 30-mutation throttle rule in `.claude/docs/github-queries.md`.
