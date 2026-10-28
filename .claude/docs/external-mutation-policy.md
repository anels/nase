# External Mutation Policy - Shared Reference

## Contents

- The rule
- Autonomy level
- Gate contract
- Private payload directory
- `execute` exit codes
- What this policy is NOT
- Application checklist for new skills
- GitHub auth account guard
- Deeper recipes

Canonical rule for skills that change state in systems outside the local workspace (Slack, Jira, Confluence, GitHub, ADO, cloud resources).

---

## The rule

**No external mutation without an explicit, draft-first, autonomy-pre-authorized, or `AskUserQuestion`-gated user confirmation in the same turn.** "External mutation" = anything other people can see, anything that pages someone, anything that costs money, or anything hard to undo.

| System | Hard rule |
|--------|-----------|
| **Slack** | NEVER call `slack_send_message` or `slack_schedule_message` directly. ALWAYS use `slack_send_message_draft` so the user reviews + sends. No exceptions. A canvas is a write too: `slack_create_canvas` and `slack_update_canvas` publish with no draft path, so `slack-send-guard.sh` blocks both. Put the canvas body in `workspace/tmp/{name}.md`, get explicit approval, and have the user create it. |
| **Jira** | Comments, issue creation, and status transitions are mutations - they notify watchers and may auto-assign. Gate each one, except a transition whose class the autonomy level pre-authorizes (below). |
| **Confluence** | Page create / update: draft to `workspace/tmp/{name}.md` first, get explicit approval, only then call the tool. Never publish silently. Tool names differ by MCP generation; the current and older names are listed in `.claude/docs/mutation-reference.md → Confluence tool names`. Attachment upload has no MCP tool: `confluence-publish.py attach` posts PNG bytes to any page with the stored Atlassian token, so it runs only through `external-write-action.py --system confluence` (see Gate contract). |
| **Atlassian generic runner** | NEVER call `executeWrite` or `executeDestructive`. They run any `discover` operation under an opaque `{name, cloudId, inputs}` payload, so no payload-bound gate can read them; `atlassian-generic-write-guard.sh` blocks both. One exception: `executeWrite` with `name: "createConfluenceComment"`, gated on its own payload by that hook. The draft-first rule still applies: write the comment under `workspace/tmp/` and get the user's go-ahead. `discover` and `executeRead` are read-only and fine. |
| **GitHub PR** | Opening a PR, merging, editing a description, adding labels, requesting reviewers, posting review comments - gate each, unless the autonomy level pre-authorizes the class. Default to **draft PR** when creating. Inline review comments stay AI-clean (no `Co-Authored-By` lines). |
| **ADO pipeline** | Triggering a build is action-taking: gate it with the computed `templateParameters` shown. Use `az` CLI (`az pipelines`, `az rest` - never `curl` with `$ADO_PAT`). |
| **Cloud resources** | `az`, `kubectl`, `terraform apply`, `snow` - any infrastructure mutation requires explicit confirmation at every autonomy level. Read-only queries (`get`, `list`, `show`, `describe`) are fine. |
| **git push** | Push to a feature branch is OK after the standard commit sequence. Push to `main` / `master` / `develop` / `release/*` is BLOCKED by `block-dangerous-git.sh` - do not bypass. Force-push only with `--force-with-lease` after warning the user. |

## Autonomy level

`workspace/config.md → ## Autonomy` carries `level: guided | standard | auto`. Missing section or key means `guided`, so an unconfigured workspace behaves exactly as before. Ask the policy script, never re-implement the table:

```bash
python3 .claude/scripts/autonomy-policy.py --class jira-transition-progress
# {"level": "standard", "class": "...", "decision": "auto", "reason": "..."}
```

`decision` is `auto`, `ask`, or `never`. `never` means the class cannot be pre-authorized at any level and must stop for a human.

