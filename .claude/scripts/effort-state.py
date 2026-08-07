#!/usr/bin/env python3
"""Classify one active effort file with the shared lifecycle contract."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


STAGE_DISPLAY = {
    "planning": "Planning",
    "implementing": "Implementing",
    "in_review": "In review",
    "awaiting_deploy": "Awaiting deploy",
    "follow_up_only": "Follow-up only",
}

CHECKBOX_RE = re.compile(r"^\s*-\s*\[([ xX])\]\s+(.+?)\s*$")
PR_REFERENCE_RE = re.compile(
    r"https://github\.com/[^/\s]+/[^/\s]+/pull/\d+|\b[^/\s]+/[^#\s]+#\d+"
)
TARGET_PR_COUNT_RE = re.compile(
    r"(?i)(?:\*\*)?Target PR count(?:\*\*)?\s*:\s*(\d+)\b"
)
LIFECYCLE_HEADING_RE = re.compile(r"^(#{2,6})\s+Lifecycle\s*$", re.IGNORECASE)
HEADING_RE = re.compile(r"^(#{1,6})\s+\S")

# An unchecked row inside ## Lifecycle usually means "this deliverable is still
# owed". These status/bookkeeping rows do not describe another delivery PR, so
# they must not block the transition to `awaiting-deploy`.
#
# Anchored at the start of the row on purpose: matching these words anywhere would
# swallow real deliverables whose prose happens to contain them - "revert the
# CI-verified-only exclusion" names an unopened PR, not a completed verification.
BENIGN_LIFECYCLE_RE = re.compile(
    r"""(?ix)
    ^(?:
        deployed\b                        # Deployed / Deployed to alpha / Deployed (if applicable)
      | merged\b                          # merged-but-unticked is drift, not undelivered work
      | review\s+passed\b
      | effort\s+doc\s+moved\b
    )
    """
)

# These rows also do not represent another delivery PR, but once `Deployed` is
# checked they must remain visible so the effort cannot move to `completed`
# before its post-deploy validation is checked off.
POST_DEPLOY_LIFECYCLE_RE = re.compile(
    r"""(?ix)
    ^(?:
        outcome\s*:
      | verified\b
      | validated\b
      | verification\s+(?:complete|completed|passed)\b
      | validation\s+(?:complete|completed|passed)\b
      | post-?deploy\b
      | (?:alpha|beta|staging|prod(?:uction)?|sc\d+)\s+validation\s+(?:complete|completed|passed)\b
      | (?:(?:alpha|beta|staging|prod(?:uction)?|sc\d+)\s+)?(?:deploy|soak|bake)\s+(?:window|observation|verification)\b
    )
    """
)

# Authors of multi-PR efforts often record the outstanding PRs as a trailing
# clause on the *checked* `PR opened` row ("PR-1 #173 (draft); PR-1b + PR-2 still
# pending") instead of giving each one its own row. The row is checked, so the
# unchecked-row scan cannot see it, yet it says plainly that delivery is partial.
OUTSTANDING_CLAUSE_RE = re.compile(
    r"(?i)\b(?:still\s+pending|not\s+(?:yet\s+)?started|remain(?:s|ing)?\s+pending|yet\s+to\s+be\s+opened)\b"
)


def frontmatter_status(text: str) -> str:
    match = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    if not match:
        return ""
    for line in match.group(1).splitlines():
        status = re.match(r"^status:\s*(.+?)\s*$", line, re.IGNORECASE)
        if status:
            return status.group(1).strip().strip('"\'').lower()
    return ""


def canonical_label(label: str) -> str | None:
    lowered = label.strip().lower()
    if lowered.startswith("implementation started"):
        return "Implementation started"
    if lowered.startswith("pr opened"):
        return "PR opened"
    if lowered.startswith("merged"):
        return "Merged"
    if lowered.startswith("deployed"):
        return "Deployed"
    return None


def stage_from_status(status: str, text: str) -> str:
    if status in {"proposed", "planned", "tracked"}:
        return "planning"
    if status in {"in-progress", "needs-revision", "blocked"}:
        return "implementing"
    if status in {"in-review", "merge-ready", "ready"}:
        return "in_review"
    if status in {"merged", "awaiting-deploy"}:
        return "awaiting_deploy"
    if PR_REFERENCE_RE.search(text):
        return "in_review"
    return "planning"


def lifecycle_line_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """1-indexed [start, end) spans of every `## Lifecycle` section."""
    ranges: list[tuple[int, int]] = []
    for index, line in enumerate(lines, 1):
        match = LIFECYCLE_HEADING_RE.match(line)
        if not match:
            continue
        start = index + 1
        lifecycle_level = len(match.group(1))
        end = len(lines) + 1
        for next_index in range(start, len(lines) + 1):
            heading = HEADING_RE.match(lines[next_index - 1])
            if heading and len(heading.group(1)) <= lifecycle_level:
                end = next_index
                break
        ranges.append((start, end))
    return ranges


def strip_emphasis(label: str) -> str:
    return label.lstrip("*_ ").strip()


def classify(text: str) -> dict[str, object]:
    status = frontmatter_status(text)
    checked: set[str] = set()
    evidence: list[dict[str, object]] = []
    undelivered: list[dict[str, object]] = []
    pending_postdeploy_validation: list[dict[str, object]] = []
    pending_followups = 0

    lines = text.splitlines()
    lifecycle_ranges = lifecycle_line_ranges(lines)
    target_pr_counts = [
        {"count": int(match.group(1)), "line": line_number, "text": line.strip()}
        for line_number, line in enumerate(lines, 1)
        if (match := TARGET_PR_COUNT_RE.search(line))
    ]

    for line_number, line in enumerate(lines, 1):
        match = CHECKBOX_RE.match(line)
        if not match:
            continue
        is_checked = match.group(1).lower() == "x"
        label = match.group(2).strip()
        canonical = canonical_label(label)
        if canonical and is_checked:
            checked.add(canonical)
            evidence.append({"label": canonical, "line": line_number, "text": label})
            if canonical in {"PR opened", "Merged"} and OUTSTANDING_CLAUSE_RE.search(label):
                undelivered.append({"line": line_number, "text": label})
        if not is_checked and label.lower().startswith("follow-up:"):
            pending_followups += 1
        in_lifecycle = any(
            start <= line_number < end for start, end in lifecycle_ranges
        )
        if not is_checked and in_lifecycle and not label.lower().startswith("follow-up:"):
            plain_label = strip_emphasis(label)
            if POST_DEPLOY_LIFECYCLE_RE.search(plain_label):
                pending_postdeploy_validation.append(
                    {"line": line_number, "text": label}
                )
            # An unchecked, non-benign row inside `## Lifecycle` is the author
            # saying "there is still a deliverable owed here". Later PRs in a
            # multi-PR plan have no delivery-PR entry to be seen by, so this row
            # is the only signal that the effort is not actually deployable yet.
            elif not BENIGN_LIFECYCLE_RE.search(plain_label):
                undelivered.append({"line": line_number, "text": label})

    if "Deployed" in checked and pending_followups:
        stage = "follow_up_only"
    elif "Merged" in checked:
        stage = "awaiting_deploy"
    elif "PR opened" in checked:
        stage = "in_review"
    elif "Implementation started" in checked:
        stage = "implementing"
    else:
        stage = stage_from_status(status, text)

    method = "lifecycle" if evidence else "frontmatter"
    status_stage = stage_from_status(status, text) if status else None
    compatible_statuses = {"follow_up_only": {"awaiting_deploy", "follow_up_only"}}
    expected_stages = compatible_statuses.get(stage, {stage})
    needs_live_verification = bool(
        evidence and status_stage is not None and status_stage not in expected_stages
    )

    return {
        "stage": stage,
        "display_stage": STAGE_DISPLAY[stage],
        "method": method,
        "status": status or None,
        "evidence": evidence,
        "pending_followups": pending_followups,
        "needs_live_verification": needs_live_verification,
        "undelivered": undelivered,
        "pending_postdeploy_validation": pending_postdeploy_validation,
        "target_pr_counts": target_pr_counts,
    }


def transition(
    classification: dict[str, object],
    delivery_pr_states: list[str],
    jira_state: str,
    blocked_by_unresolved: bool,
) -> dict[str, object]:
    if not delivery_pr_states:
        return {"action": "none", "status": None, "reason": "no-delivery-pr"}
    if "UNREADABLE" in delivery_pr_states:
        return {"action": "none", "status": None, "reason": "unreadable-delivery-pr"}
    if jira_state == "unreadable":
        return {"action": "none", "status": None, "reason": "unreadable-jira"}
    if blocked_by_unresolved:
        return {"action": "none", "status": None, "reason": "unresolved-blocker"}
    if "OPEN" in delivery_pr_states:
        return {"action": "none", "status": None, "reason": "open-delivery-pr"}
    # A multi-PR effort whose first PR merged is not deployable: the PRs nobody has
    # opened yet cannot appear in delivery_pr_states, so the states alone read as
    # "everything shipped" and would archive live work. This sits ahead of both
    # terminal paths on purpose — a plan whose first PR was *closed* is no more
    # `wontfix` than one whose first PR merged is `awaiting-deploy`. Name the rows
    # that held it, so a stale row gets fixed instead of silently suppressing every
    # future transition.
    undelivered = list(classification.get("undelivered") or [])
    target_pr_counts = classification.get("target_pr_counts") or []
    expected_pr_count = max(
        (entry["count"] for entry in target_pr_counts),
        default=0,
    )
    if expected_pr_count > len(delivery_pr_states):
        undelivered.extend(
            {"line": entry["line"], "text": entry["text"]}
            for entry in target_pr_counts
            if entry["count"] == expected_pr_count
        )
    if undelivered:
        return {
            "action": "none",
            "status": None,
            "reason": "undelivered-lifecycle-rows",
            "undelivered": undelivered,
        }
    if "MERGED" in delivery_pr_states:
        if jira_state == "not-done":
            return {"action": "none", "status": None, "reason": "jira-not-done"}
        deployed = any(
            evidence["label"] == "Deployed" for evidence in classification["evidence"]
        )
        if deployed and classification["pending_postdeploy_validation"]:
            if classification["status"] == "awaiting-deploy":
                return {
                    "action": "none",
                    "status": None,
                    "reason": "pending-postdeploy-validation",
                }
            return {
                "action": "update",
                "status": "awaiting-deploy",
                "reason": "pending-postdeploy-validation",
            }
        if deployed and classification["pending_followups"] == 0:
            return {"action": "move", "status": "completed", "reason": "deployed"}
        if classification["status"] == "awaiting-deploy":
            return {
                "action": "none",
                "status": None,
                "reason": "already-awaiting-deploy",
            }
        return {
            "action": "update",
            "status": "awaiting-deploy",
            "reason": "merged-awaiting-deploy",
        }
    return {"action": "move", "status": "wontfix", "reason": "all-delivery-prs-closed"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, type=Path, help="active effort Markdown file")
    parser.add_argument(
        "--delivery-pr-state",
        action="append",
        default=[],
        choices=("OPEN", "MERGED", "CLOSED", "UNREADABLE"),
        help="live state for one structured delivery PR; repeat for multiple PRs",
    )
    parser.add_argument(
        "--jira-state",
        default="untracked",
        choices=("untracked", "done", "not-done", "unreadable"),
        help="live state for the tracked Jira issue",
    )
    parser.add_argument(
        "--blocked-by-unresolved",
        action="store_true",
        help="prevent lifecycle mutation while any blocker remains unresolved",
    )
    parser.add_argument(
        "--evaluate-transition",
        action="store_true",
        help="include the deterministic lifecycle transition decision",
    )
    args = parser.parse_args()

    try:
        text = args.file.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {args.file}: {exc}", file=sys.stderr)
        return 2

    result = classify(text)
    if args.evaluate_transition:
        result["transition"] = transition(
            result,
            args.delivery_pr_state,
            args.jira_state,
            args.blocked_by_unresolved,
        )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
