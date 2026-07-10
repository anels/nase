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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, type=Path, help="active effort Markdown file")
    args = parser.parse_args()

    try:
        text = args.file.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {args.file}: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(classify(text), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
