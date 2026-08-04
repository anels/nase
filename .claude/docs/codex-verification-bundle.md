# Codex Verification Bundle

This document owns the local artifact passed to FSD quality and spec reviewers. Review invocation and action reduction live in `.claude/docs/fsd-delivery-gates.md` and `.claude/scripts/fsd-review-gate.py`.

## Build

```bash
python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" \
  --base "$BASE" \
  --task "$canonical_task_spec" \
  --inventory-file "{canonical_inventory_json}" \
  --evidence-file "{command_evidence_json}" \
  --reviewer-identity-output "{nase_workspace}/workspace/tmp/fsd-qa-{branch_slug}-r{qa_round}-identity.json" \
  --output "{nase_workspace}/workspace/tmp/fsd-qa-{branch_slug}-r{qa_round}.md"
```

Keep inventory, evidence, result, state, and bundle files outside the target repository. Otherwise those artifacts become untracked candidate content.

The first bundle line is machine-readable `fsd-artifact` JSON. It records:

- resolved `base_oid`
- `head_oid`
- `candidate_tree_oid`
- `contract_inventory_sha256`
- changed-path count and hash
- deterministic evidence metadata and its tested `candidate_tree_oid`
- requested bound-context metadata
- symlink, gitlink, missing-blob, or special-file evidence gaps
- bounded binary-path object metadata; binary patches are never embedded

`--reviewer-identity-output` writes trusted JSON containing the resolved `base_oid`, `candidate_tree_oid`, `contract_inventory_sha256`, and SHA-256 of the exact finished bundle bytes. Keep it outside the target repository, pass it outside the untrusted bundle section of the reviewer prompt, and require the reviewer to copy it exactly into `result.artifact`. Pass the same captured bundle value to every reducer invocation as `--expected-bundle-sha256` together with the independently resolved `--expected-base-oid`. This rejects body tampering or an incorrect diff base even when a reviewer echoes the bundle's self-description.

## Candidate Tree

The helper creates a temporary `GIT_INDEX_FILE`, runs `read-tree HEAD`, `git add -A -- .` only against that temporary index, then `git write-tree`. It never changes the real index. The resulting tree captures tracked, unstaged, untracked, deleted, renamed, and mode-changed paths while respecting ignored files.

All stat, name-status, changed-line, sample, and full-diff sections compare `base_oid` directly with `candidate_tree_oid`. Rename samples use the actual source and destination paths. Binary patches are represented only by path, mode, Git object OID, and byte size. Text diff projections are capped at 64 KiB, full diffs at 128 KiB of changed blob content, and the entire bundle at 512 KiB. Staging or committing the same content therefore preserves the reviewed identity.

To resolve only the candidate identity:

```bash
python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" \
  --base "$BASE" \
  --inventory-file "{canonical_inventory_json}" \
  --candidate-tree-only
```

## Verification Evidence

Resolve `tested_candidate_tree_oid` immediately before the final verification commands. Run them, resolve the candidate again, and require exact equality before writing evidence with this schema:

```json
{
  "candidate_tree_oid": "exact tree tested by every command below",
  "commands": [
    {"command": "exact command", "exit_code": 0, "summary": "bounded normalized result"}
  ]
}
```

`commands` must be non-empty when `--evidence-file` is supplied and every `exit_code` must be zero. The helper rejects unknown keys, failed or invalid command records, or evidence whose tree differs from the bundled candidate.

An evidence payload is capped at 64 KiB. Larger JSON keeps SHA-256, original byte count, and head/tail projection. Invalid UTF-8 is rejected.

Before writing any reviewer artifact, the helper runs a redacted, high-confidence secret preflight over the canonical task, inventory, structured command evidence, candidate diff, every changed candidate blob, and any requested context projection. Blob and diff scans use bounded chunks. A possible credential stops bundle creation and reports only kind plus location, never the matched value. Existing repository secret tooling may add broader checks, but must run against the same candidate tree before external review.

## Bound Context

When the reducer returns `CONTEXT`, pass its output to the next bundle:

```bash
python3 .claude/scripts/codex-verify-bundle.py \
  --repo "{worktree_or_repo}" \
  --base "$BASE" \
  --task "$canonical_task_spec" \
  --inventory-file "{canonical_inventory_json}" \
  --evidence-file "{command_evidence_json}" \
  --context-request-file "{reducer_output_json}" \
  --reviewer-identity-output "{next_identity_json}" \
  --output "{next_bundle}"
```

The context file must be the reducer result containing `base_oid`, `candidate_tree_oid`, `contract_inventory_sha256`, and `context_requests`. The reducer rejects more than 64 requests before any Git lookup; accepted requests are deduplicated by tree selector and normalized path. The helper resolves the path entry from only the bound `base_oid` or `candidate_tree_oid` with `git ls-tree`, then reads that exact blob OID with `git cat-file`; it never reads the live worktree.

A reducer result carries both bound OIDs and the inventory hash. When supplied, the helper preserves those OIDs even if the live worktree or CLI base ref moved, while recording the current candidate/base separately. The next reducer then rejects live candidate drift as `STALE`.

Each context payload is capped at 64 KiB and total embedded context at 256 KiB. Hash and original byte count survive truncation. Symlinks, gitlinks, special files, missing blobs, non-UTF-8 blobs, and paths absent from the selected tree are explicit evidence gaps. The reducer consumes both bundle-declared and reviewer-requested gaps, so no declared gap can silently pass.

## Closure Binding

Reviewers must echo `base_oid`, `candidate_tree_oid`, `contract_inventory_sha256`, and the exact bundle SHA-256. The reducer rejects a mismatch with the independently captured pre-review bundle SHA-256, candidate tree, changed-path hash/count, inventory hash, or reviewer echo as `STALE`.

Before commit, the real staged `git write-tree` must equal `approved_candidate_tree_oid`. After commit and commit-message amend, `HEAD^{tree}` must equal it. A mismatch restarts Phase 6 and both fresh reviews. No similar diff, staged descendant, or later commit inherits approval.
