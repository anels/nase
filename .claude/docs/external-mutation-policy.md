# External Mutation Policy — Shared Reference

Canonical rule for skills that change state in systems outside the local workspace (Slack, Jira, Confluence, GitHub, ADO, cloud resources).

---

## The rule

**No external mutation without an explicit, draft-first or `AskUserQuestion`-gated user confirmation in the same turn.** "External mutation" = anything other people can see, anything that pages someone, anything that costs money, anything that's hard to undo.

| System | Hard rule |
|--------|-----------|
| **Slack** | NEVER call `slack_send_message` directly. ALWAYS use `slack_send_message_draft` so the user reviews + sends. No exceptions. |
| **Jira** | Drafting comments, creating issues, transitioning status — all require `AskUserQuestion` before the call. "Open" / "In Progress" transitions are mutations too — they notify watchers and may auto-assign. |
| **Confluence** | Page create / update — draft to `workspace/tmp/{name}.md` first, prompt user, only then call `createConfluencePage` / `updateConfluencePage`. Never publish silently. |
| **GitHub PR** | Opening a PR, merging, editing description, adding labels, requesting reviewers, posting review comments — `AskUserQuestion` before. Default to **draft PR** when creating. Inline review comments stay AI-clean (no `Co-Authored-By` lines). |
| **ADO pipeline** | Triggering a build = action-taking. `AskUserQuestion` before the trigger with the computed `templateParameters` shown. Use `az` CLI (`az pipelines`, `az rest` — never `curl` with `$ADO_PAT`; see `feedback_ado-az-cli-only.md`). |
| **Cloud resources** | `az`, `kubectl`, `terraform apply`, `snow` — anything that mutates infrastructure requires explicit user confirmation. Read-only queries (`get`, `list`, `show`, `describe`) are fine. |
| **git push** | Push to feature branch is OK after the standard commit sequence. Push to `main` / `master` / `develop` / `release/*` is BLOCKED by `block-dangerous-git.sh` hook — do not bypass. Force-push: only with `--force-with-lease` and only when the user has been warned. |

---

## Hook backstops

Prompt rules are not enough for irreversible writes. These hooks enforce the
highest-risk rules even when a future skill forgets the prompt contract:

| Hook | Blocks |
|------|--------|
| `slack-send-guard.sh` | direct `slack_send_message`; use `slack_send_message_draft` |
| `jira-write-guard.sh` | Jira mutation tools without a fresh `workspace/.jira-write-token`; Jira body writes with missing `contentFormat`, or ADF bodies outside an approved batch token (see `.claude/docs/jira-write-pattern.md`) |
| `confluence-size-guard.sh` | Confluence page bodies over 60 KB; page writes not sent as `contentFormat: "adf"` (see `.claude/docs/confluence-adf-pattern.md`) |
| `block-dangerous-git.sh` | destructive or protected-branch git commands |

### Jira token contract

Every Jira mutation needs a fresh JSON token written immediately before the
tool call, after the payload-showing `AskUserQuestion` approval. For a
single-shot mutation, bind the exact payload:

```json
{
  "tool_name": "{actual transitionJiraIssue tool name}",
  "issue_key": "PROJ-123",
  "issue_keys": ["PROJ-123"],
  "created_at": "2026-05-25T19:00:00Z",
  "payload_summary": "PROJ-123 -> Done",
  "payload_sha256": "{sha256 of canonical tool_input}"
}
```

The hook verifies the tool name, freshness, issue-key parity, and
`payload_sha256`, then consumes the token. Compute `payload_sha256` from the
exact Jira MCP `tool_input` that will be sent:

```bash
PAYLOAD_SHA=$(jq -cS '.tool_input // {}' "$JIRA_TOOL_CALL_JSON" | shasum -a 256 | awk '{print $1}')
```

`createJiraIssue` may omit issue keys because the issue does not exist yet;
link/comment/transition/edit calls must identify their target keys. `tool_name`
must exactly match the current MCP tool name; the namespace prefix may differ
by MCP server, so do not blindly copy the example value.
If the guard cannot parse the hook JSON or its required `jq` dependency is
missing, it blocks the mutation instead of guessing.

#### Batch token (approved multi-ticket runs)

When one `AskUserQuestion` approves a batch of mutations across several tickets
(e.g. cancel N incidents, each needing a transition + a comment), a single-shot
token per call is wasteful — every call re-derives a payload sha. Write one
**batch token** instead, after the approval that showed the per-ticket plan:

