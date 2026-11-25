# External Mutation Reference

## Contents

- Manifest binding internals
- Confluence tool names
- Hook backstops
- What the CLI guard does with a command it cannot parse
- Jira token contract
- GitHub auth account guard
- Related memories

Loaded on demand from `.claude/docs/external-mutation-policy.md`. The policy's rule,
autonomy table, gate contract, payload-directory snippet, and exit codes stay in that
file; this one holds the recipes a step reads only when it hits them.

## Manifest binding internals

The helper stores a local manifest and a one-shot 300-second token. It hashes the argv
and payload-file contents, rechecks both before execution, invokes the CLI without a
shell, and consumes the token after success or failure. The Hook denies the raw
mutation shapes it knows and any guarded CLI invocation it cannot parse. It bounds
honest mistakes, not a determined caller, and known gaps remain: a script written to a
file and then run, `xargs sh -c`, and names built dynamically inside interpreter code.
This binds the approved
action and prevents accidental payload drift; it does not prove a hostile model
actually obtained user approval. The helper accepts no environment overrides - the
CLI uses the current authenticated environment.

`11` exists because a bounded hang and a failed write are different facts, and a caller
cannot tell them apart from a generic non-zero. A killed CLI also only receives the
signal itself, so a helper process it spawned can outlive it. The collision fails safe
in the direction that matters: a CLI failure read as unknown sends you to check state,
while a timeout read as a clean failure would not.

## Confluence tool names

Current server: `createConfluenceContent`, `updateConfluenceContent`,
`getConfluenceContent`, `searchConfluence`. Older server: `createConfluencePage`,
`updateConfluencePage`, `getConfluencePage`, `searchConfluenceUsingCql`. Use the current
names; if a call reports an unknown tool, check the live tool list for the other
generation before substituting. `getConfluenceSpaces` exists in neither generation -
reach spaces through `searchConfluence` or `discover` plus `executeRead`.

## Hook backstops

Prompt rules are not enough for irreversible writes. These hooks enforce the
highest-risk rules even when a future skill forgets the prompt contract:

| Hook | Blocks |
|------|--------|
| `slack-send-guard.sh` | all 11 Slack write tools - `slack_send_message`, `slack_schedule_message`, `slack_create_canvas`, `slack_update_canvas`, `slack_add_reaction`, `slack_create_conversation`, `slack_add_list_record`, `slack_update_list_record`, `slack_create_list`, `slack_update_list`, and `slack_complete_file_upload`; use `slack_send_message_draft` |
| `jira-write-guard.sh` | Jira mutation tools without a fresh `workspace/.jira-write-token`; Jira body writes with missing `contentFormat`, or ADF bodies outside an approved batch token (see `.claude/docs/jira-write-pattern.md`) |
| `confluence-size-guard.sh` | Confluence bodies over 70 KB; writes with an unset or unaccepted body format (see `.claude/docs/confluence-adf-pattern.md`) |
| `atlassian-generic-write-guard.sh` | `executeWrite` and `executeDestructive`, whose opaque payload no named Atlassian gate can read; `createConfluenceComment` under `executeWrite` is the one allowed operation, and only when its body format, body size, and addressing fields pass this hook's own checks, its body passes `prose-lint.py` (surface `confluence-doc`), and a single-shot `jira-write-token` bound to the payload is valid (the hook pipes the call into `jira-write-guard.sh`) |
| `block-dangerous-git.sh` | destructive or protected-branch git commands |
| `external-cli-write-guard.sh` | raw GitHub, Azure/ADO, Kubernetes, and Terraform mutations, `confluence-publish.py attach` (an ungated REST upload otherwise), plus unrecognized commands for those guarded CLIs |
| `prose-lint-guard.sh` | Slack draft bodies that fail `prose-lint.py`; it fails open when the linter is unavailable, because a quality check must not block a write on its own breakage. `gh` payload prose goes through `external-write-action.py`'s own `prose_gate_findings` instead |

