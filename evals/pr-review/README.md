# PR Review Evals

Offline eval cases for PR/review-related nase skills.

These evals are intentionally local and deterministic. Run the skill manually or
with a harness, save the produced chat output to a file, then score it:

```bash
python3 .claude/scripts/pr-review-eval.py validate evals/pr-review/evals.json
python3 .claude/scripts/pr-review-eval.py score --eval-set evals/pr-review/evals.json --case discuss-pr-problem-first --output /path/to/output.txt
python3 .claude/scripts/skill-eval-run.py run-routing --eval-set evals/pr-review/evals.json --routing-case routing-discuss-pr-positive --model MODEL --repetitions 3 --max-budget-usd USD --timeout-seconds N
python3 .claude/scripts/skill-eval-run.py run-output --eval-set evals/pr-review/evals.json --runtime-case runtime-discuss-pr-grounding --model MODEL --max-budget-usd USD --timeout-seconds N
```

The assertions check observable output shape: problem framing before findings,
file:line evidence, safe external-mutation language, reviewer classification,
deep-dive comment dossiers, explicit non-blocking nits, needs-answer questions,
must-not-merge review states, self-review constraints, explicit-only AI
verification-debt reporting, and concise Slack review-request drafts. They do
not replace human review of finding quality. Runtime receipts remain private
under `workspace/stats/skill-evals/`; live model runs are manual and paid, never
part of CI. Use `coverage` to view structural, invocation, outcome, and human
evidence separately, then `review` to accept or reject a current passing output
receipt.
