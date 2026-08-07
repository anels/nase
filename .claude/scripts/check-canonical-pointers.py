#!/usr/bin/env python3
"""Fail when a skill rewords or duplicates a canonical shared-doc pointer.

Canonical wording is declared in the source doc inside a
`<canonical-block name="...">` section; every consuming skill must carry the
pointer body verbatim. See `.claude/docs/language-config.md → Canonical pointer`.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SOURCE_DOC = Path(".claude/docs/language-config.md")
BLOCK_NAME = "language-preflight"

# Inline restatements of the preflight rules: a second copy that drifts.
RESTATEMENTS = (
    "`workspace/config.md` → `## Language`",
    "`workspace/config.md` `## Language`",
    "`workspace/config.md` for `conversation:`",
    "workspace/config.md -> ## Language",
)


def canonical_pointer(text: str) -> str | None:
    match = re.search(
        rf'<canonical-block name="{BLOCK_NAME}">\n(.*?)\n</canonical-block>',
        text,
        re.DOTALL,
    )
    return match.group(1).strip() if match else None


def targets(root: Path) -> list[Path]:
    found = sorted((root / ".claude/commands/nase").glob("*.md"))
    workspace_skills = root / "workspace/skills"
    if workspace_skills.is_dir():
        found += sorted(workspace_skills.glob("*.md"))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=".",
        help="Repo root to scan (default: current directory).",
    )
    args = parser.parse_args()
    root = Path(args.root)
    source_doc = root / SOURCE_DOC

    if not source_doc.is_file():
        print(f"MISSING_SOURCE {source_doc}", file=sys.stderr)
        return 1

    canonical = canonical_pointer(source_doc.read_text(encoding="utf-8"))
    if canonical is None:
        print(
            f'NO_CANONICAL_BLOCK {source_doc}: expected a <canonical-block '
            f'name="{BLOCK_NAME}"> section under ## Canonical pointer',
            file=sys.stderr,
        )
        return 1

    # A leading verb or a `**Step 0 …:**` label may precede the pointer; the
    # pointer body itself never varies.
    body = canonical.rstrip(".")
    if "`" in body:
        body = body[body.index("`"):]

    failures: list[str] = []
    for path in targets(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        if body not in text:
            failures.append(
                f"DRIFT    {path}: language preflight pointer is missing or "
                f"reworded. Use the canonical spelling verbatim: {canonical}"
            )
        for restatement in RESTATEMENTS:
            if restatement in text:
                failures.append(
                    f"INLINE   {path}: restates the preflight rules "
                    f"({restatement}). Delete the restatement and point at "
                    f"{source_doc} instead."
                )

    if failures:
        print("\n".join(failures), file=sys.stderr)
        print(
            f"\n{len(failures)} canonical-pointer failure(s). Canonical wording "
            f"lives in {source_doc} → Canonical pointer.",
            file=sys.stderr,
        )
        return 1

    print("OK: every skill uses the canonical language-preflight pointer")
    return 0


if __name__ == "__main__":
    sys.exit(main())
