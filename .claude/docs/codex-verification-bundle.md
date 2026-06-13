# Codex Verification Bundle

Shared bundle-generation algorithm for the Codex pre-push verification gate.
Callers invoke Codex per `.claude/docs/codex-review.md`; this doc only owns the
local markdown bundle that gives Codex enough diff context to verify the spec.
Callers must still gate per `.claude/docs/codex-review.md → Prerequisite`. When
the Codex MCP is unavailable, skip cleanly past only the Codex MCP call; callers that
define a separate local verifier fallback run that fallback outside this bundle
contract.

## Helper

Use:

```bash
python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" \
  --base "$BASE" \
  --task "$TASK_SPEC" \
  --output "{nase_workspace}/workspace/tmp/codex-verify-{short_sha}.md"
```

The helper writes a markdown bundle containing:
- task spec verbatim
- base ref
- changed-line count
- `git diff --stat`
- `git diff --name-status`
- untracked files
- full diff when the diff is small
- a largest-file diff sample when the diff is large

Do not inline generated/binary/build artifacts in the command prompt. Let the
bundle list them or sample only non-generated text files.

## Optional AI Verification Debt Context

When the caller has explicit AI provenance or verification-debt risk, append a short
caller-owned section to the Codex prompt beside the bundle path. Do not change the
helper output just to guess AI authorship.

Use this shape:

```text
AI Verification Debt Context:
- ai_provenance: explicit | none-found
- provenance_evidence: <commit trailer / PR text / bot login / session log, or none>
- risk: P0 security/data-loss | P1 correctness/runtime | P2 architecture/maintainability | P3 style/nit
- verification_gap: missing-tests | missing-scanner | missing-runtime-proof | missing-contract-doc | stale-review-thread | surviving-finding | none
- test_coverage_evidence: <commands/results or missing>
- scanner_status: <commands/results/skipped + reason>
- unresolved_risk_notes: <specific uncertainty Codex should check, or none>
```

Only `explicit` provenance may be reported as AI-sourced. If no explicit signal exists,
use `none-found` and ask Codex to verify the risk/test evidence, not authorship.

## Codex Prompt Inputs

Pass these fields to the Codex MCP prompt:
- original task spec from `$ARGUMENTS`, verbatim
- bundle absolute path
- merge base
- changed-file count and total changed lines from the bundle header
- optional AI verification debt context, when supplied by the caller
- instruction: `If this manifest is insufficient to verify the spec, return NEEDS-HUMAN with the exact missing files or diff hunks instead of guessing.`

## Result Handling

Expected Codex output:

```
VERDICT: PASS | FAIL | NEEDS-HUMAN
SPEC ITEMS NOT ADDRESSED: ...
SCOPE CREEP: ...
REASONING: ...
```

- `PASS`: log `Codex verify: PASS`, no prompt.
- `NEEDS-HUMAN`: write the full output next to the bundle as
  `codex-verify-{short_sha}-result.md`, then ask whether to push anyway, revise,
  or show the diff side-by-side.
- `FAIL`: do not push. Write the full output next to the bundle, show top
  failures and result path, then ask whether to fix, override, or cancel.
- Missing `VERDICT:`: treat as `NEEDS-HUMAN` and store raw output.

If Codex asks for locally available context, read only those requested files or
hunks, update the bundle, and rerun once. Do not loop beyond one context
completion rerun without asking.
