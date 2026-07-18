# Core Workflow Evals

Offline output-shape cases for high-frequency planning, daily, learning, onboarding, incident, and deployment workflows.

```bash
python3 .claude/scripts/pr-review-eval.py validate evals/core-workflows/evals.json
python3 .claude/scripts/pr-review-eval.py score \
  --eval-set evals/core-workflows/evals.json \
  --case design-implementation-ready \
  --output /path/to/output.txt
```

The historical checker filename is retained for compatibility; it accepts any schema-v1 skill eval set. These cases validate observable output and safety shape, not the technical truth of a real task.
