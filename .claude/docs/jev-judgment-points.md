# Jev Judgment Points

TypeSafe's Jev (System One) answers small, bounded judgments - Choice (pick from a fixed set), Score (rate one dimension), Noul (yes/no) - fast and cheap: typed state in, typed judgment out. `.claude/scripts/jev-judge.py` is the one seam every skill calls; call sites never talk to the Jev API directly.

The API shape and degrade philosophy are carried over from this same product's OMC plugin integration (see Provenance below), sized down for nase's one-call-per-decision usage instead of a persistent shadow/circuit-breaker rollout.

## Contract

- It is a script, not a command on `PATH`, so `command -v jev` finds nothing even when everything works. Never decide Jev is unavailable by probing for a binary or by guessing from the environment. Run `python3 .claude/scripts/jev-judge.py` at the call site and read the JSON on stdout, because `available: false` with its `reason` is the only authoritative answer. `/nase:doctor` reports whether the key and kill switch allow it.
- No `TYPESAFE_API_KEY` set, or `NASE_JEV=off` → the script prints `{"available": false, ...}` immediately, zero HTTP calls, zero egress.
- `--dry-run` is the one path that runs without a key. It prints the request body that would be POSTed and exits before building the request, so it is still zero HTTP calls and zero egress. `NASE_JEV=off` is checked first and still wins, so the kill switch is never bypassed, and with it set `--dry-run` prints `{"reason": "disabled"}` rather than a body.
- Any HTTP, timeout, or malformed-response failure → same `{"available": false, "reason": "..."}` shape, never a crash, never a hang past `NASE_JEV_TIMEOUT_MS` (default 2500ms).
- `reason` distinguishes the failure kinds that need different responses: `http_error:<code>` is the API rejecting the request (a contract bug - fix the call), `timeout` is the deadline expiring, `net_error:<class>` is the connection failing. Collapsing these hides contract bugs behind what looks like a flaky network. `<class>` is an exception class name such as `ConnectionRefusedError`, never a message, so it can be matched on.
- Three more reasons mean the call was never attempted because the invocation itself is wrong, and they are fixed at the call site rather than retried: `invalid_config:<msg>` (`NASE_JEV_TIMEOUT_MS` or `NASE_JEV_EXCERPT_CHARS` is not an integer), `invalid_endpoint_scheme` (`NASE_JEV_ENDPOINT` is not http(s)), and `exception:bad_json:<msg>` (`--criteria` or `--state` is not parseable JSON). Two more are catch-alls: `invalid_response[:<msg>]` for a body that is not the documented answer shape, and `exception:<class>` (an exception class name, never a message, because a message can quote the Authorization header) for any other client-side failure. The script's module docstring is the sole enumeration, and `tests/scripts/test-jev-judge.sh` asserts every reason above appears in it.
- Success with `confidence >= 0.9` → `"usable": true`. Trust the answer and skip the point's own full judgment.
- Success with `confidence < 0.9`, or `confidence` missing → `"usable": false` with `fallback_reason` set to `low_confidence` or `missing_confidence`; still `"available": true`, but judge the point yourself using the same criteria and treat the jev answer only as a hint, never as the decision. Callers test `usable`; re-deriving the 0.9 comparison at each call site is how the threshold drifts. A call site that still compares `confidence` itself must treat a missing confidence as a fallback too - `null` is not `>= 0.9`.
- **The fallback in every case is: do exactly what the skill instructed before this script existed.** Adding a jev call must never change behavior for a user with no `TYPESAFE_API_KEY` configured.

## Config

| Env var | Default | Meaning |
|---|---|---|
| `TYPESAFE_API_KEY` | unset | presence enables Jev; absence is the normal, zero-egress state |
| `NASE_JEV=off` | unset | master kill switch, overrides key presence |
| `NASE_JEV_TIMEOUT_MS` | 2500 | per-call timeout. A healthy call measures ~1100ms, so a budget under that turns every success into a reported `timeout`. |
| `NASE_JEV_EXCERPT_CHARS` | 200 | max chars of any string sent in state/criteria (never whole files) |
| `NASE_JEV_ENDPOINT` | `https://api.typesafe.ai/v1/systemone` | override for testing |
| `NASE_JEV_TELEMETRY_FILE` | unset | append one JSON line per call (point, confidence, `usable`, fallback reason, latency, criteria hash). Off by default; a write failure never changes the answer. |

## Calling it from a skill

```bash
python3 .claude/scripts/jev-judge.py \
  --point <skill-name>.<step-name> \
  --type Choice \
  --criteria '{"label": "one-line description", ...}' \
  --state '{"finding_text": "<the bounded text being judged>"}'
```