```json
{
  "approved_issues": ["SRE-1", "SRE-2"],
  "max_ops": 6,
  "created_at": "2026-06-12T15:40:00Z",
  "payload_summary": "cancel approved incidents",
  "tools": ["transitionJiraIssue", "addCommentToJiraIssue"],
  "ttl_seconds": 900
}
```

The hook authorizes any gated Jira mutation whose target issue is in
`approved_issues`, up to `max_ops` calls, within the TTL (default **900s**;
`ttl_seconds` overrides). It decrements `max_ops` on each allowed call and
deletes the token when the budget is exhausted or the TTL passes. `tools` is an
optional allowlist (exact or suffix match, to tolerate MCP namespace prefixes);
omit it to allow all gated Jira tools. A non-empty `approved_issues` array is
what selects batch mode.

Batch mode trades the exact-payload sha binding for an **issue allowlist + op
cap + TTL**: a runaway loop still cannot touch a ticket outside the approved set
or exceed the approved op budget. Use it only for the concrete batch the user
just approved; for a single irreversible mutation, prefer the single-shot token.
A failed validation (unapproved issue, disallowed tool, stale TTL) deletes the
token, forcing re-approval. `createJiraIssue` (no target key) still requires a
single-shot token.

Size the op budget to cover the planned calls (e.g. 4 tickets × [transition +
comment + close transition] = 12). The token authorizes mutation *count*, not
exact text — show the per-ticket disposition in the `AskUserQuestion` so the
user approves the substance, not just a number.

---

## What this policy is NOT

- Not a license to ask permission for every read (`gh pr view`, `az pipelines runs show`, MCP `getJiraIssue` — all fine, run them directly).
- Not a substitute for verifying side effects. After a mutation, confirm the change landed (e.g., re-fetch the Jira issue, re-check Slack draft was created, parse `gh pr create` response for URL).
- Not a substitute for the `slack_send_message_draft` rule — that is stricter and absolute. Slack never gets a direct send.

---

## Application checklist for new skills

When authoring or reviewing a skill that touches an external system, ask:

1. Does it mutate? (write, create, transition, trigger, publish, push)
2. If yes: is there a draft-first path? (Slack draft, Confluence draft page, draft PR, `workspace/tmp/{name}.md`)
3. If draft-first isn't available: is there an explicit `AskUserQuestion` gate immediately before the mutation call? (not a generic "should we proceed?" earlier in the flow — the gate must be the last step before the side-effect)
4. Does the gate show the user the *concrete payload* (Jira transition, Confluence page diff, ADO templateParameters, PR title+body)?

If any answer is no, the skill is non-compliant — fix before merging.

---

## GitHub auth account guard

Workspaces that ship multi-account `gh` setups (e.g. personal + work accounts) hit an intermittent failure where `gh auth switch --user <work>` does not persist across long gaps, MCP calls, or other non-`gh` tool calls. The first failure presents as `GraphQL: Could not resolve to a Repository with the name '{ProtectedOrg}/{Repo}'` — misleading, since the repo exists.

Before any `gh` mutation against the protected org, ensure the active account matches the configured expected account from `workspace/config.md → gh_account:`. If the field is absent, the snippet is a no-op (no account switch ever runs with an empty arg).

```bash
EXPECTED_GH=$(awk -F': ' '/^gh_account:/{print $2}' workspace/config.md 2>/dev/null || true)
if [ -n "$EXPECTED_GH" ] && ! gh auth status --active 2>&1 | grep -q "Active account: $EXPECTED_GH"; then
  gh auth switch --user "$EXPECTED_GH"
fi
```

Run this snippet immediately before each `gh` mutation block (PR edit, comment reply, thread resolve, reviewer assign, PR create, `pr ready`). Skip cleanly when `gh_account:` is unset.

Skills that should reference this guard: `address-comments`, `prep-merge`, `request-review`, `fsd`. Read-only `gh` calls (`gh pr view`, `gh pr diff`, `gh api .../comments` GET) do not need the guard — only mutations.

## Related memories

- `feedback_no-address-comments-others-pr.md` — never mutate someone else's PR without permission
- `feedback_ado-az-cli-only.md` — never `curl` with `$ADO_PAT` (use `az` CLI; same auth boundary as user)
- `feedback_gh-auth-active-account-flips.md` — the multi-account `gh auth switch` non-durability that motivates the guard above

## Reference from skills

Add a one-line pointer near the top of any mutation-capable skill:
> Follows `.claude/docs/external-mutation-policy.md` — every external write goes through draft-first or `AskUserQuestion`.

Do not re-document the rules per skill. Update the doc here when the policy evolves.
