#!/usr/bin/env python3
"""Call TypeSafe's Jev (System One) for one bounded judgment.

Contract lives in .claude/docs/jev-judgment-points.md. A skill calls this for
a single decision point instead of reasoning it out inline. Never blocks a
skill: any failure (no key, disabled, timeout, HTTP error, bad response)
degrades to {"available": false}, and the caller falls back to judging the
point itself exactly as it did before this script existed. A low-confidence
answer (missing confidence, or confidence < 0.9) is still "available": true
but the caller should not trust it alone -- fall back to full reasoning,
optionally using the jev answer as a hint.

Usage:
  python3 .claude/scripts/jev-judge.py --point <name> --type Choice|Score|Noul \
    --criteria '{"label": "description", ...}' --state '{"...": "..."}' \
    [--instructions "extra context for the judgment"]

Output (stdout, always valid JSON, always exit 0):
  {"available": true,  "point": "<name>", "answer": <choice str | score num | noul probability 0-1>,
   "confidence": <float|null>, "usable": <bool>, "fallback_reason": <string|null>}
  {"available": false, "point": "<name>", "reason": "<one of the reasons below>",
   "usable": false, "fallback_reason": "<the reason>"}

`usable` is true only for an available answer with a confidence of at least 0.9;
anything else is a fallback, and `fallback_reason` says which (`low_confidence`,
`missing_confidence`, or the unavailable reason). Callers test `usable`, not a
hand-rolled comparison, so the threshold lives in one place.

Telemetry: set NASE_JEV_TELEMETRY_FILE=<path> to append one JSON line per call
(point, type, available, confidence, usable, fallback_reason, latency_ms, and the
question-definition hash that helps group call sites). Off by default; a telemetry
write failure never changes the answer or the exit code.

Reasons, grouped by what the caller should do about them. This list is the whole
set; `.claude/docs/jev-judgment-points.md` carries the same one.
  Configured off, no call attempted:
    no_api_key               no TYPESAFE_API_KEY in the environment
    disabled                 NASE_JEV=off, the kill switch
  The call was never made because the invocation is wrong (fix the call site):
    invalid_config:<msg>     NASE_JEV_TIMEOUT_MS / NASE_JEV_EXCERPT_CHARS not an int
    invalid_endpoint_scheme  NASE_JEV_ENDPOINT is not http(s)
    exception:bad_json:<msg> --criteria or --state is not parseable JSON
  The call was made and failed:
    http_error:<code>        the API rejected the request; a contract bug
    timeout                  the deadline expired
    net_error:<class>        the connection failed; <class> is an exception class
                             name such as ConnectionRefusedError, never a message
    invalid_response[:<msg>] the body was not the documented answer shape
    exception:<class>        any other client-side failure; <class> is an exception class
                             name, never a message, which can quote the Authorization header
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import NoReturn

DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
DEFAULT_TIMEOUT_MS = 2500
DEFAULT_EXCERPT_CHARS = 200
JEV_MODEL = "jev-latest"
CONFIDENCE_FLOOR = 0.9
_START = time.monotonic()
_POINT = ""
_TYPE = ""
_CRITERIA_SHA = ""


def bound_excerpts(value, max_chars):
    if isinstance(value, str):
        return value[:max_chars]
    if isinstance(value, list):
        return [bound_excerpts(v, max_chars) for v in value]
    if isinstance(value, dict):
        return {k: bound_excerpts(v, max_chars) for k, v in value.items()}
    return value


def _emit(payload: dict) -> None:
    """Print the answer and, when enabled, append one telemetry line.

    Telemetry is best-effort: any failure is swallowed so a full disk or a bad
    path can never turn a judgment into a crash or change the answer.
    """
    print(json.dumps(payload))
    path = os.environ.get("NASE_JEV_TELEMETRY_FILE")
    if not path:
        return
    try:
        row = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "point": payload.get("point"),
            "type": _TYPE,
            "available": payload.get("available"),
            "confidence": payload.get("confidence"),
            "usable": payload.get("usable"),
            "fallback_reason": payload.get("fallback_reason"),
            "latency_ms": int((time.monotonic() - _START) * 1000),
            "criteria_sha256": _CRITERIA_SHA,
        }
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    except Exception:  # a telemetry failure must never change the answer
        return


def unavailable(reason: str) -> NoReturn:
    _emit(
        {
            "available": False,
            "point": _POINT,
            "reason": reason,
            "usable": False,
            "fallback_reason": reason,
        }
    )
    sys.exit(0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--point", required=True)
    parser.add_argument("--type", required=True, choices=["Choice", "Score", "Noul"])
    parser.add_argument("--criteria", required=True, help="JSON object: label -> description")
    parser.add_argument("--state", required=True, help="JSON object: the bounded input to judge")
    parser.add_argument("--instructions", default=None)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the request body that would be POSTed and exit; no key needed, no network",
    )
    args = parser.parse_args()

    # The unavailable path is reached from many early returns that run before a
    # payload dict exists; these three values are the only context they share.
    global _POINT, _TYPE, _CRITERIA_SHA  # noqa: PLW0603
    _POINT, _TYPE = args.point, args.type
    _CRITERIA_SHA = hashlib.sha256(args.criteria.encode("utf-8")).hexdigest()[:12]

    if os.environ.get("NASE_JEV", "").strip().lower() == "off":
        unavailable("disabled")

    api_key = os.environ.get("TYPESAFE_API_KEY")
    if not api_key and not args.dry_run:
        unavailable("no_api_key")

    try:
        criteria = json.loads(args.criteria)
        state = json.loads(args.state)
    except json.JSONDecodeError as exc:
        unavailable(f"exception:bad_json:{exc}")

    try:
        excerpt_chars = int(os.environ.get("NASE_JEV_EXCERPT_CHARS", DEFAULT_EXCERPT_CHARS))
        timeout_ms = int(os.environ.get("NASE_JEV_TIMEOUT_MS", DEFAULT_TIMEOUT_MS))
    except ValueError as exc:
        unavailable(f"invalid_config:{exc}")
    endpoint = os.environ.get("NASE_JEV_ENDPOINT", DEFAULT_ENDPOINT)
    try:
        scheme = urllib.parse.urlparse(endpoint).scheme
    except ValueError:
        scheme = ""
    if scheme not in ("http", "https"):
        unavailable("invalid_endpoint_scheme")

    # The API's ChoiceQuestion/ScoreQuestion/NoulQuestion schemas pin "type" to the
    # lowercase const; sending the CLI's capitalized spelling is rejected with HTTP 400.
    question_def = {"type": args.type.lower(), "criteria": bound_excerpts(criteria, excerpt_chars)}
    if args.instructions:
        question_def["instructions"] = args.instructions[:excerpt_chars]

    body = json.dumps(
        {
            "state": bound_excerpts(state, excerpt_chars),
            "questions": {args.point: question_def},
            "model": JEV_MODEL,
        }
    ).encode("utf-8")

    if args.dry_run:
        print(body.decode("utf-8"))
        sys.exit(0)

    request = urllib.request.Request(  # noqa: S310 - scheme validated above
        endpoint,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout_ms / 1000) as response:  # noqa: S310 - scheme validated above
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        unavailable(f"http_error:{exc.code}")
    except TimeoutError:
        unavailable("timeout")
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError):
            unavailable("timeout")
        # The class name, not `str(reason)`, whose errno text and resolved host
        # differ between machines and so cannot be matched on downstream.
        reason = exc.reason
        name = type(reason if isinstance(reason, BaseException) else exc).__name__
        unavailable(f"net_error:{name}")
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        unavailable(f"invalid_response:{exc}")
    except Exception as exc:  # any client failure must degrade, not crash the caller
        unavailable(f"exception:{type(exc).__name__}")

    answers = payload.get("answers") if isinstance(payload, dict) else None
    if not isinstance(answers, dict) or args.point not in answers:
        unavailable("invalid_response:missing_answer")

    answer = answers[args.point]
    value_key = args.type.lower()
    if not isinstance(answer, dict) or "type" not in answer or value_key not in answer:
        unavailable("invalid_response:malformed_answer")

    value = answer.get(value_key)
    confidence = answer.get("confidence")
    if confidence is None and value_key == "noul" and isinstance(value, (int, float)):
        confidence = max(value, 1 - value)

    numeric_confidence = isinstance(confidence, (int, float)) and not isinstance(confidence, bool)
    usable = numeric_confidence and confidence >= CONFIDENCE_FLOOR
    if usable:
        fallback_reason = None
    elif numeric_confidence:
        fallback_reason = "low_confidence"
    else:
        fallback_reason = "missing_confidence"

    _emit(
        {
            "available": True,
            "point": args.point,
            "answer": value,
            "confidence": confidence,
            "usable": usable,
            "fallback_reason": fallback_reason,
        }
    )


if __name__ == "__main__":
    main()
