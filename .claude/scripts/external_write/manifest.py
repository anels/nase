from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .account import configured_github_account, github_target_host, github_target_owner
from .base import ActionError, sha256
from .classification import classify, kubectl_command, program_name
from .payload import external_action_dir, literal_at_file_fields, payload_files

MANIFEST_VERSION = 1


def action_payload(
    root: Path,
    system: str,
    summary: str,
    argv: list[str],
    github_owner: str | None = None,
) -> dict[str, Any]:
    classification = classify(argv)
    if classification.kind != "mutation":
        if (
            argv
            and program_name(argv[0]) == "kubectl"
            and kubectl_command([word.lower() for word in argv[1:]]) is None
        ):
            raise ActionError(
                "kubectl has a global option this guard does not recognize; "
                "drop it or pass it as an environment setting, then prepare again"
            )
        raise ActionError("command is not an allowlisted external mutation")
    if system != classification.system:
        raise ActionError(f"system must be {classification.system} for this command")
    if github_owner and system != "github":
        raise ActionError("--github-owner is valid only for GitHub actions")
    offenders = literal_at_file_fields(root, argv)
    if offenders:
        raise ActionError(
            "gh api -f/--raw-field does not read files, so "
            f"{', '.join(offenders)} would post the path as the body text; "
            "build the payload with `jq -n --rawfile body \"$FILE\" '{body:$body}'` "
            'and pass `--input "$PAYLOAD_FILE"` instead '
            "(see .claude/docs/github-queries.md -> Reply To A Review Thread)"
        )
    files = payload_files(root, argv, system)
    payload = {"argv": argv, "payload_files": files}
    action = {
        "system": system,
        "summary": summary,
        "argv": argv,
        "payload_files": files,
        "payload_sha256": sha256(payload),
    }
    if system == "github":
        action["github_host"] = github_target_host(argv)
        owner = github_target_owner(argv, github_owner)
        action["github_owner"] = owner
        action["github_owner_override"] = github_owner is not None
        action["github_account"] = configured_github_account(root, owner)
    return action


def ensure_manifest_path(root: Path, path: Path) -> Path:
    resolved = path.resolve()
    try:
        resolved.relative_to(external_action_dir(root).resolve())
    except ValueError as exc:
        raise ActionError(
            "manifest must live under workspace/tmp/external-actions"
        ) from exc
    return resolved


def load_manifest(root: Path, path: Path) -> tuple[Path, dict[str, Any]]:
    resolved = ensure_manifest_path(root, path)
    try:
        data = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ActionError(f"cannot read manifest: {exc}") from exc
    if (
        not isinstance(data, dict)
        or data.get("version") != MANIFEST_VERSION
        or not isinstance(data.get("action"), dict)
    ):
        raise ActionError("manifest schema is invalid")
    action = data["action"]
    if data.get("action_sha256") != sha256(action):
        raise ActionError("manifest action hash does not match")
    argv = action.get("argv")
    if not isinstance(argv, list) or not all(isinstance(value, str) for value in argv):
        raise ActionError("manifest argv is invalid")
    classification = classify(argv)
    if classification.kind != "mutation" or classification.system != action.get("system"):
        raise ActionError("manifest command is not an allowlisted mutation")
    if action.get("system") == "github" and (
        not isinstance(action.get("github_account"), str)
        or not isinstance(action.get("github_owner"), str)
        or not isinstance(action.get("github_owner_override"), bool)
        or action.get("github_host") != "github.com"
    ):
        raise ActionError("GitHub manifest target or account is invalid")
    expected_payload = sha256(
        {"argv": argv, "payload_files": action.get("payload_files", [])}
    )
    if action.get("payload_sha256") != expected_payload:
        raise ActionError("manifest payload hash does not match")
    return resolved, data
