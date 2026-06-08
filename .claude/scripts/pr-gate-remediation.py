#!/usr/bin/env python3
"""Classify known PR gate failures into mechanical remediation recipes."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Recipe:
    recipe: str
    patterns: tuple[str, ...]
    action: str
    mutation_owner: str
    requires_user: bool = False


RECIPES = (
    Recipe(
        recipe="commitlint",
        patterns=("commit lint", "commitlint"),
        action=(
            "Pull failed-run log to identify the offending commit subject. "
            "If already pushed, do not add a follow-up commit; hand off to "
            "/nase:prep-merge or /nase:improve-commit-message with force-push confirmation."
        ),
        mutation_owner="commit-push-pattern",
        requires_user=True,
    ),
    Recipe(
        recipe="pr-description",
        patterns=("pr description check", "pr-description-check"),
        action="Refresh PR body sections from implementation summary and verification evidence.",
        mutation_owner="address-comments Phase 8b",
    ),
    Recipe(
        recipe="pr-size",
        patterns=("pr size check", "pr-size-check"),
        action="Fill `## How to Review` from changed file list and per-file intent.",
        mutation_owner="address-comments Phase 8b",
    ),
    Recipe(
        recipe="jira-key",
        patterns=("check for jira issue key", "checkjiraissuekey"),
        action="Ask for Jira key, then update PR title through the PR metadata mutation gate.",
        mutation_owner="address-comments Phase 8b",
        requires_user=True,
    ),
    Recipe(
        recipe="ef-migration",
        patterns=("ef migration checker", "migration drift"),
        action="Read bot drift comment, add missing migration, rerun verification, then re-enter commit/push.",
        mutation_owner="address-comments Phase 8",
    ),
    Recipe(
        recipe="super-linter",
        patterns=("lint code base", "super-linter"),
        action="If advisory, log and skip. Otherwise pull bot auto-commit with `git pull --ff-only`.",
        mutation_owner="none",
    ),
)


def normalize(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def classify(name: str) -> dict[str, object]:
    normalized = normalize(name)
    for recipe in RECIPES:
        if any(normalize(pattern) in normalized for pattern in recipe.patterns):
            return {
                "recipe": recipe.recipe,
                "action": recipe.action,
                "mutation_owner": recipe.mutation_owner,
                "requires_user": recipe.requires_user,
            }
    return {
        "recipe": "unknown",
        "action": "Fetch failed-run log, summarize in 3 lines, then ask whether to fix, skip, or show full log.",
        "mutation_owner": "manual",
        "requires_user": True,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    classify_parser = sub.add_parser("classify", help="Classify a PR gate name.")
    classify_parser.add_argument("--name", required=True)
    classify_parser.set_defaults(func=lambda args: classify(args.name))
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    print(json.dumps(args.func(args), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
