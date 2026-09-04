#!/usr/bin/env python3
"""Enforce `workspace/context.md -> Workspace Boundary Policy` over tracked files.

The policy keeps internal identifiers and vendor tech names out of everything the
`nase` repo ships. It used to be prompt-only, which is the failure mode
`CLAUDE.md -> Architecture Stance` warns about: a leak sat in a tracked shared doc
until someone read the file by hand.

Term list: `workspace/boundary-terms.txt` (git-ignored, so the terms never ship).
Absent list -> skip with a notice, because a fresh clone has no `workspace/`.

Findings print `path:line` plus a redacted term fingerprint. The matched text is
never rendered: this gate runs in CI on a public repo, so printing the term would
publish the thing the policy protects.

Exit 0 = clean or skipped, 1 = at least one violation, 2 = malformed term list.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

TERMS_FILE = Path("workspace/boundary-terms.txt")

# The regression test points this at a throwaway git repo. Without it the gate
# would only be exercisable against the real tree, which cannot host a probe
# that must fail.
SCAN_ROOT_ENV = "NASE_BOUNDARY_SCAN_ROOT"

# Tracked paths that may carry a term. Each entry needs a reason; an unreasoned
# entry is how a gate quietly stops gating.
ALLOWLIST: dict[str, str] = {
    ".claude/scripts/check-boundary-terms.py": "gate implementation",
    "tests/check-boundary-terms.sh": "gate wrapper",
    "tests/scripts/test-boundary-terms.sh": "gate regression test",
}

# Binary and font extensions carry no reviewable prose.
SKIP_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf",
    ".zip", ".7z", ".gz", ".woff", ".woff2", ".ttf", ".otf",
}


def load_terms(path: Path) -> tuple[list[str], dict[str, int]]:
    """Return (exempt phrases, {term: tier}) from the term list."""
    exempt: list[str] = []
    tiers: dict[str, int] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or parts[0] not in {"0", "1", "2"} or not parts[1].strip():
            print(
                f"FAIL: {path}:{lineno} is malformed; expected '<tier 0|1|2><TAB><term>'.",
                file=sys.stderr,
            )
            raise SystemExit(2)
        tier, term = int(parts[0]), parts[1].strip()
        if tier == 0:
            exempt.append(term)
        else:
            tiers[term] = tier
    if not tiers:
        print(f"FAIL: {path} declares no tier 1 or tier 2 terms.", file=sys.stderr)
        raise SystemExit(2)
    return exempt, tiers


def build_pattern(terms: list[str]) -> re.Pattern[str] | None:
    """Case-sensitive whole-word alternation, longest term first."""
    if not terms:
        return None
    alts = []
    for term in sorted(set(terms), key=len, reverse=True):
        # `\b` is wrong for terms containing `.` or `/`, so bound on non-word
        # characters only where the term's own edge is a word character.
        left = r"(?<![0-9A-Za-z_])" if term[0].isalnum() or term[0] == "_" else ""
        right = r"(?![0-9A-Za-z_])" if term[-1].isalnum() or term[-1] == "_" else ""
        alts.append(f"{left}{re.escape(term)}{right}")
    return re.compile("|".join(alts))


def fingerprint(term: str) -> str:
    """Identify a term to its author without printing it."""
    return f"{term[0]}{'*' * (len(term) - 1)} (len {len(term)})"


def exempt_spans(line: str, pattern: re.Pattern[str] | None) -> list[tuple[int, int]]:
    if pattern is None:
        return []
    return [m.span() for m in pattern.finditer(line)]


def inside(span: tuple[int, int], spans: list[tuple[int, int]]) -> bool:
    return any(start <= span[0] and span[1] <= end for start, end in spans)


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, text=True, check=True
    ).stdout
    return [f for f in out.split("\0") if f]


def main() -> int:
    scan_root = os.environ.get(SCAN_ROOT_ENV)
    if scan_root:
        os.chdir(scan_root)

    if not TERMS_FILE.exists():
        print(
            f"SKIP: {TERMS_FILE} is absent (workspace/ is git-ignored); "
            "boundary terms not checked."
        )
        return 0

    exempt, tiers = load_terms(TERMS_FILE)
    exempt_pattern = build_pattern(exempt)
    term_pattern = build_pattern(list(tiers))
    assert term_pattern is not None  # load_terms rejects an empty term set

    files = tracked_files()
    findings: list[str] = []
    for rel in files:
        if rel in ALLOWLIST or Path(rel).suffix.lower() in SKIP_SUFFIXES:
            continue
        path = Path(rel)
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            skip = exempt_spans(line, exempt_pattern)
            for match in term_pattern.finditer(line):
                if inside(match.span(), skip):
                    continue
                term = match.group(0)
                findings.append(
                    f"{rel}:{lineno}: tier {tiers[term]} boundary term "
                    f"{fingerprint(term)}"
                )

    if findings:
        print(
            "FAIL: tracked files carry boundary terms "
            "(workspace/context.md -> Workspace Boundary Policy).",
            file=sys.stderr,
        )
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        print(
            f"\n{len(findings)} finding(s). Replace each with a generic placeholder. "
            "Terms are redacted above on purpose; read workspace/boundary-terms.txt "
            "for the list and the tier meanings.",
            file=sys.stderr,
        )
        return 1

    print(f"OK: {len(files)} tracked files carry no boundary terms.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
