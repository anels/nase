#!/usr/bin/env python3
"""Validate and score offline skill output eval cases."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
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
RISK_LEVELS = {"low", "medium", "high"}
ROUTING_EXPECTATIONS = {"invoke", "not_invoke"}
SKILL_NAME = re.compile(r"^nase:(?:workspace:)?[a-z0-9][a-z0-9-]*$")
RUNTIME_FILE_LIMIT = 16
RUNTIME_BYTE_LIMIT = 64 * 1024


class EvalError(ValueError):
    """Eval set or output is invalid."""


def load_json(path: str) -> Any:
    with Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def load_eval_set(path: str) -> dict[str, Any]:
    source = Path(path).resolve()
    data = load_json(str(source))
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

    represented_skills = {str(case["skill"]) for case in cases}
    routeable_skills = {
        skill for skill in represented_skills if not skill.startswith("nase:workspace:")
    }
    routing_cases = data.get("routing_cases")
    if routing_cases is not None:
        if not isinstance(routing_cases, list) or not routing_cases:
            raise EvalError("routing_cases must be a non-empty list when present")
        routing_by_skill: dict[str, set[str]] = {}
        for case in routing_cases:
            validate_routing_case(case, seen_ids, routeable_skills)
            routing_by_skill.setdefault(str(case["skill"]), set()).add(str(case["expect"]))
        for skill in sorted(routeable_skills):
            if routing_by_skill.get(skill) != ROUTING_EXPECTATIONS:
                raise EvalError(f"{skill}: routing cases need invoke and not_invoke coverage")

    runtime_cases = data.get("runtime_cases")
    if runtime_cases is not None:
        if not isinstance(runtime_cases, list) or not runtime_cases:
            raise EvalError("runtime_cases must be a non-empty list when present")
        offline = {str(case["id"]): case for case in cases}
        for case in runtime_cases:
            validate_runtime_case(case, seen_ids, offline, source)
    return data


def validate_case(case: dict[str, Any], seen_ids: set[str]) -> None:
    if not isinstance(case, dict):
        raise EvalError("each case must be an object")
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


def validate_routing_case(
    case: dict[str, Any], seen_ids: set[str], represented_skills: set[str]
) -> None:
    if not isinstance(case, dict):
        raise EvalError("each routing case must be an object")
    required = {"id", "skill", "prompt", "expect", "risk"}
    allowed = required | {"adjacent_skill"}
    missing = required - set(case)
    extra = set(case) - allowed
    if missing:
        raise EvalError(f"routing case missing keys: {', '.join(sorted(missing))}")
    if extra:
        raise EvalError(f"routing case has unsupported keys: {', '.join(sorted(extra))}")
    case_id = str(case["id"])
    if case_id in seen_ids:
        raise EvalError(f"duplicate case id: {case_id}")
    seen_ids.add(case_id)
    skill = str(case["skill"])
    if skill not in represented_skills or SKILL_NAME.fullmatch(skill) is None:
        raise EvalError(f"{case_id}: unknown skill {skill!r}")
    expectation = str(case["expect"])
    if expectation not in ROUTING_EXPECTATIONS:
        raise EvalError(f"{case_id}: invalid routing expectation {expectation!r}")
    suffix = skill.removeprefix("nase:").replace(":", "-")
    expected_id = f"routing-{suffix}-{'positive' if expectation == 'invoke' else 'near-miss'}"
    if case_id != expected_id:
        raise EvalError(f"{case_id}: expected routing id {expected_id}")
    prompt = case["prompt"]
    if not isinstance(prompt, str) or not prompt.strip():
        raise EvalError(f"{case_id}: prompt must be non-empty")
    if f"/{skill}" in prompt:
        raise EvalError(f"{case_id}: routing prompt contains target slash command")
    if not isinstance(case["risk"], str) or case["risk"] not in RISK_LEVELS:
        raise EvalError(f"{case_id}: invalid risk")
    adjacent = case.get("adjacent_skill")
    if adjacent is not None and (
        not isinstance(adjacent, str) or SKILL_NAME.fullmatch(adjacent) is None
    ):
        raise EvalError(f"{case_id}: invalid adjacent_skill")
    if adjacent == skill:
        raise EvalError(f"{case_id}: adjacent_skill must differ from skill")


def safe_relative_path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\0" in value:
        raise EvalError(f"{label} must be a non-empty relative path")
    path = Path(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise EvalError(f"{label} must not escape its root")
    return path


def command_path(repo_root: Path, skill: str) -> Path:
    suffix = skill.removeprefix("nase:")
    if suffix.startswith("workspace:"):
        return repo_root / ".claude" / "commands" / "nase" / "workspace" / f"{suffix.removeprefix('workspace:')}.md"
    return repo_root / ".claude" / "commands" / "nase" / f"{suffix}.md"


def source_paths(repo_root: Path) -> list[Path]:
    try:
        completed = subprocess.run(
            [
                "git",
                "-C",
                str(repo_root),
                "ls-files",
                "-t",
                "--cached",
                "--deleted",
                "--others",
                "--exclude-standard",
                "-z",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise EvalError("cannot enumerate repository sources for canary isolation") from exc
    paths: list[Path] = []
    deleted: set[Path] = set()
    for item in completed.stdout.split(b"\0"):
        if not item:
            continue
        try:
            tag, value = item.split(b" ", 1)
        except ValueError as exc:
            raise EvalError("cannot parse repository sources for canary isolation") from exc
        path = repo_root / os.fsdecode(value)
        if tag == b"R":
            deleted.add(path)
        else:
            paths.append(path)
    return [path for path in paths if path not in deleted]


def validate_runtime_case(
    case: dict[str, Any],
    seen_ids: set[str],
    offline_cases: dict[str, dict[str, Any]],
    eval_source: Path,
) -> None:
    if not isinstance(case, dict):
        raise EvalError("each runtime case must be an object")
    required = {
        "id",
        "skill",
        "score_case",
        "prompt",
        "fixture_dir",
        "required_reads",
        "required_canaries",
        "risk",
    }
    missing = required - set(case)
    extra = set(case) - required
    if missing:
        raise EvalError(f"runtime case missing keys: {', '.join(sorted(missing))}")
    if extra:
        raise EvalError(f"runtime case has unsupported keys: {', '.join(sorted(extra))}")
    case_id = str(case["id"])
    if case_id in seen_ids:
        raise EvalError(f"duplicate case id: {case_id}")
    seen_ids.add(case_id)
    skill = str(case["skill"])
    if SKILL_NAME.fullmatch(skill) is None:
        raise EvalError(f"{case_id}: invalid skill")
    score_case_id = str(case["score_case"])
    score_case = offline_cases.get(score_case_id)
    if score_case is None:
        raise EvalError(f"{case_id}: score_case not found: {score_case_id}")
    if score_case["skill"] != skill:
        raise EvalError(f"{case_id}: score_case skill differs")
    prompt = case["prompt"]
    if not isinstance(prompt, str) or not prompt.strip():
        raise EvalError(f"{case_id}: prompt must be non-empty")
    if not isinstance(case["risk"], str) or case["risk"] not in RISK_LEVELS:
        raise EvalError(f"{case_id}: invalid risk")

    fixture_rel = safe_relative_path(case["fixture_dir"], f"{case_id}.fixture_dir")
    fixture = eval_source.parent / fixture_rel
    if fixture.is_symlink() or not fixture.is_dir():
        raise EvalError(f"{case_id}: fixture_dir must be a real directory")
    files: list[Path] = []
    total_bytes = 0
    for path in fixture.rglob("*"):
        if path.is_symlink():
            raise EvalError(f"{case_id}: fixture contains a symlink")
        if path.is_file():
            files.append(path)
            total_bytes += path.stat().st_size
    if len(files) > RUNTIME_FILE_LIMIT or total_bytes > RUNTIME_BYTE_LIMIT:
        raise EvalError(f"{case_id}: fixture exceeds file or byte limit")

    reads = case["required_reads"]
    if not isinstance(reads, list) or not reads:
        raise EvalError(f"{case_id}: required_reads must be non-empty")
    normalized_reads: set[str] = set()
    for item in reads:
        rel = safe_relative_path(item, f"{case_id}.required_reads")
        if rel.as_posix() in normalized_reads:
            raise EvalError(f"{case_id}: duplicate required read")
        normalized_reads.add(rel.as_posix())
        target = fixture / rel
        if target.is_symlink() or not target.is_file():
            raise EvalError(f"{case_id}: required read does not name a fixture file")

    canaries = case["required_canaries"]
    if not isinstance(canaries, list) or not canaries or any(not isinstance(item, str) for item in canaries):
        raise EvalError(f"{case_id}: required_canaries must be a unique non-empty list")
    if len(set(canaries)) != len(canaries):
        raise EvalError(f"{case_id}: required_canaries must be a unique non-empty list")
    fixture_bytes = b"\n".join(path.read_bytes() for path in files)
    repo_root = Path(__file__).resolve().parents[2]
    excluded = {eval_source.resolve(), *(path.resolve() for path in files)}
    other_sources = [path for path in source_paths(repo_root) if path.resolve() not in excluded]
    for canary in canaries:
        if not 8 <= len(canary) <= 128:
            raise EvalError(f"{case_id}: invalid canary")
        encoded = canary.encode("utf-8")
        if encoded not in fixture_bytes:
            raise EvalError(f"{case_id}: canary is absent from fixture")
        if canary in prompt:
            raise EvalError(f"{case_id}: canary leaks into prompt")
        for path in other_sources:
            try:
                if encoded in path.read_bytes():
                    raise EvalError(f"{case_id}: canary occurs outside its fixture")
            except OSError as exc:
                raise EvalError(f"{case_id}: cannot prove canary isolation for {path.name}") from exc


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


def find_routing_case(eval_set: dict[str, Any], case_id: str) -> dict[str, Any]:
    for case in eval_set.get("routing_cases", []):
        if str(case["id"]) == case_id:
            return case
    raise EvalError(f"routing case not found: {case_id}")


def find_runtime_case(eval_set: dict[str, Any], case_id: str) -> dict[str, Any]:
    for case in eval_set.get("runtime_cases", []):
        if str(case["id"]) == case_id:
            return case
    raise EvalError(f"runtime case not found: {case_id}")


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
