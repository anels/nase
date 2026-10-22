# Trace Role A/B

`discuss-pr` Step 5b spawns read-only code-trace agents. The default role is `worker` (sonnet). `lookup` (haiku) is faster and cheaper, but a trace that silently misses a caller or a config key becomes a wrong review verdict, and the miss is invisible inside the trace itself. This file is the gate's procedure: run it, record it, and let `.claude/scripts/trace-role.py` decide.

## Read the decision

```bash
python3 .claude/scripts/trace-role.py resolve
# {"role": "worker", "reason": "no-receipt"}
```

`lookup` is returned only when all of these hold:

- A receipt exists at `workspace/stats/skill-evals/trace-role.json` with `schema_version: 1`.
- Its `directive_sha256` equals the current hash of the §13 spawn directive in `.claude/docs/pr-review-verification.md`. Edit the directive and the receipt stops counting.
- `cases >= 20`.
- `lookup_correct >= worker_correct`.
- `decided_at` is within 180 days.

Anything else returns `worker` with the reason. Do not override the script at the spawn site; if the role should change, rerun the A/B.

## Run the A/B

1. Pick 20 closed PRs whose review produced a **resolvable** code-trace question: an operation-name call site, a config key's consumer, a dependency's exit-code contract, or a schema field's producer. Exclude style nits and anything answerable from the diff alone.
2. For each case, write the trace question and the ground truth as `file:line` plus one sentence saying confirmed or refuted. Ground truth comes from the merged resolution, not from an agent's answer.
3. Run the same prompt twice, once per role: the §13 directive copied verbatim, then the case question. Use a fresh context per run and hide the expected answer from the runner.
4. Score blind: correct only when the agent names the same decisive `file:line` and reaches the same confirmed/refuted conclusion. A correct conclusion with the wrong mechanism is a miss; the mechanism is what the review quotes.
5. Record the counts. The script refuses fewer than 20 cases or counts above the case total.

```bash
python3 .claude/scripts/trace-role.py record \
  --worker-correct 18 --lookup-correct 18 --cases 20
```

A tie keeps `lookup` (equal accuracy at lower cost). A lookup loss records `worker` and resolves `worker` until a later eval wins.

## What invalidates a run

- Editing §13, including the pinned-revision or trace-shape paragraphs.
- A model change on either role, or a new `roles.yaml` prompt prefix.
- Case leakage: the runner saw the expected answer, or the case set is reused so often it is memorized. Rebuild from PRs merged after the last run.

Record the case set under `workspace/stats/skill-evals/trace-role-cases/` (gitignored) so the same 20 are not re-derived, and note the PR numbers next to the receipt (a sibling note file, or the commit message of the commit that ran the eval). The receipt is intentionally small: counts, hash, date, role.