These guards select by tool name, so an upstream rename silently turns one off:
the matcher stops matching and the guard exits 0 on every call. Each guarded name
is therefore pinned in `.claude/scripts/validate-workspace.sh`, which probes the
live matchers and the guard bodies. When an MCP renames a write path, add the new
name in the same commit as the pin - do not swap it, because both generations can
be installed at once.

## What the CLI guard does with a command it cannot parse

`gh`, `az`, `kubectl`, and `terraform` are the four guarded executables. Parsing is done by
`.claude/scripts/shell_scan.py`, the same parser `block-dangerous-git.sh` uses, so a wrapper
or shell construct is closed once for both. It resolves quotes and `$'..'`, splits on every
separator, reads compound commands (`for`, `if`, `while`, `case`, `{ }`, `( )`, `!`,
function bodies), strips command wrappers with their value-taking options (`env`, `sudo`,
`doas`, `time`, `timeout`, `nice`, `nohup`, `setsid`, `stdbuf`, `xargs`, `exec`, `command`,
`find -exec`, ...), and reads into `bash -c`, `eval`, `$(...)`, backticks, process
substitution, heredocs, here-strings, and the left side of a pipe into a shell. A simple
`VAR=literal` is tracked, so `G=gh; $G pr create` resolves to `gh`.

`guard` runs three checks in order, and only the first of them consults those names:

1. **Unbindable target, guarded name present.** A `$(...)`, a backtick, `eval`, `alias`,
   `source`, or a command that cannot be lexed leaves a program the parser cannot bind. That
   blocks only when one of the four names appears in the command text. Reading the text
   rather than the parsed invocations is what catches a name the parser cannot place:
   `echo "count: $(gh pr list)"` has it inside a substitution. Drop the name -
   `echo "count: $(date)"` - and it is allowed. A command that cannot be lexed also counts
   a shell name as reach, because it can hide a `| bash`.
2. **Mutation.** A statically bound guarded invocation that mutates: `gh pr create`,
   `terraform apply`, `kubectl delete`, wherever the parser finds it - behind a wrapper,
   inside a loop body, a function body, a substitution, an unquoted heredoc, a here-string,
   or text piped into a shell.
3. **Unrecognized or unenumerable invocation.** A guarded invocation the read-only
   allowlist does not recognize, **and** every construct whose executed command cannot be
   enumerated at all. A dynamic program (`$X pr create`, `$(printf 'g''h') pr create`),
   `eval`, `source`, `alias`, a shell reading its script from a pipe or a here-string, and
   a substitution inside a nested `bash -c` script are all in the second class, so
   `eval "ls -la"` and `echo hi | bash` block with no guarded name anywhere.

So a dynamic construct alone does not block, and a guarded name is not what decides it in
every case: check 1 needs the name, check 3 does not. A `$(git rev-parse HEAD)` inside an
`echo` reaches none of them, which is the point - blocking every command the parser cannot
bind blocked the read-only majority for nothing. One narrow exception to check 1: a substitution that only fills an argument of a literal `gh` read (`gh pr view $(git branch --show-current)`) does not block, because the noun and verb are fixed and the verb has no write flag. A substitution in the program, noun, or verb, around `gh api`, `gh auth`, or any other guarded CLI, or holding a guarded command itself still blocks. Kubernetes and Terraform global flags (`-n`, `--context=`, `-chdir=`) are skipped before the verb is read, so `kubectl -n prod get pods` is a read and `kubectl -n prod delete pod x` is still a mutation. Three consequences worth knowing:

- **Heredoc bodies are data, not commands.** `cat > file <<EOF` writes prose; its lines are
  not parsed as invocations, so a guarded verb sitting in that prose does not block the
  write. An unquoted body still runs its `$(...)` and backticks, so a mutation inside one is
  found. The exception is a heredoc feeding a shell (`bash <<EOF`, quoted or not), where the
  body really is executed and is read as commands.
