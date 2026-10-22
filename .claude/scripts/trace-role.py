#!/usr/bin/env python3
"""Pick the trace subagent role, and only from a recorded eval receipt.

`discuss-pr-analysis.md` Step 5b spawns code-trace agents. `worker` (sonnet) is the
default; `lookup` (haiku) is cheaper and faster but is not trusted until an A/B eval
shows it does not lose trace accuracy. This script is the gate: a missing, stale, or
mismatched receipt resolves to `worker`, so the default cannot drift by intuition.

Receipt: workspace/stats/skill-evals/trace-role.json
  {"schema_version": 1, "decided_at": "...", "directive_sha256": "...",
   "cases": 20, "worker_correct": 18, "lookup_correct": 18, "role": "lookup"}

Usage:
  python3 .claude/scripts/trace-role.py [--root DIR] resolve
  python3 .claude/scripts/trace-role.py [--root DIR] record --worker-correct N --lookup-correct N --cases N

`--root` is a main-parser option, so it comes before the subcommand.

`resolve` always exits 0 and prints {"role": ..., "reason": ...}; `record` exits 2 on
invalid input (fewer than 20 cases, negative counts, or more correct answers than
cases) so a bad receipt cannot be written.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn

MIN_CASES = 20
MAX_AGE_DAYS = 180
SCHEMA_VERSION = 1
RECEIPT_REL = Path("workspace/stats/skill-evals/trace-role.json")
DIRECTIVE_REL = Path(".claude/docs/pr-review-verification.md")
DIRECTIVE_HEADING = re.compile(r"^##\s+13\.", re.MULTILINE)


def directive_sha(root: Path) -> str:
    """Hash the §13 spawn directive, which is what both eval arms must share."""
    path = root / DIRECTIVE_REL
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    match = DIRECTIVE_HEADING.search(text)
    if not match:
        return ""
    return hashlib.sha256(text[match.start():].encode("utf-8")).hexdigest()


def _die(message: str) -> NoReturn:
    print(f"trace-role: {message}", file=sys.stderr)
    raise SystemExit(2)


def resolve(root: Path) -> dict[str, object]:
    path = root / RECEIPT_REL
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"role": "worker", "reason": "no-receipt"}
    except (OSError, json.JSONDecodeError):
        return {"role": "worker", "reason": "unreadable-receipt"}

    if not isinstance(receipt, dict) or receipt.get("schema_version") != SCHEMA_VERSION:
        return {"role": "worker", "reason": "wrong-schema"}
    current = directive_sha(root)
    if not current:
        return {"role": "worker", "reason": "directive-unreadable"}
    if receipt.get("directive_sha256") != current:
        return {"role": "worker", "reason": "directive-changed"}

    cases = receipt.get("cases")
    worker = receipt.get("worker_correct")
    lookup = receipt.get("lookup_correct")
    if not all(isinstance(v, int) for v in (cases, worker, lookup)) or cases < MIN_CASES:
        return {"role": "worker", "reason": "insufficient-cases"}
    if lookup < worker:
        return {"role": "worker", "reason": "lookup-lost"}

    try:
        decided = datetime.fromisoformat(str(receipt.get("decided_at", "")))
    except ValueError:
        return {"role": "worker", "reason": "bad-timestamp"}
    if decided.tzinfo is None:
        decided = decided.replace(tzinfo=timezone.utc)
    age_days = (datetime.now(timezone.utc) - decided).days
    if age_days > MAX_AGE_DAYS:
        return {"role": "worker", "reason": "receipt-stale"}

    return {"role": "lookup", "reason": "eval-passed"}


def record(root: Path, worker: int, lookup: int, cases: int) -> dict[str, object]:
    if cases < MIN_CASES:
        _die(f"need at least {MIN_CASES} cases, got {cases}")
    if min(worker, lookup) < 0 or worker > cases or lookup > cases:
        _die("correct counts must be between 0 and --cases")
    current = directive_sha(root)
    if not current:
        _die(f"cannot read the §13 directive in {DIRECTIVE_REL}")
    receipt = {
        "schema_version": SCHEMA_VERSION,
        "decided_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "directive_sha256": current,
        "cases": cases,
        "worker_correct": worker,
        "lookup_correct": lookup,
        "role": "lookup" if lookup >= worker else "worker",
    }
    path = root / RECEIPT_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[2]),
        help="nase repo root (default: the repo this script lives in)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("resolve", help="print the role the receipt allows")

    record_cmd = sub.add_parser("record", help="write an eval receipt")
    record_cmd.add_argument("--worker-correct", type=int, required=True)
    record_cmd.add_argument("--lookup-correct", type=int, required=True)
    record_cmd.add_argument("--cases", type=int, required=True)

    args = parser.parse_args(argv)
    root = Path(args.root)
    if args.command == "resolve":
        print(json.dumps(resolve(root), sort_keys=True))
        return 0
    payload = record(root, args.worker_correct, args.lookup_correct, args.cases)
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