Read the single line of JSON on stdout. `usable: false` (unavailable, low confidence, or a missing confidence) means fall back to the skill's own judgment for that point; `fallback_reason` says which case, and is worth quoting in a report when a point keeps falling back.

**Telemetry.** Set `NASE_JEV_TELEMETRY_FILE` to an absolute path to record one line per call. This workspace sets it in the git-ignored `.claude/settings.local.json` under `env`, to `<repo>/workspace/stats/jev.jsonl`. An absolute path is needed because a relative one resolves against the shell's cwd, which differs in a worktree. A line carries `point`, `type`, `available`, `confidence`, `usable`, `fallback_reason`, `latency_ms`, and `criteria_sha256` (the first 12 hex chars of the criteria JSON). It never carries state text. The hash groups call sites whose labels drifted apart; the fallback counts tell you which point is not worth keeping. After a few weeks, drop a point whose `usable` rate stays below about 60 percent. The write is best-effort and never affects the answer.

`--type` takes the capitalized spelling (`Choice` / `Score` / `Noul`); the script lowercases it on the wire, because the API pins each question schema's `type` to a lowercase const and rejects anything else with HTTP 400.

A `Noul` call must pass `--instructions` with the one-line yes/no question, worded so yes is the answer the skill acts on. Its `criteria` keys are `true` (what makes the answer yes) and `false` (what makes it no). Any other key, such as `{"yes": "..."}`, is dropped without a warning, and with no `instructions` either the call fails with HTTP 400 (`Noul question must have criteria or instructions`). The answer is a probability from 0 to 1 that the statement is true, and the API sends no confidence for it, so the script reports `max(p, 1 - p)` as the confidence. `tests/scripts/test-jev-judge.sh` fails when a call site under `.claude` names `--type Noul` without `--instructions`. Keep both flags on one line, because the guard reads one line at a time.

`--dry-run` prints the request body and exits without a key and without a network call. Use it to check a new call site's shape, and note that `tests/scripts/test-jev-judge.sh` asserts the wire casing through it.

## Which decisions may use it

Jev is for a bounded, fuzzy judgment over non-sensitive text. Three kinds of decision never go to it.

- Deterministic ones. A hash compare, a path-safety verdict, a numeric threshold, or a fixed-rule input classification is code or a written rule, and the skill applies it directly.
- Ones whose input is private. PR and review text, Slack threads, Jira and Confluence text, KB content about a repo, diffs, matched lines from a scanner, and reflection answers stay local, because `NASE_JEV_EXCERPT_CHARS` only truncates what leaves the machine and does not redact it.
- Safety gates. A model answer must not decide an `unsafe`, credential, or approval question.

A new call site must say which of these it avoids. If it cannot, do not add one.

## Surviving points

Each point is defined once, inline at its own `Try jev first (...)` call site, so there is one place to update. This table only lists them. The state for each is generic text with identifiers removed.

| Point | Where | Judgment |
|---|---|---|
| `tech-digest.relevance` | `.claude/commands/nase/tech-digest.md` | `adopt` / `watch` / `ignore` for a public news item against the matched topics |
| `extract-skills.reusable`, `.non-obvious`, `.self-contained` | `.claude/commands/nase/extract-skills.md` | three yes/no checks on a skill candidate, worded so yes means the check passes |
| `estimate-eta.lane` | `.claude/docs/eta-estimation.md` | dominant lane of a subtask |
| `estimate-eta.size` | `.claude/commands/nase/estimate-eta.md` | S to XXL bucket of a subtask |
| `doctor.probe` | `.claude/commands/nase/doctor.md` | constant-text liveness probe, only with `--deep` |

To check the list, run `grep -rn -i "try jev first" .claude workspace/skills`. A point not in the table is stale and should be removed. `workspace/skills` call sites are personal files outside this repo's CI.

## Provenance

The API shape (`POST /v1/systemone`, `{state, questions, model: "jev-latest"}`, bearer auth, `{answers: {name: {type, choice|score|noul, confidence}}}` (Noul carries no `confidence`) and the degrade philosophy come from this same product's OMC plugin integration (`docs/adr/03665-jev-degradation-contract.md`, `docs/issues/issue-3669-jev-judgment-points.md`, `src/hooks/jev/` in the `omc` marketplace plugin). nase's version drops OMC's shadow-mode, circuit-breaker, and manual-promotion machinery - that exists to earn trust across OMC's many hook-triggered calls per session; nase calls this once per named decision point per skill run, so it goes straight to active-with-confidence-gated-fallback instead.
