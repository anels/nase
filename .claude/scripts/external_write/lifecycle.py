from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from nase_fs import lock_exclusive
from nase_time import utc_now_iso
from workspace_lock import pid_alive

from .account import (
    GITHUB_AUTH_ENV_VARS,
    GITHUB_PREFLIGHT_TIMEOUT_SECONDS,
    NO_CWD_SEARCH_ENV_VAR,
    launch_argv,
    run_github_action,
)
from .base import ActionError, parse_timestamp, sha256, write_json
from .ledger import record_outcome
from .manifest import MANIFEST_VERSION, action_payload, load_manifest
from .payload import external_action_dir, token_path, verify_payload_files

TOKEN_TTL_SECONDS = 300
# Deliberately generous: one `terraform apply` or `az deployment create` can
# legitimately run for many minutes. The bound exists so a stalled network call
# cannot hang the session forever, not to fail a slow-but-working write early.
EXECUTE_TIMEOUT_SECONDS = 900
# Distinct from every other exit code because the outcome is unknown, not failed:
# the CLI may have applied the mutation before the bound expired.
EXECUTE_TIMEOUT_EXIT = 11
EXECUTE_LAUNCH_EXIT = 12
# Env vars that redirect a non-GitHub CLI at a specific target. They are kept (they are
# the approved target, not credentials), but each one is announced for the system that
# actually reads it, so an `az` write never claims KUBECONFIG chose its target.
TARGET_SELECTOR_ENV_VARS = {
    "azure": ("AZURE_CONFIG_DIR",),
    "kubernetes": ("KUBECONFIG",),
    "terraform": ("TF_CLI_CONFIG_FILE", "TF_DATA_DIR"),
}


def cmd_prepare(args: argparse.Namespace) -> int:
    argv = list(args.argv)
    if argv and argv[0] == "--":
        argv.pop(0)
    action = action_payload(
        args.root, args.system, args.summary, argv, args.github_owner
    )
    action_dir = external_action_dir(args.root)
    action_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(action_dir, 0o700)
    path = (
        action_dir
        / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex}.json"
    )
    manifest = {"version": MANIFEST_VERSION, "created_at": utc_now_iso(microseconds=False), "action": action}
    manifest["action_sha256"] = sha256(action)
    write_json(path, manifest)
    print(json.dumps({"manifest": str(path), "action": action}, sort_keys=True))
    return 0


CLAIM_GRACE_SECONDS = 60
CLAIM_NAME_RE = re.compile(r"\.executing-(?:(\d+)-(\d+)-)?[0-9a-f]{32}$")


def claim_is_stale(claim: Path, now: float | None = None) -> bool:
    """A claim is abandoned when its executor is gone or past its own kill deadline.

    The owner pid and the deadline ride in the file name, so they land atomically with the
    rename that claims the token. The deadline also covers pid reuse: no live executor can
    outlast its own `--timeout-seconds` by more than the grace period.
    """
    now = time.time() if now is None else now
    match = CLAIM_NAME_RE.search(claim.name)
    if match and match.group(1):
        if now > int(match.group(2)) + CLAIM_GRACE_SECONDS:
            return True
        return not pid_alive(int(match.group(1)))
    try:  # pre-upgrade claim with no owner info: fall back to the longest legal run
        age = now - claim.stat().st_mtime
    except OSError:
        return False
    return age > EXECUTE_TIMEOUT_SECONDS + TOKEN_TTL_SECONDS + CLAIM_GRACE_SECONDS


def token_is_expired(path: Path, now: float | None = None) -> bool:
    """An unreadable or past-TTL token can never pass verify_token, so it is not 'active'."""
    try:
        token = json.loads(path.read_text(encoding="utf-8"))
        created = parse_timestamp(str(token.get("created_at", "")))
        ttl = token.get("ttl_seconds")
        if not isinstance(ttl, int) or isinstance(ttl, bool):
            return True
    except (OSError, ValueError, AttributeError, ActionError):
        return True
    current = (
        datetime.now(timezone.utc)
        if now is None
        else datetime.fromtimestamp(now, timezone.utc)
    )
    return (current - created).total_seconds() > ttl


def discard_dead_file(path: Path, reason: str) -> None:
    """Rename first so two concurrent authorizers cannot both delete and then both re-create."""
    graveyard = path.with_name(f"{path.name}.discarded-{uuid.uuid4().hex}")
    try:
        path.replace(graveyard)
    except FileNotFoundError:
        return
    graveyard.unlink(missing_ok=True)
    print(f"NOTE: removed {reason}: {path.name}", file=sys.stderr)


def cmd_authorize(args: argparse.Namespace) -> int:
    _, manifest = load_manifest(args.root, args.manifest)
    if not 0 < args.ttl_seconds <= TOKEN_TTL_SECONDS:
        raise ActionError(
            f"token TTL must be between 1 and {TOKEN_TTL_SECONDS} seconds"
        )
    path = token_path(args.root)
    token = {
        "version": MANIFEST_VERSION,
        "action_sha256": manifest["action_sha256"],
        "created_at": utc_now_iso(microseconds=False),
        "ttl_seconds": args.ttl_seconds,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_name(f"{path.name}.lock"), "a") as lock:
        # Two authorizers must not both pass the "already active" check below.
        lock_exclusive(lock)
        for claim in path.parent.glob(f"{path.name}.executing-*"):
            if claim_is_stale(claim):
                discard_dead_file(claim, "abandoned external-write claim")
        if path.exists() and token_is_expired(path):
            discard_dead_file(path, "expired external-write token")
        active_claim = next(path.parent.glob(f"{path.name}.executing-*"), None)
        if path.exists() or active_claim is not None:
            raise ActionError(
                "an external-write token is already active; execute or remove it before authorizing another action"
            )
        write_json(path, token)
    print(
        json.dumps(
            {"token": str(path), "expires_in_seconds": args.ttl_seconds}, sort_keys=True
        )
    )
    return 0


