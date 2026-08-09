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
```

The historical checker filename is retained for compatibility; it accepts any
schema-v1 skill eval set. These cases validate observable output and safety
shape, not the technical truth of a real task. Runtime receipts remain private
under `workspace/stats/skill-evals/`; live calls require an explicit paid-run
decision and are never a CI gate.
