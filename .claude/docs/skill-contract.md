# Skill Output Contract

> Canonical rules for every `/nase:*` skill that produces a substantial artifact (report, scorecard, synthesis, multi-section list, journal entry).
>
> This doc is referenced from `CLAUDE.md` and from individual skill files. Edit here, not in the skills.

## The contract

1. **Full artifact → file.** Write the complete content to one of:
   - `workspace/journals/`, `workspace/recaps/`, `workspace/stats/`, `workspace/tmp/`, or
   - the skill's documented output path.

   The file is the canonical record. Re-running the skill overwrites or replaces the file, never appends a second copy.

2. **Chat → pointer + summary only.** The chat reply contains exactly:
   - `{Artifact} saved → {path}`
   - 1–5 short lines pulling the highlights.

   Never re-render the full artifact inline. The user opens the file when they want detail.

3. **`--verbose` opt-in.** If the user passes `--verbose` in `$ARGUMENTS`, dump the full content inline in addition to writing the file. This is the legacy behaviour, opt-in only.

4. **Batch `AskUserQuestion` calls.** If a skill needs more than one upfront decision (mode, isolation, PR target, success criteria), pass a single `AskUserQuestion` with a `questions` array. One ask, not N asks.

## Checkpoint discipline (push-right + brief)

Rule 4 governs *how* to ask when a checkpoint is unavoidable; this governs *when* to place it and *what* it presents. A **checkpoint** is any point where the skill stops to make the user verify or decide.

Safety and mutation approval gates are the exception. Follow `.claude/docs/external-mutation-policy.md` and the relevant trust-boundary contract: show the exact payload immediately before each action and gate each action at the required timing, even when that means presenting raw payload content or using more than one approval gate. The push-right / brief rules below apply only after those stricter requirements are satisfied.

- **Push right.** Defer every checkpoint as far as it will go. Do the maximal work the evidence allows — research, codebase lookups, sub-agent fact-finding — *before* involving the user, so they are asked once, late, with everything already prepared. A question the codebase or KB can answer is never a checkpoint (it is a lookup the skill owes itself). `/nase:design` auto mode is the reference: it front-loads research/grill and asks the genuinely-unanswerable questions in one batch at the very end. The frontier-round grill (`design-grill-mode.md`) is the same move — resolve facts first, ask the settled frontier once per round.
- **Brief, not draft.** What a checkpoint presents is a decision-ready summary — what was produced, why, and a link down to the asset — never the raw output. The user reads a brief and decides; they open the file (rule 2) when they want the full artifact. Speed of review is the point: a checkpoint that dumps the draft makes the user do the skill's synthesis work.

Attribution: push-right / brief vocabulary from mattpocock/skills `loop-me` — see `workspace/kb/general/workflow.md → §2026-07-16`.

## Redact before you show

Applies to **every** skill, not only artifact-producing ones: any command you show, any output you paste into chat, any evidence you quote into a file, a PR body, a review comment, or a Slack draft.

- **Redaction is the first move on the material, not a review pass at the end.** Write `<REDACTED>` in place of the value before the text reaches chat or a draft. A secret that reaches chat has already leaked into the transcript; deleting it from the final artifact does not unsend it.
- **Build the command against the environment, so the credential never enters what you show.** `curl -H "Authorization: Bearer $TOKEN"`, `az ... --query`, `gh api` with the token in the environment - show the invocation with the variable name, never the expanded value. The same rule kills `echo $TOKEN`-style verification steps: prove the variable exists without reading it, or report only its length.
- **Quote only the signal-carrying lines of a captured artifact.** HAR files, `az` JSON, request dumps, and CI logs carry auth headers, connection strings, and cookies far from the line you actually need. Quote the shortest decisive line, never the whole capture.
- **If the redacted evidence is no longer enough to make the point, say so and ask the user** — do not quietly widen what you paste to make the argument land.
- Tool-level scanning stays where it already is (`gitleaks detect --redact`, `.claude/docs/kb-teamshare-file-processing.md`, `tests/check-local-sensitive-artifacts.sh`). Those catch what reaches a file; this rule governs what reaches the screen, which is earlier.

`[CONFIDENTIAL]` handling is a separate axis — see `.claude/docs/confidential-marker.md`. A line can be non-confidential and still carry a token.

Attribution: redact-first from mattpocock/skills `diagnosing-bugs` — see `workspace/kb/general/workflow.md → §2026-08-06`.

## Why

Output tokens are the most expensive surface in a long session: a 200-line report in
chat costs roughly ten times a 5-line summary plus a file write, with no review
benefit, and the file is searchable, diff-able, and survives compaction where chat
scrollback does not.

New skills inherit this contract automatically and do not restate it. A skill that
needs to deviate says so in its own `## Notes`, with a one-line reason.

The author-side checklist, and the worked examples of skills that already conform,
live in `.claude/docs/skill-authoring-contract.md → 9. Output discipline`. They are
for writing a skill, not running one, so they are not loaded at runtime.