def claim_token(root: Path, timeout_seconds: float) -> tuple[Path, dict[str, Any]]:
    """Atomically move the one-shot token out of circulation before execution."""
    path = token_path(root)
    # The claim also covers the preflight lookups that run before the bounded mutation.
    deadline = int(time.time() + timeout_seconds + 2 * GITHUB_PREFLIGHT_TIMEOUT_SECONDS)
    claimed = path.with_name(
        f"{path.name}.executing-{os.getpid()}-{deadline}-{uuid.uuid4().hex}"
    )
    try:
        with open(path.with_name(f"{path.name}.lock"), "a") as lock:
            # The rename must hold the same lock `cmd_authorize` uses for its
            # "already active" check: otherwise a claim can land in the middle
            # of that check-then-write, and authorize's view of the token state
            # is stale when it writes a second token.
            lock_exclusive(lock)
            path.replace(claimed)
    except FileNotFoundError as exc:
        # Covers a missing token and a missing `workspace/` directory alike:
        # the lock file cannot be opened when its directory is absent.
        raise ActionError("no external-write token present") from exc
    try:
        token = json.loads(claimed.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        claimed.unlink(missing_ok=True)
        raise ActionError(f"external-write token is invalid: {exc}") from exc
    if not isinstance(token, dict):
        claimed.unlink(missing_ok=True)
        raise ActionError("external-write token is invalid: not a JSON object")
    return claimed, token


def verify_token(token: dict[str, Any], manifest: dict[str, Any]) -> None:
    if not isinstance(token, dict) or token.get("version") != MANIFEST_VERSION:
        raise ActionError("external-write token schema is invalid")
    if token.get("action_sha256") != manifest.get("action_sha256"):
        raise ActionError("external-write token does not match this manifest")
    created_at = parse_timestamp(str(token.get("created_at", "")))
    ttl = token.get("ttl_seconds")
    if not isinstance(ttl, int) or ttl <= 0 or ttl > TOKEN_TTL_SECONDS:
        raise ActionError("external-write token TTL is invalid")
    age = (datetime.now(timezone.utc) - created_at).total_seconds()
    if age < 0 or age > ttl:
        raise ActionError("external-write token is stale or from the future")


def cmd_execute(args: argparse.Namespace) -> int:
    if args.timeout_seconds <= 0:
        raise ActionError("execute timeout must be a positive number of seconds")
    token_file: Path | None = None
    try:
        token_file, token = claim_token(args.root, args.timeout_seconds)
        manifest_path, manifest = load_manifest(args.root, args.manifest)
        verify_token(token, manifest)
        action = manifest["action"]
        verify_payload_files(args.root, action)
        try:
            if action["system"] == "github":
                completed = run_github_action(args.root, action, args.timeout_seconds)
            else:
                # Do not let ambient GitHub auth env vars leak into a non-GitHub
                # CLI: an approved `az`/`kubectl`/`terraform` call must not
                # silently inherit a stray GH_TOKEN. Target selectors are
                # deliberately kept, because they are the approved target, not
                # credentials.
                environment = os.environ.copy()
                for key in GITHUB_AUTH_ENV_VARS:
                    environment.pop(key, None)
                environment[NO_CWD_SEARCH_ENV_VAR] = "1"
                for redirect_var in TARGET_SELECTOR_ENV_VARS.get(
                    action["system"], ()
                ):
                    if redirect_var in environment:
                        print(
                            f"NOTE: {redirect_var} is set and selects the target for "
                            f"this {action['system']} write.",
                            file=sys.stderr,
                        )
                completed = subprocess.run(
                    launch_argv(action["argv"]),
                    cwd=args.root,
                    env=environment,
                    check=False,
                    timeout=args.timeout_seconds,
                )
        except subprocess.TimeoutExpired:
            # Not a failure: the CLI may have applied the mutation before the bound
            # expired, and nothing here can tell which. Say so, and let the consumed
            # token force a fresh approval rather than inviting a blind retry.
            print(
                f"TIMEOUT: {action['system']} write exceeded {args.timeout_seconds}s; the CLI "
                "process was killed.\n"
                "  The mutation MAY already have been applied. Read the target state before "
                "deciding anything.\n"
                "  Only the CLI itself was signalled, so any helper process it spawned (a "
                "Terraform provider, for one) can still be running.\n"
                "  The one-shot token is spent, so a retry needs a new preview and approval.",
                file=sys.stderr,
            )
            record_outcome(args.root, manifest_path, action, None, "unknown")
            return EXECUTE_TIMEOUT_EXIT
        except OSError as exc:
            print(
                f"ERROR: could not launch {action['argv'][0]}: {exc}\n"
                "  Nothing was mutated. The one-shot token is spent, so a retry needs a "
                "new approval.",
                file=sys.stderr,
            )
            record_outcome(args.root, manifest_path, action, None, "not-launched")
            return EXECUTE_LAUNCH_EXIT
        record_outcome(
            args.root,
            manifest_path,
            action,
            completed.returncode,
            "ok" if completed.returncode == 0 else "failed",
        )
        return completed.returncode
    finally:
        if token_file is not None:
            token_file.unlink(missing_ok=True)
