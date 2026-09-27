# FSD Phase 7: commit-message conformance

Branch-specific procedure for `/nase:fsd` Phase 7, loaded when the phase runs. The entrypoint
keeps only the pointer.

## Conform the subject after the initial commit

The helper amends HEAD, so it runs at Step 4 of `.claude/docs/commit-push-pattern.md`, after the
Step 3 commit. Running it earlier rewrites the previous commit. That document owns the
invocation and the `--repo` requirement; this file does not restate them.

The subject must satisfy `gate_profile.commit_format` per
`.claude/docs/pr-gates-consumption.md` section 3, meaning the documented `type` and `scope` set
and no `fixup!` or `squash!` prefix.

## Verify after it runs

That skill polishes prose but does not know this repo's scope and type rules, so check the
resulting subject against `gate_profile.commit_format` after it returns, per that section's
verify-after branch.

## Protected-branch stop condition

The helper disables `--auto-accept` whenever its `is_protected` is true, which includes a ref
`rev-parse` cannot name. If it returns an approval prompt instead of an amend, the branch setup
is wrong. Stop and report the branch. Do not answer the prompt to get past it.

The tree OID assertion in `/nase:fsd` Phase 7 runs again after this helper returns, so an amend
that changed anything but the message fails there.
