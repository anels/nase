#!/usr/bin/env python3
"""Validate and score offline PR/review skill eval cases."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ASSERTION_TYPES = {
    "must_contain_regex",
    "must_not_contain_regex",
    "ordered_regex",
    "min_count_regex",
    "max_count_regex",
}


class EvalError(ValueError):
    """Eval set or output is invalid."""


def load_json(path: str) -> Any:
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def load_eval_set(path: str) -> dict[str, Any]:
    data = load_json(path)
    if not isinstance(data, dict):
        raise EvalError("eval set must be a JSON object")
    if data.get("schema_version") != 1:
        raise EvalError("schema_version must be 1")
    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        raise EvalError("cases must be a non-empty list")

    seen_ids: set[str] = set()
    for case in cases:
        validate_case(case, seen_ids)
    return data


def validate_case(case: dict[str, Any], seen_ids: set[str]) -> None:
    required = ("id", "skill", "prompt", "expected_output", "assertions")
    for key in required:
        if key not in case:
            raise EvalError(f"case missing key: {key}")
    case_id = str(case["id"])
    if case_id in seen_ids:
        raise EvalError(f"duplicate case id: {case_id}")
    seen_ids.add(case_id)
    if not isinstance(case["assertions"], list) or not case["assertions"]:
        raise EvalError(f"{case_id}: assertions must be a non-empty list")
    for assertion in case["assertions"]:
        validate_assertion(case_id, assertion)


def validate_assertion(case_id: str, assertion: dict[str, Any]) -> None:
    if "name" not in assertion or "type" not in assertion:
        raise EvalError(f"{case_id}: assertion needs name and type")
    assertion_type = assertion["type"]
    if assertion_type not in ASSERTION_TYPES:
        raise EvalError(f"{case_id}: unsupported assertion type {assertion_type!r}")
    if assertion_type == "ordered_regex":
        patterns = assertion.get("patterns")
        if not isinstance(patterns, list) or not patterns:
            raise EvalError(f"{case_id}: ordered_regex needs patterns")
        for pattern in patterns:
            re.compile(str(pattern), re.MULTILINE)
        return

    pattern = assertion.get("pattern")
    if not isinstance(pattern, str) or not pattern:
        raise EvalError(f"{case_id}: {assertion_type} needs pattern")
    re.compile(pattern, re.MULTILINE)
    if assertion_type in {"min_count_regex", "max_count_regex"}:
        if not isinstance(assertion.get("count"), int):
            raise EvalError(f"{case_id}: {assertion_type} needs integer count")


def find_case(eval_set: dict[str, Any], case_id: str) -> dict[str, Any]:
    for case in eval_set["cases"]:
        if str(case["id"]) == case_id:
            return case
    raise EvalError(f"case not found: {case_id}")


def score_assertion(assertion: dict[str, Any], text: str) -> dict[str, Any]:
    assertion_type = assertion["type"]
    result = {"name": assertion["name"], "type": assertion_type, "passed": False}

    if assertion_type == "must_contain_regex":
        result["passed"] = re.search(assertion["pattern"], text, re.MULTILINE) is not None
    elif assertion_type == "must_not_contain_regex":
        result["passed"] = re.search(assertion["pattern"], text, re.MULTILINE) is None
    elif assertion_type == "ordered_regex":
        cursor = 0
        matched = []
        for pattern in assertion["patterns"]:
            match = re.search(pattern, text[cursor:], re.MULTILINE)
            if not match:
                result["matched"] = matched
                return result
            matched.append(pattern)
            cursor += match.end()
        result["matched"] = matched
        result["passed"] = True
    elif assertion_type == "min_count_regex":
        count = len(re.findall(assertion["pattern"], text, re.MULTILINE))
        result["actual_count"] = count
        result["expected_count"] = assertion["count"]
        result["passed"] = count >= assertion["count"]
    elif assertion_type == "max_count_regex":
        count = len(re.findall(assertion["pattern"], text, re.MULTILINE))
        result["actual_count"] = count
        result["expected_count"] = assertion["count"]
        result["passed"] = count <= assertion["count"]

    return result


def score_case(case: dict[str, Any], output_path: str) -> dict[str, Any]:
    text = Path(output_path).read_text(encoding="utf-8")
    assertions = [score_assertion(assertion, text) for assertion in case["assertions"]]
    passed = sum(1 for assertion in assertions if assertion["passed"])
    return {
        "case_id": case["id"],
        "skill": case["skill"],
        "passed": passed,
        "total": len(assertions),
        "ok": passed == len(assertions),
        "assertions": assertions,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate", help="Validate an eval set")
    validate.add_argument("eval_set")

    score = sub.add_parser("score", help="Score one skill output file")
    score.add_argument("--eval-set", required=True)
    score.add_argument("--case", required=True)
    score.add_argument("--output", required=True)

    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        eval_set = load_eval_set(getattr(args, "eval_set", ""))
        if args.command == "validate":
            print(f"OK: {len(eval_set['cases'])} eval case(s)")
            return 0
        case = find_case(eval_set, args.case)
        result = score_case(case, args.output)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["ok"] else 1
    except (EvalError, OSError, json.JSONDecodeError, re.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