| Class | guided | standard | auto |
|---|---|---|---|
| `workspace-append` (daily log, journal, JSONL) | ask | auto | auto |
| `slack-draft` (create/update a draft, never send) | ask | auto | auto |
| `jira-transition-progress` (to In Progress only) | ask | auto | auto |
| `jira-comment-approved` (body already approved once this run) | ask | auto | auto |
| `pr-mark-ready` | ask | auto | auto |
| `worktree-cleanup` | ask | auto | auto |
| `workspace-durable-write` (KB, tasks, efforts, journals) | ask | ask | auto |
| `pr-create-draft`, `pr-label`, `pr-request-review` | ask | ask | auto |
| `jira-transition-other` (any status except Done / Canceled) | ask | ask | auto |
| `slack-send`, `merge`, `force-push`, `confluence-publish`, `review-other-pr`, `cloud-resource`, `ado-trigger` | never | never | never |

Rules that apply at every level:

- `auto` removes the human stop, never the payload binding. The manifest, one-shot token, drift checks, hooks, and prose gates all still run, and the caller appends an audit entry to the daily log in the canonical shape `- {HH:MM} | autonomy: {class} {target} {manifest}`. Write it through `python3 .claude/scripts/daily-log-append.py autonomy "{class} {target} {manifest}"` - a hand-written line under `## Sessions` in any other shape fails the daily-log format check.
- A class the table does not name, or a `--class` the script rejects, is `ask`. Unknown never means auto.
- The level is a floor for *asking*, not a grant of permission: a repo rule, a protected branch, an external mutation policy row, or an explicit user instruction that is stricter still wins.
- When a mutation fails, the failure path is unchanged - report it, do not retry blind.

## Gate contract

GitHub CLI, ADO, Azure, Kubernetes, Terraform, and Confluence attachment-upload (`confluence-publish.py attach`, `--system confluence`) mutations use `.claude/scripts/external-write-action.py`, never a raw mutating shell command. Prepare the exact argv and payload files, show the emitted manifest plus payload content, then authorize and execute:

```bash
MANIFEST=$(python3 .claude/scripts/external-write-action.py prepare \
  --system github --summary "create draft PR" -- \
  gh pr create --draft --title "{title}" --body-file "{body_file}" \
  | jq -r .manifest)

# Show the manifest and exact payload content before asking.
cat "$body_file"
jq . "$MANIFEST"
python3 .claude/scripts/external-write-action.py authorize --manifest "$MANIFEST"
python3 .claude/scripts/external-write-action.py execute --manifest "$MANIFEST"
```

Show the exact argv, target, side effects, payload content (or its structured fields), and each payload SHA - a path and hash alone are not an adequate payload review.

`prepare` hashes every file the CLI will read, not only the files behind a known flag: the flag tables (`--body-file`, `-F`, `--in-file`, `--patch-file`, `-fFILE`, `key=@file`, ...) name the ones that must exist, and any other argv word that names an existing regular file is bound too, so a file-valued flag added later cannot slip past unhashed. The prose gate reads every bound file. A payload path may not be a symlink or sit under a user-owned symlinked directory, and `execute` re-resolves each path as written and refuses a file that now resolves elsewhere. For `confluence attach`, the plan's body file and every pending PNG are bound as well. Do not put credentials in argv or payload files. For an `auto` class, show nothing and execute immediately, then write the audit line.

### Private payload directory

A mutation whose payload is a file writes it to a fresh 0700 directory, never to a
shared path. The 0700 directory is what makes the payload private; `chmod` on a file
in a shared `/tmp` is not. Callers differ only in the prefix and the file name:

```bash
# The X's must come LAST. BSD/macOS does not expand a template with a suffix after
# them, so "foo.XXXXXXXX.md" yields that literal - and shared - name.
PAYLOAD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/{prefix}-XXXXXXXX")
trap 'rm -rf "$PAYLOAD_DIR"' EXIT
```

Skills reference this block; they do not restate the `mktemp` rule.

### `execute` exit codes

