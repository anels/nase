from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from nase_fs import lock_exclusive
from nase_time import utc_now_iso

from .base import sha256
from .payload import external_action_dir


def ledger_path(root: Path) -> Path:
    return root / "workspace" / "logs" / ".external-writes.jsonl"


def record_outcome(
    root: Path,
    manifest_path: Path,
    action: dict[str, Any],
    exit_code: int | None,
    outcome: str,
) -> None:
    """Append one outcome row; the mutation already ran, so a failure only warns."""
    row = {
        "ts": utc_now_iso(),
        "manifest": manifest_path.name,
        "action_sha256": sha256(action),
        "system": action.get("system"),
        "summary": action.get("summary"),
        "exit": exit_code,
        "outcome": outcome,
    }
    path = ledger_path(root)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path.with_name(f"{path.name}.lock"), "a") as lock:
            lock_exclusive(lock)
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as ledger:
                ledger.write(json.dumps(row, sort_keys=True) + "\n")
    except OSError as exc:
        print(f"WARNING: could not record outcome ledger row: {exc}", file=sys.stderr)


def cmd_audit(args: argparse.Namespace) -> int:
    manifests = {path.name for path in external_action_dir(args.root).glob("*.json")}
    ledger_names: set[str] = set()
    outcomes: list[str] = []
    malformed = 0
    try:
        lines = ledger_path(args.root).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        try:
            row = json.loads(line)
            name, outcome = row["manifest"], row["outcome"]
            if not isinstance(name, str) or not isinstance(outcome, str):
                raise TypeError("ledger row fields must be strings")
        except (json.JSONDecodeError, KeyError, TypeError):
            malformed += 1
            continue
        ledger_names.add(name)
        outcomes.append(outcome)
    print(
        json.dumps(
            {
                "prepared": len(manifests),
                "executed": sum(1 for o in outcomes if o in ("ok", "failed")),
                "unknown_outcome": outcomes.count("unknown"),
                "not_launched": outcomes.count("not-launched"),
                "prepared_not_executed": len(manifests - ledger_names),
                "ledger_without_manifest": len(ledger_names - manifests),
                "malformed_ledger_lines": malformed,
            },
            sort_keys=True,
        )
    )
    return 0
