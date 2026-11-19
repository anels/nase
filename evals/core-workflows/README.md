# Core Workflow Evals

Offline output-shape cases for high-frequency planning, daily, learning, onboarding, incident, and deployment workflows.

```bash
python3 .claude/scripts/pr-review-eval.py validate evals/core-workflows/evals.json
python3 .claude/scripts/pr-review-eval.py score \
  --eval-set evals/core-workflows/evals.json \
  --case design-implementation-ready \
  --output /path/to/output.txt
python3 .claude/scripts/skill-eval-run.py run-routing \
  --eval-set evals/core-workflows/evals.json \
  --routing-case routing-design-positive \
  --model MODEL --repetitions 3 --max-budget-usd USD --timeout-seconds N
python3 .claude/scripts/skill-eval-run.py run-output \
  --eval-set evals/core-workflows/evals.json \
  --runtime-case runtime-design-grounding \
  --model MODEL --max-budget-usd USD --timeout-seconds N
python3 .claude/scripts/skill-eval-run.py run-output --arm no-skill \
  --eval-set evals/core-workflows/evals.json \
  --runtime-case runtime-design-grounding \
  --model MODEL --repetitions 3 --max-budget-usd USD --timeout-seconds N
python3 .claude/scripts/skill-eval-run.py ablate \
  --eval-set evals/core-workflows/evals.json \
  --manifest-dir workspace/stats/skill-evals
```

`--arm no-skill` runs the same case without the skill file or the docs, and
without the slash command in the prompt. Its receipts use the lane
`output-baseline`, so they never count in `coverage`. A baseline receipt goes
stale when the skill file changes, so re-run both arms on the same skill
revision. `ablate` prints raw counts per case, model and arm (total, error,
scored, pass) and the median cost and duration. An error is never a pass. The
verdict is `insufficient` until both arms have 3 scored runs. It is a label, and
the counts are the evidence.

Expect a ceiling. The scoring assertions are three regexes, and a capable model
without the skill will likely pass them. The first ablation will mostly measure
cost and duration, not skill value. A baseline run also loses `.claude/docs` by
design.

The historical checker filename is retained for compatibility; it accepts any
schema-v1 skill eval set. These cases validate observable output and safety
shape, not the technical truth of a real task. Runtime receipts remain private
under `workspace/stats/skill-evals/`; live calls require an explicit paid-run
decision and are never a CI gate.