- **What this guard cannot see.** Anything a script or task runner executes for itself:
  `bash deploy.sh`, `./deploy.sh`, `make deploy`, and `npm run deploy` are all allowed,
  whatever the file goes on to run. Also a program name no parser can read statically, such
  as one a script computes at run time. A name assembled into a variable is *not* in this
  class any more: `X=$(printf 'g''h'); $X pr create` leaves `$X` as a dynamic executable,
  which check 3 blocks. This guard bounds the commands this agent writes by mistake; it is
  not a sandbox against a hostile author.
- **An unlexable command still reaches checks 2 and 3.** `printf 'unterminated` lexes to
  nothing useful and is allowed, but `printf 'unterminated | bash` is blocked, because an
  unparseable command that names a shell is treated as reaching one. The commands before a
  syntax error are still parsed, since a shell runs them.

Checks 2 and 3 read one answer per invocation from `classify()` in
`external-write-action.py`. The answer is `read`, `local`, `mutation`, or `unrecognized`.
`prepare` reads the same answer and refuses anything that is not a `mutation`.

Four forms pass only as the whole command: `gh api <path> -X OPTIONS`,
`gh api <path> -X GET --input <file>`, `kubectl config use-context <name>`, and
`terraform workspace select <name>`. The command text must be exactly those plain words,
single spaced. A variable, a quote, a wrapper, an environment prefix, a redirect, a pipe,
or a second command blocks them under check 3.

The git guard reads the same parse. It also fails closed on a push refspec it cannot read
literally (`$BRANCH`, `{main,}`, `refs/heads/*:refs/heads/*`), and on a bare `git push`
whose repository directory it cannot resolve (`cd`/`pushd`/`-C` with a variable, `GIT_DIR`,
`--git-dir`, `--work-tree`): name the branch, or use `git -C <literal path>`. A call to a
function the same command defines is read as a possible git call, and its arguments are also
read as a command, so `g() { git "$@"; }; g push origin main` blocks. Wrappers outside the
parser's table (for example `strace`, `parallel`, `ssh host`) and programs that run a git
command from their own script text (`python3 -c`, `awk system(...)`) are not seen; extend
the table in `shell_scan.py` rather than adding a pattern to either guard.

## Jira token contract

