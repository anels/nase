#!/usr/bin/env python3
"""One bounded git runner for every nase script.

A `git fetch` against an unreachable remote or a `git ls-remote` behind a stalled proxy
hangs forever, and a hook or gate that hangs looks to the caller exactly like one that is
working. The bound lives here so a new call site cannot forget it, together with the
other axes a per-script runner would each answer differently: bytes or text, whether a
non-zero exit raises, and whether the environment is merged.

`run` never raises on a non-zero exit unless asked; a timeout is different, because the
caller learned nothing about the repository and has to decide what that means. Each
consumer maps `GitTimeout` onto its own failure vocabulary rather than inheriting one.
"""

from __future__ import annotations

import contextlib
import os
import pathlib
import subprocess
from collections.abc import Generator
from typing import IO, Any

# Local plumbing finishes in well under a second; the ceiling is here to break a hang,
# not to pace normal work.
GIT_TIMEOUT_SECONDS = 120
# Anything that reaches a remote: a cold fetch on a large repository over a slow link is
# legitimately slow, and cutting it short would turn a slow network into a wrong answer.
GIT_NETWORK_TIMEOUT_SECONDS = 600


class GitTimeout(subprocess.SubprocessError):
    """A git call exceeded its bound and was killed, so its outcome is unknown."""

    def __init__(self, argv: list[str], timeout: float) -> None:
        self.argv = list(argv)
        self.timeout = timeout
        super().__init__(
            f"{' '.join(self.argv)} exceeded {timeout:g}s and was killed; "
            "its effect on the repository is unknown"
        )


def _argv(args: tuple[str, ...], repo: pathlib.Path | str | None) -> list[str]:
    if repo is None:
        return ["git", *args]
    return ["git", "-C", str(repo), *args]


def run(
    *args: str,
    repo: pathlib.Path | str | None = None,
    cwd: pathlib.Path | str | None = None,
    text: bool = False,
    check: bool = False,
    env: dict[str, str] | None = None,
    timeout: float = GIT_TIMEOUT_SECONDS,
) -> subprocess.CompletedProcess:
    """Run one git command with both streams captured and a wall-clock bound.

    `repo` becomes `git -C <repo>`; omit it for a call that must read the ambient
    repository, such as `rev-parse --show-toplevel`. `env` is merged over the current
    environment rather than replacing it, because git needs the ambient PATH and HOME.
    `check` raises `CalledProcessError` exactly as `subprocess.run` would. A timeout
    raises `GitTimeout` instead of `TimeoutExpired`, so a caller cannot mistake it for a
    command that merely failed.
    """
    argv = _argv(args, repo)

    merged_env: dict[str, str] | None = None
    if env:
        merged_env = os.environ.copy()
        merged_env.update(env)

    try:
        return subprocess.run(
            argv,
            cwd=cwd,
            check=check,
            text=text,
            capture_output=True,
            env=merged_env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise GitTimeout(argv, timeout) from exc


@contextlib.contextmanager
def streaming(
    *args: str,
    repo: pathlib.Path | str | None = None,
    stderr: int | IO[Any] = subprocess.DEVNULL,
    timeout: float = GIT_TIMEOUT_SECONDS,
) -> Generator[subprocess.Popen[bytes]]:
    """Yield a running git process whose stdout the caller reads incrementally.

    `run` buffers both streams, which is wrong for a blob that can be hundreds of
    megabytes. This keeps the streaming read and takes on the two things a bare `Popen`
    leaves to every call site: the process is always reaped, and the reap is bounded.

    Pass a real file object as `stderr` when the message matters. A pipe deadlocks: git
    blocks writing to a full stderr pipe while the caller is still draining stdout, and
    neither side ever moves. A file never blocks the writer.
    """
    argv = _argv(args, repo)
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=stderr)
    try:
        yield process
    finally:
        if process.stdout is not None:
            process.stdout.close()
        if process.poll() is None:
            process.kill()
        # Already signalled; a process that will not die after SIGKILL is stuck in the
        # kernel, and blocking the caller on it forever helps nobody.
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=timeout)


def resolve_root(
    explicit: str | os.PathLike[str] | None = None,
    *,
    env_var: str | None = "NASE_ROOT",
) -> pathlib.Path:
    """Resolve the nase workspace root: explicit argument, then env var, then git, then cwd.

    Falling back to the working directory rather than failing is deliberate: the callers
    are hooks and telemetry helpers that must not break the workflow they observe. Pass
    `env_var=None` for a caller that must ignore the ambient root.
    """
    candidate = explicit or (os.environ.get(env_var) if env_var else None)
    if candidate:
        return pathlib.Path(candidate).expanduser().resolve()
    try:
        completed = run("rev-parse", "--show-toplevel", text=True)
        if completed.returncode == 0 and completed.stdout.strip():
            return pathlib.Path(completed.stdout.strip()).resolve()
    except (GitTimeout, OSError):
        pass
    return pathlib.Path.cwd().resolve()
