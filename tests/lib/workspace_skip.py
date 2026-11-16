"""Counted skips for doctrine checks that read git-ignored workspace/ files.

Python twin of tests/lib/workspace-skip.sh. A skip appends one line to the file named by
WS_SKIP_FILE (set by `ws_skip_file_init`), which the shell sums into its final warning.
"""

import os
from pathlib import Path


def present(path, hits):
    """True when `path` exists and should be read.

    A missing tracked file is always a failure. A missing file under workspace/skills/ is a
    failure when that directory exists, because the skill was renamed or deleted and its
    assertions would otherwise skip silently. Any other missing workspace/ file is a
    counted skip.
    """
    p = Path(path)
    if p.exists():
        return True
    if p.parts[:1] != ("workspace",):
        hits.append(f"  {p}: missing")
        return False
    if p.parts[:2] == ("workspace", "skills") and Path("workspace/skills").is_dir():
        hits.append(f"  {p}: missing although workspace/skills/ exists")
        return False
    target = os.environ.get("WS_SKIP_FILE")
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write("skip\n")
    return False
