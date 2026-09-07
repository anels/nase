#!/usr/bin/env python3
"""Verify `workspace/tasks/todo.md` and `workspace/efforts/` agree in both directions.

`.claude/commands/nase/kb-review.md` states the contract this enforces: todo.md carries
"no checked or dropped items, no duplicate initiative state, and no unresolved effort
pointer". Until this gate existed the contract was prompt-only, and it drifted: on
2026-09-06 todo.md held 17 open pointers to efforts that had already reached a terminal
directory, and omitted 5 active efforts including one `in-progress`. Neither direction is
visible to any other check - `effort-state.py`, `effort-pr-sweep.py`, `kb-hygiene-scan.py`,
`workspace-quality-scan.py` and `workspace-data-scan.py` all read effort files without ever
asking whether the queue points at them.

Three assertions, each catching a drift the others cannot see:

  A. Every `workspace/efforts/<slug>.md` pointer in todo.md resolves at that exact path.
     Catches a close that moved the file to `done/` or `archive/<year>/` without sweeping
     the queue. This is the direction that produces phantom open work.

  B. Every active effort - a file living directly in `workspace/efforts/` - is pointed at
     by todo.md. Catches the opposite failure: a live effort that never entered the queue,
     or that fell out of it when a parent closed. This is the direction that loses work
     silently, so it is the more dangerous of the two.

  C. todo.md carries no `- [x]` items. The contract sends closed work to an effort doc or
     to a cleanup file under `workspace/tasks/archive/`, not to a checkbox left ticked.

Assertion B keys on **location**, not on `status:`, because location is what
*Terminal Destination* in `.claude/docs/effort-model.md` makes authoritative. A root
file whose `status:` is already terminal is therefore reported as its own finding rather
than being silently exempted from B - otherwise this gate would demand a queue pointer for
an effort that should have been moved out.

`workspace/` is git-ignored, so CI has no copy. Absence is a skip, never a failure.

Run from repo root:  python3 .claude/scripts/check-effort-pointer-integrity.py
Exit 0 = both directions reconcile (or workspace absent), exit 1 = at least one drift.
"""

import re
import sys
from pathlib import Path

TERMINAL_STATUSES = {"completed", "wontfix"}

# `- [ ] ... -> `workspace/efforts/<slug>.md`` - the arrow form todo.md uses. Matched
# anywhere on the line because entries carry prose on both sides of the pointer.
POINTER_RE = re.compile(r"workspace/efforts/(?P<rest>[A-Za-z0-9._/-]+\.md)")
CHECKED_RE = re.compile(r"^\s*-\s*\[x\]\s", re.IGNORECASE)
STATUS_RE = re.compile(r"^status:\s*(\S+)\s*$", re.MULTILINE)


def read_status(path: Path) -> str:
    """Frontmatter `status:` value, or "" when the file has no readable frontmatter."""
    try:
        head = path.read_text(encoding="utf-8", errors="replace")[:2048]
    except OSError:
        return ""
    if not head.startswith("---"):
        return ""
    end = head.find("\n---", 3)
    block = head[3:end] if end != -1 else head
    match = STATUS_RE.search(block)
    return match.group(1) if match else ""


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    todo = root / "workspace/tasks/todo.md"
    efforts = root / "workspace/efforts"

    if not todo.is_file() or not efforts.is_dir():
        print(
            "SKIP  effort-pointer integrity: workspace/tasks/todo.md or "
            "workspace/efforts/ not present (workspace/ is git-ignored)"
        )
        return 0

    lines = todo.read_text(encoding="utf-8").splitlines()

    # Pointer -> first line number, so a finding can name a location.
    pointed: dict[str, int] = {}
    checked: list[tuple[int, str]] = []
    for lineno, line in enumerate(lines, start=1):
        if CHECKED_RE.match(line):
            checked.append((lineno, line.strip()))
        for match in POINTER_RE.finditer(line):
            pointed.setdefault(match.group("rest"), lineno)

    failures: list[str] = []

    # --- A. every pointer resolves --------------------------------------------------
    unresolved = []
    for rest, lineno in sorted(pointed.items()):
        if not (efforts / rest).is_file():
            landed = sorted(
                p.relative_to(efforts).as_posix()
                for p in efforts.rglob(Path(rest).name)
            )
            where = f" (now at {', '.join(landed)})" if landed else " (not found anywhere)"
            unresolved.append(f"todo.md:{lineno} -> workspace/efforts/{rest}{where}")
    if unresolved:
        failures.append(
            f"{len(unresolved)} todo.md pointer(s) do not resolve; close the queue entry "
            f"or restore the effort:\n    " + "\n    ".join(unresolved)
        )

    # --- B. every active effort is pointed at ---------------------------------------
    # and the terminal-status-at-root case reported separately (see module docstring).
    active_unlisted = []
    terminal_at_root = []
    for path in sorted(efforts.glob("*.md")):
        name = path.name
        status = read_status(path)
        if status in TERMINAL_STATUSES:
            terminal_at_root.append(f"workspace/efforts/{name} (status: {status})")
            continue
        if name not in pointed:
            label = status or "no status:"
            active_unlisted.append(f"workspace/efforts/{name} ({label})")
    if active_unlisted:
        failures.append(
            f"{len(active_unlisted)} active effort(s) have no todo.md pointer; work that is "
            f"live but invisible to the queue:\n    " + "\n    ".join(active_unlisted)
        )
    if terminal_at_root:
        failures.append(
            f"{len(terminal_at_root)} effort(s) carry a terminal status while still living "
            f"directly in workspace/efforts/; move them to the destination "
            f"effort-state.py reports:\n    " + "\n    ".join(terminal_at_root)
        )

    # --- C. no checked items --------------------------------------------------------
    if checked:
        shown = [f"todo.md:{n}  {t[:100]}" for n, t in checked]
        failures.append(
            f"{len(checked)} checked item(s) in todo.md; the contract keeps closed work in "
            f"the effort doc or a workspace/tasks/archive/ cleanup file:\n    "
            + "\n    ".join(shown)
        )

    active_count = len(list(efforts.glob("*.md")))
    if failures:
        for finding in failures:
            print(f"FAIL  {finding}", file=sys.stderr)
        print(f"\n{len(failures)} failure(s)", file=sys.stderr)
        return 1

    print(
        f"PASS  effort-pointer integrity: {len(pointed)} pointer(s) resolve, "
        f"{active_count} active effort(s) listed, 0 checked items"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
