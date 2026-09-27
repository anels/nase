# Jev Judgment Points

TypeSafe's Jev (System One) answers small, bounded judgments - Choice (pick from a fixed set), Score (rate one dimension), Noul (yes/no) - fast and cheap: typed state in, typed judgment out. `.claude/scripts/jev-judge.py` is the one seam every skill calls; call sites never talk to the Jev API directly.

The API shape and degrade philosophy are carried over from this same product's OMC plugin integration (see Provenance below), sized down for nase's one-call-per-decision usage instead of a persistent shadow/circuit-breaker rollout.

## Contract

- No `TYPESAFE_API_KEY` set, or `NASE_JEV=off` → the script prints `{"available": false, ...}` immediately, zero HTTP calls, zero egress.
- `--dry-run` is the one path that runs without a key. It prints the request body that would be POSTed and exits before building the request, so it is still zero HTTP calls and zero egress. `NASE_JEV=off` is checked first and still wins, so the kill switch is never bypassed, and with it set `--dry-run` prints `{"reason": "disabled"}` rather than a body.
- Any HTTP, timeout, or malformed-response failure → same `{"available": false, "reason": "..."}` shape, never a crash, never a hang past `NASE_JEV_TIMEOUT_MS` (default 2500ms).
- `reason` distinguishes the failure kinds that need different responses: `http_error:<code>` is the API rejecting the request (a contract bug - fix the call), `timeout` is the deadline expiring, `net_error:<class>` is the connection failing. Collapsing these hides contract bugs behind what looks like a flaky network. `<class>` is an exception class name such as `ConnectionRefusedError`, never a message, so it can be matched on.
- Three more reasons mean the call was never attempted because the invocation itself is wrong, and they are fixed at the call site rather than retried: `invalid_config:<msg>` (`NASE_JEV_TIMEOUT_MS` or `NASE_JEV_EXCERPT_CHARS` is not an integer), `invalid_endpoint_scheme` (`NASE_JEV_ENDPOINT` is not http(s)), and `exception:bad_json:<msg>` (`--criteria` or `--state` is not parseable JSON). Two more are catch-alls: `invalid_response[:<msg>]` for a body that is not the documented answer shape, and `exception:<msg>` for any other client-side failure. The script's module docstring is the sole enumeration, and `tests/scripts/test-jev-judge.sh` asserts every reason above appears in it.
- Success with `confidence >= 0.9` → trust the answer, skip the point's own full judgment.
- Success with `confidence < 0.9`, or `confidence` missing → still `"available": true`, but judge the point yourself using the same criteria; treat the jev answer only as a hint, never as the decision.
- **The fallback in every case is: do exactly what the skill instructed before this script existed.** Adding a jev call must never change behavior for a user with no `TYPESAFE_API_KEY` configured.

## Config

| Env var | Default | Meaning |
|---|---|---|
| `TYPESAFE_API_KEY` | unset | presence enables Jev; absence is the normal, zero-egress state |
| `NASE_JEV=off` | unset | master kill switch, overrides key presence |
| `NASE_JEV_TIMEOUT_MS` | 2500 | per-call timeout. A healthy call measures ~1100ms, so a budget under that turns every success into a reported `timeout`. |
| `NASE_JEV_EXCERPT_CHARS` | 200 | max chars of any string sent in state/criteria (never whole files) |
| `NASE_JEV_ENDPOINT` | `https://api.typesafe.ai/v1/systemone` | override for testing |

## Calling it from a skill

```bash
python3 .claude/scripts/jev-judge.py \
  --point <skill-name>.<step-name> \
  --type Choice \
  --criteria '{"label": "one-line description", ...}' \
  --state '{"finding_text": "<the bounded text being judged>"}'
```

Read the single line of JSON on stdout. `available: false`, or `confidence` under 0.9 or missing, means fall back to the skill's own judgment for that point.

`--type` takes the capitalized spelling (`Choice` / `Score` / `Noul`); the script lowercases it on the wire, because the API pins each question schema's `type` to a lowercase const and rejects anything else with HTTP 400.

`--dry-run` prints the request body and exits without a key and without a network call. Use it to check a new call site's shape, and note that `tests/scripts/test-jev-judge.sh` asserts the wire casing through it.

## Where a point's definition lives

Each judgment point is documented once, inline at its own `Try jev first (...)` call site - in the skill/command file that uses it, or in the shared doc that file routes the step to, but never in both and never in a second table here. That sentence names the point, its `state` (the bounded text/JSON sent), and points at the labels/options already written a few lines above or below it in the same file (that list doubles as the point's `criteria`). Keeping the definition next to the call site means there's only one place to update when either changes.

To find every point currently wired up: `grep -rn "jev-judgment-points.md" .claude/commands/nase .claude/docs workspace/skills`. `.claude/docs` is not optional - `discuss-pr.kind` and `discuss-pr.disposition` live only in `.claude/docs/discuss-pr-analysis.md`.

## Provenance

The API shape (`POST /v1/systemone`, `{state, questions, model: "jev-latest"}`, bearer auth, `{answers: {name: {type, choice|score|noul, confidence}}}`) and the degrade philosophy come from this same product's OMC plugin integration (`docs/adr/03665-jev-degradation-contract.md`, `docs/issues/issue-3669-jev-judgment-points.md`, `src/hooks/jev/` in the `omc` marketplace plugin). nase's version drops OMC's shadow-mode, circuit-breaker, and manual-promotion machinery - that exists to earn trust across OMC's many hook-triggered calls per session; nase calls this once per named decision point per skill run, so it goes straight to active-with-confidence-gated-fallback instead.