Every Jira mutation needs a fresh JSON token written immediately before the
tool call, after the payload-showing approval. For a single-shot mutation, bind the
exact payload:

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
PAYLOAD_SHA=$(jq -cS '.tool_input // {}' "$JIRA_TOOL_CALL_JSON" | tr -d '\r' | shasum -a 256 | awk '{print $1}')
```

`createJiraIssue` may omit issue keys because the issue does not exist yet;
link/comment/transition/edit calls must identify their target keys. `tool_name`
must exactly match the current MCP tool name; the namespace prefix may differ
by MCP server, so do not blindly copy the example value.
If the guard cannot parse the hook JSON or its required `jq` dependency is
missing, it blocks the mutation instead of guessing.

### Batch token (approved multi-ticket runs)

When one approval covers a batch of mutations across several tickets (e.g. cancel N
incidents, each needing a transition + a comment), a single-shot token per call is
wasteful - every call re-derives a payload sha. Write one **batch token** instead, after
the approval that showed the per-ticket plan:

```json
{
  "approved_issues": ["SRE-1", "SRE-2"],
  "max_ops": 6,
  "created_at": "2026-06-12T15:40:00Z",
  "payload_summary": "cancel approved incidents",
  "tools": ["transitionJiraIssue", "addCommentToJiraIssue", "addOrEditJiraIssueComment"],
  "ttl_seconds": 900
}
```

The hook authorizes any gated Jira mutation whose target issue is in
`approved_issues`, up to `max_ops` calls, within the TTL (**900s**;
`ttl_seconds` may only shorten that window, never extend it). `max_ops` is capped at
**100**. It decrements `max_ops` on each allowed call and
deletes the token when the budget is exhausted or the TTL passes. `tools` is an
optional allowlist. An entry matches a tool name exactly or as a suffix (to tolerate MCP
namespace prefixes), so list both comment tool names when either server generation
may be in play: `addCommentToJiraIssue` does not permit `addOrEditJiraIssueComment`.
Omit `tools` to allow all gated Jira tools. A non-empty `approved_issues` array is
what selects batch mode.

Publish tokens with `python3 .claude/scripts/jira-write-token.py --root . --content-file <approved-token.json>`. Publication, validation, consumption,
and audit logging share the repo-wide workspace mutation lock. Concurrent calls
therefore share one atomic approval budget: a single-shot token allows exactly
one call, and a batch token allows at most `max_ops` calls. If the lock cannot
be acquired within two seconds, the hook blocks the call and leaves the token
untouched.

Batch mode trades the exact-payload sha binding for an **issue allowlist + op
cap + TTL**: a runaway loop still cannot touch a ticket outside the approved set
or exceed the approved op budget. Use it only for the concrete batch the user
just approved; for a single irreversible mutation, prefer the single-shot token.
A malformed or stale token is deleted. A call that does not match the current
token leaves it untouched, so an approval for a separate pending mutation is
not consumed. `createJiraIssue` (no target key) still requires a single-shot
token.

Size the op budget to cover the planned calls (e.g. 4 tickets × [transition +
comment + close transition] = 12). The token authorizes mutation *count*, not
exact text - show the per-ticket disposition in the approval so the user
approves the substance, not just a number.

The hook decrements `max_ops` in `PreToolUse`, before the MCP server validates the
payload, so a call the schema rejects still costs one op. Budget one spare op, and
check parameter names against the loaded tool schema before the first call (seen
rejected: `body` for `commentBody`, a `transition` object for `transitionId`).
Take `created_at` from the real clock, never from an estimate. The hook rejects a
value ahead of real time as stale or from the future.

## GitHub auth account guard

Workspaces with multiple `gh` accounts can lose the intended active account between
commands. Every GitHub mutation therefore runs through
`.claude/scripts/external-write-action.py`. `prepare` resolves the target owner and
maps it through top-level `workspace/config.md`: `github_org` selects
`work_gh_account`, while an owner matching `personal_gh_account` selects the personal
identity. It binds both owner and account into the hashed action. `execute` re-reads
the mapping, loads that account's credential with `gh auth token --user`, verifies the
token actor with `gh api user`, and passes `GH_TOKEN` only to the mutation subprocess.
It never changes shared `gh` account state. A missing, changed, unreadable, unmapped,
unselectable, or actor-mismatched account blocks the write and consumes the one-shot
token.

The helper derives owners from `-R`/`--repo`, `--org`/`--owner`, REST API paths,
repo positional targets, or PR or issue URLs. It never falls back to the current
`origin`: the helper runs in the nase checkout, so a write that names no repository
(`gh pr merge 12`) is refused at `prepare` instead of landing on the workspace repo.
Opaque API/GraphQL, PR or issue URL, repo positional, gist, and user-scoped mutations
must also pass `prepare --github-owner <owner>`; that value must match any owner
encoded in the command.
GitHub writes are restricted and manifest-bound to `github.com`; enterprise hosts,
environment host overrides, and duplicate target selectors fail closed.
Execution clears `GH_REPO` and token environment overrides so they cannot redirect
the approved target or actor before it selects the manifest-bound token.

Raw `gh auth token`, `login`, `logout`, and `refresh` commands are blocked. `gh auth switch` is allowed: it only changes which local account is active, and a write never reads that state.
Only `gh auth status` without `-t`/`--show-token` may run outside the helper.
Raw Azure access-token output and login/logout commands are also blocked; ordinary
read-only account inspection remains allowed.
Credential-bearing Azure reads, Kubernetes Secret/raw-config reads, and Terraform
output/state reads fail closed so secret values cannot enter command output.

The selected token is captured, never printed or stored in the manifest, and scoped to
the exact `gh` subprocess. Mutation skills reference the shared helper; they do not
copy token-selection snippets.

## Related memories

- `feedback_no-address-comments-others-pr.md` - never mutate someone else's PR without permission
- `feedback_ado-az-cli-only.md` - never `curl` with `$ADO_PAT` (use `az` CLI; same auth boundary as user)
- `feedback_gh-auth-active-account-flips.md` - the multi-account `gh auth switch` non-durability that motivates the guard above
