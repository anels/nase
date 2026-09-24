# Jev Judgment Points

TypeSafe's Jev (System One) answers small, bounded judgments - Choice (pick from a fixed set), Score (rate one dimension), Noul (yes/no) - fast and cheap: typed state in, typed judgment out. `.claude/scripts/jev-judge.py` is the one seam every skill calls; call sites never talk to the Jev API directly.

The API shape and degrade philosophy are carried over from this same product's OMC plugin integration (see Provenance below), sized down for nase's one-call-per-decision usage instead of a persistent shadow/circuit-breaker rollout.

## Contract

- No `TYPESAFE_API_KEY` set, or `NASE_JEV=off` → the script prints `{"available": false, ...}` immediately, zero HTTP calls, zero egress.
- Any HTTP, timeout, or malformed-response failure → same `{"available": false, "reason": "..."}` shape, never a crash, never a hang past `NASE_JEV_TIMEOUT_MS` (default 250ms).
- Success with `confidence >= 0.9` → trust the answer, skip the point's own full judgment.
- Success with `confidence < 0.9`, or `confidence` missing → still `"available": true`, but judge the point yourself using the same criteria; treat the jev answer only as a hint, never as the decision.
- **The fallback in every case is: do exactly what the skill instructed before this script existed.** Adding a jev call must never change behavior for a user with no `TYPESAFE_API_KEY` configured.

## Config

| Env var | Default | Meaning |
|---|---|---|
| `TYPESAFE_API_KEY` | unset | presence enables Jev; absence is the normal, zero-egress state |
| `NASE_JEV=off` | unset | master kill switch, overrides key presence |
| `NASE_JEV_TIMEOUT_MS` | 250 | per-call timeout |
| `NASE_JEV_EXCERPT_CHARS` | 200 | max chars of any string sent in state/criteria (never whole files) |
| `NASE_JEV_ENDPOINT` | `https://api.typesafe.ai/v1/systemone` | override for testing |

## Calling it from a skill

```bash
python3 .claude/scripts/jev-judge.py \
  --point <point-name-from-the-registry-below> \
  --type Choice \
  --criteria '{"label": "one-line description", ...}' \
  --state '{"finding_text": "<the bounded text being judged>"}'
```

Read the single line of JSON on stdout. `available: false`, or `confidence` under 0.9 or missing, means fall back to the skill's own judgment for that point.

## Registry

One row per judgment point. The `criteria`/`state` columns are the canonical shapes for that point - keep them in sync with the actual call site when either changes, per this doc's own reuse rule (shared doc + consuming command move together).

| Point | Skill file | Type | Criteria (label → meaning) | State |
|---|---|---|---|---|
| `discuss-pr.kind` | `.claude/commands/nase/discuss-pr.md` | Choice | issue / suggestion / nit / question | finding text + surrounding evidence |
| `discuss-pr.disposition` | `.claude/commands/nase/discuss-pr.md` | Choice | blocking / non-blocking / needs-answer | finding text + its `kind` |
| `estimate-eta.lane` | `.claude/commands/nase/estimate-eta.md` | Choice | 🤖AI / 🔌Env / 🧠Human / ✅Verify | subtask description |
| `improve-commit-message.type` | `.claude/commands/nase/improve-commit-message.md` | Choice | feat / fix / docs / style / refactor / perf / test / build / ci / chore / revert | diff summary |
| `kb-update.classify` | `.claude/commands/nase/kb-update.md` | Choice | current-state-fact / durable-dated-event / no-op-status-fact / unknown-or-follow-up | the knowledge being written |
| `learn.input-type` | `.claude/commands/nase/learn.md` | Choice | url / repository / direct-tip / topic | `$ARGUMENTS` |
| `request-review.complexity` | `.claude/commands/nase/request-review.md` | Choice | simple / complex | file count, diff line count, "clearly mechanical" note |
| `request-review.cherry-pick-group` | `.claude/commands/nase/request-review.md` | Noul | is-same-group | two PR titles + commit trailers |
| `tech-digest.relevance` | `.claude/commands/nase/tech-digest.md` | Noul | is-relevant | item summary + workspace topic list |
| `agent-introspection.failure-mode` | `workspace/skills/agent-introspection.md` | Choice | wrong-mental-model / stale-context / tool-misuse / scope-drift / context-burn / duplicate-question / env-mismatch / external-dependency-hang | captured agent state |
| `appinsights-deep-triage.telemetry-route` | `workspace/skills/appinsights-deep-triage.md` | Choice | initializer-ownership / deploy-provenance / both-missing | aggregate auto/manual telemetry counts |
| `handle-support-question.question-type` | `workspace/skills/handle-support-question.md` | Choice | how-to / bug / data-discrepancy / feature-request / access | question text |
| `handle-support-question.audience` | `workspace/skills/handle-support-question.md` | Choice | internal / customer-facing | channel name + message content |
| `investigate-sre-jira.intake-route` | `workspace/skills/investigate-sre-jira.md` | Choice | sre-alert / customer-issue | ticket text |
| `sync-skill-docs.ref-action` | `workspace/skills/sync-skill-docs.md` | Choice | edit / fix-example / skip | matched reference + local context |

## Provenance

The API shape (`POST /v1/systemone`, `{state, questions, model: "jev-latest"}`, bearer auth, `{answers: {name: {type, choice|score|noul, confidence}}}`) and the degrade philosophy come from this same product's OMC plugin integration (`docs/adr/03665-jev-degradation-contract.md`, `docs/issues/issue-3669-jev-judgment-points.md`, `src/hooks/jev/` in the `omc` marketplace plugin). nase's version drops OMC's shadow-mode, circuit-breaker, and manual-promotion machinery - that exists to earn trust across OMC's many hook-triggered calls per session; nase calls this once per named decision point per skill run, so it goes straight to active-with-confidence-gated-fallback instead.
