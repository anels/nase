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


def classify(text: str) -> dict[str, object]:
    status = frontmatter_status(text)
    checked: set[str] = set()
    evidence: list[dict[str, object]] = []
    pending_followups = 0

    for line_number, line in enumerate(text.splitlines(), 1):
        match = CHECKBOX_RE.match(line)
        if not match:
            continue
        is_checked = match.group(1).lower() == "x"
        label = match.group(2).strip()
        canonical = canonical_label(label)
        if canonical and is_checked:
            checked.add(canonical)
            evidence.append({"label": canonical, "line": line_number, "text": label})
        if not is_checked and label.lower().startswith("follow-up:"):
            pending_followups += 1

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
    if "MERGED" in delivery_pr_states:
        if jira_state == "not-done":
            return {"action": "none", "status": None, "reason": "jira-not-done"}
        deployed = any(
            evidence["label"] == "Deployed" for evidence in classification["evidence"]
        )
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