Read the exit code before reporting an outcome. Only `0` means the write landed.

| Code | Meaning | What to do |
|---|---|---|
| `0` | The CLI succeeded. | Report the write as done. |
| non-zero from the CLI | The CLI ran and failed; its own exit code passes through. | Report the failure with the CLI's stderr. Nothing landed unless the CLI says otherwise. |
| `2` | The helper refused: stale or missing token, manifest drift, payload drift, changed owner/account mapping, or a preflight `gh` call that timed out. Nothing was executed. | Fix what it names, then prepare and approve again. |
| `11` | The CLI exceeded `--timeout-seconds` (default 900) and was killed. **The outcome is unknown** - it may have applied the mutation first. | Read the target state before deciding anything. Never report this as either success or failure, and never retry blind: the one-shot token is spent, so a retry needs a fresh preview and approval. |

`11` is not a reserved range, so a CLI that natively exits `11` is indistinguishable by
code alone. The helper prints a `TIMEOUT:` line to stderr when it is the one that gave
up - read that, not the number, when it matters.

## What this policy is NOT

- Not a license to ask permission for every read (`gh pr view`, `az pipelines runs show`, MCP `getJiraIssue` - all fine, run them directly).
- Not a substitute for verifying side effects. After a mutation, confirm the change landed (e.g., re-fetch the Jira issue, re-check the Slack draft was created, parse `gh pr create` for the URL).
- Not a substitute for the `slack_send_message_draft` rule - that is stricter and absolute. Slack never gets a direct send.
- Not a reason to re-document the rules per skill. Update this doc when the policy evolves.

## Application checklist for new skills

When authoring or reviewing a skill that touches an external system, ask:

1. Does it mutate? (write, create, transition, trigger, publish, push)
2. If yes: is there a draft-first path? (Slack draft, Confluence draft page, draft PR, `workspace/tmp/{name}.md`)
3. If draft-first isn't available: is there an explicit `AskUserQuestion` gate immediately before the mutation call? (not a generic "should we proceed?" earlier in the flow - the gate must be the last step before the side-effect)
4. Does the gate show the user the *concrete payload* (Jira transition, Confluence page diff, ADO templateParameters, PR title+body)?
5. If the class is autonomy-pre-authorized, does the call still bind a manifest and append the audit line?

If any answer is no, the skill is non-compliant - fix before merging.

## GitHub auth account guard

Every GitHub mutation runs through `.claude/scripts/external-write-action.py`. `prepare` binds the owner-to-account mapping into the hashed action; `execute` re-reads the mapping, loads that account's `gh` token, verifies the token actor, and passes `GH_TOKEN` only to the mutation subprocess. It never changes shared `gh` account state. A missing, changed, unreadable, unmapped, unselectable, or actor-mismatched account blocks the write and consumes the one-shot token. Raw `gh auth token`, `login`, `logout`, `refresh`, and `switch` are blocked; only `gh auth status` without `-t`/`--show-token` may run outside the helper.

Skills reference the helper; they do not copy token-selection snippets. The full owner-derivation and credential handling rules are in `.claude/docs/mutation-reference.md → GitHub auth account guard`. Skills that should reference it: `address-comments`, `prep-merge`, `request-review`, `fsd`. Read-only `gh` calls (`gh pr view`, `gh pr diff`, `gh api .../comments` GET) do not need the guard - only mutations.

## Deeper recipes

Load `.claude/docs/mutation-reference.md` only when the current step needs one of: the manifest/token internals, the Jira single-shot or batch token contract, the hook backstop table, how the CLI guard parses an unrecognized command, the Confluence tool-name matrix, the full GitHub account rules, or the related memory list.

## Reference from skills

Add a one-line pointer near the top of any mutation-capable skill:
> Follows `.claude/docs/external-mutation-policy.md` - every external write goes through draft-first, autonomy pre-authorization, or `AskUserQuestion`.

Do not re-document the rules per skill.
