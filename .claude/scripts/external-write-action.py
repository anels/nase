#!/usr/bin/env python3
"""Prepare, authorize, and execute one payload-bound external CLI mutation."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from external_write.account import (
    GITHUB_PREFLIGHT_TIMEOUT_SECONDS,  # noqa: F401 - loaded by path in tests
    launch_argv,  # noqa: F401 - loaded by path in tests
)
from external_write.base import (
    ActionError,  # noqa: F401 - loaded by path in tests
    sha256,  # noqa: F401 - loaded by path in tests
)
from external_write.classification import (
    GRAPHQL_FILE_BASE,  # noqa: F401 - loaded by path in tests
    classify,  # noqa: F401 - loaded by path in tests
)
from external_write.cli import main
from external_write.guard import cmd_guard  # noqa: F401 - loaded by path in tests
from external_write.ledger import record_outcome  # noqa: F401 - loaded by path in tests
from external_write.manifest import (
    action_payload,  # noqa: F401 - loaded by path in tests
)
from external_write.prose import (
    prose_bodies,  # noqa: F401 - loaded by path in tests
    prose_gate_findings,  # noqa: F401 - loaded by path in tests
    prose_surface,  # noqa: F401 - loaded by path in tests
)

if __name__ == "__main__":
    raise SystemExit(main())
