#!/usr/bin/env python3
"""Run isolated NASE routing and fixture-backed output evaluations."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST_DIR = REPO_ROOT / "workspace" / "stats" / "skill-evals" / "runs"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "workspace" / "stats" / "skill-evals" / "outputs"
ENV_ALLOWLIST = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR")
AUTH_SOURCES = ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
DISPOSABLE_ENV = {
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
    "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1",
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1",
}
OUTPUT_LIMIT = 512 * 1024
REQUIRED_ROUTING_REPETITIONS = 3
DENIED_TOOLS = ["Bash", "Edit", "Write", "NotebookEdit", "Agent", "WebFetch", "WebSearch"]
FILESYSTEM_POLICY = {
    "sandbox": {
        "enabled": True,
        "failIfUnavailable": True,
        "filesystem": {"denyRead": ["/"], "allowRead": ["."]},
    },
    "permissions": {"deny": DENIED_TOOLS},
}
BOUNDARY_INSTRUCTION = (
    "Before inspecting the fixture, attempt to read ../forbidden-read/sentinel.txt. "
    "Continue only after that read is denied. Then use Read or Grep on every named fixture file."
)


class RunError(RuntimeError):
    """A fail-closed execution or receipt error."""


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RunError(f"cannot load helper: {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EVAL = load_module("nase_pr_review_eval", REPO_ROOT / ".claude" / "scripts" / "pr-review-eval.py")
SECRET = load_module("nase_codex_verify_bundle", REPO_ROOT / ".claude" / "scripts" / "codex-verify-bundle.py")


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    return sha256(path.read_bytes())


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def relative_repo_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.name


def safe_directory(value: str | None, default: Path, label: str) -> Path:
    path = default if value is None else Path(value).expanduser()
    if ".." in path.parts or path.is_symlink():
        raise RunError(f"{label} must not traverse or be a symlink")
    resolved = path.resolve()
    resolved.mkdir(parents=True, exist_ok=True)
    if not resolved.is_dir():
        raise RunError(f"{label} is not a directory")
    return resolved


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("wb", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def scan_bytes(data: bytes) -> str | None:
    hit = SECRET.scan_stream_for_secret(io.BytesIO(data))
    return str(hit[0]) if hit else None


def command_inventory() -> list[dict[str, str]]:
    completed = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z", ".claude/commands/nase/*.md", ".claude/commands/nase/**/*.md"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    inventory: list[dict[str, str]] = []
    seen: set[str] = set()
    for raw_path in completed.stdout.split(b"\0"):
        if not raw_path:
            continue
        relative = os.fsdecode(raw_path)
        source = REPO_ROOT / relative
        match = re.search(r"(?m)^name:\s*(nase:(?:workspace:)?[a-z0-9][a-z0-9-]*)\s*$", source.read_text())
        if not match or match.group(1) in seen:
            raise RunError(f"invalid or duplicate command name: {relative}")
        seen.add(match.group(1))
        inventory.append({"name": match.group(1), "path": relative, "sha256": file_sha(source)})
    if not inventory:
        raise RunError("tracked NASE command inventory is empty")
    return sorted(inventory, key=lambda item: (item["name"], item["path"]))


def inventory_binding(inventory: list[dict[str, str]]) -> dict[str, Any]:
    return {"sha256": sha256(canonical_bytes(inventory)), "count": len(inventory)}


def tree_binding(root: Path) -> tuple[str, dict[str, str]]:
    entries: list[dict[str, str]] = []
    hashes: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        digest = file_sha(path)
        hashes[relative] = digest
        entries.append({"path": relative, "sha256": digest})
    return sha256(canonical_bytes(entries)), hashes


def copy_file(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def initialize_repo(project: Path) -> None:
    subprocess.run(["git", "init", "-q", str(project)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def install_inventory(project: Path, inventory: list[dict[str, str]]) -> None:
    for item in inventory:
        copy_file(REPO_ROOT / item["path"], project / item["path"])


def parse_json_output(completed: subprocess.CompletedProcess[str], label: str) -> dict[str, Any]:
    try:
        value = json.loads(completed.stdout)
    except (json.JSONDecodeError, TypeError) as exc:
        raise RunError(f"{label} returned malformed JSON") from exc
    if not isinstance(value, dict):
        raise RunError(f"{label} returned a non-object")
    return value


def parent_auth(claude: str) -> tuple[dict[str, str], str]:
    try:
        completed = subprocess.run(
            [claude, "auth", "status"], text=True, capture_output=True, timeout=15, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RunError("unauthenticated: parent auth status unavailable") from exc
    if completed.returncode != 0:
        raise RunError("unauthenticated: parent auth status failed")
    status = parse_json_output(completed, "parent auth status")
    if status.get("loggedIn") is not True:
        raise RunError("unauthenticated")
    provider = status.get("apiProvider")
    source = status.get("apiKeySource")
    if provider != "firstParty" or source not in AUTH_SOURCES:
        raise RunError("unsupported-auth-source")
    if not os.environ.get(str(source)):
        raise RunError("unsupported-auth-source: selected environment credential is absent")
    return {"provider": str(provider), "source_name": str(source)}, str(source)


def child_environment(home: Path, source: str) -> dict[str, str]:
    child = {name: os.environ[name] for name in ENV_ALLOWLIST if os.environ.get(name)}
    child.update(DISPOSABLE_ENV)
    child["HOME"] = str(home)
    child["CLAUDE_CONFIG_DIR"] = str(home / ".claude")
    child[source] = os.environ[source]
    Path(child["CLAUDE_CONFIG_DIR"]).mkdir(mode=0o700)
    return child


def verify_child_auth(claude: str, child: dict[str, str], expected: dict[str, str]) -> None:
    try:
        completed = subprocess.run(
            [claude, "auth", "status"], env=child, text=True, capture_output=True, timeout=15, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RunError("child-auth-mismatch") from exc
    if completed.returncode != 0:
        raise RunError("child-auth-mismatch")
    status = parse_json_output(completed, "child auth status")
    actual = {"provider": status.get("apiProvider"), "source_name": status.get("apiKeySource")}
    if status.get("loggedIn") is not True or actual != expected:
        raise RunError("child-auth-mismatch")


def claude_version(claude: str, child: dict[str, str]) -> str:
    completed = subprocess.run(
        [claude, "--version"], env=child, text=True, capture_output=True, timeout=15, check=False
    )
    if completed.returncode != 0:
        raise RunError("claude-version-unavailable")
    return completed.stdout.strip()[:200]


def invoke(
    claude: str,
    project: Path,
    child: dict[str, str],
    prompt: str,
    model: str,
    budget: float,
    timeout: int,
    tools: str,
    session_id: str,
) -> dict[str, Any]:
    empty_mcp = project / "empty-mcp.json"
    atomic_write(empty_mcp, b"{}\n")
    args = [
        claude,
        "--print",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-hook-events",
        "--permission-mode",
        "dontAsk",
        "--tools",
        tools,
        "--setting-sources",
        "project",
        "--no-session-persistence",
        "--strict-mcp-config",
        "--mcp-config",
        str(empty_mcp),
        "--model",
        model,
        "--max-budget-usd",
        str(budget),
        "--session-id",
        session_id,
        prompt,
    ]
    started = time.monotonic()
    try:
        completed = subprocess.run(
            args,
            cwd=project,
            env=child,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {"error": "timeout", "duration_ms": int((time.monotonic() - started) * 1000)}
    except OSError:
        return {"error": "runtime-unavailable", "duration_ms": int((time.monotonic() - started) * 1000)}
    parsed = parse_stream(completed.stdout)
    parsed.update(
        {
            "returncode": completed.returncode,
            "duration_ms": parsed.get("duration_ms") or int((time.monotonic() - started) * 1000),
            "stderr_sha256": sha256(completed.stderr.encode()) if completed.stderr else None,
        }
    )
    if completed.returncode != 0:
        parsed["error"] = "nonzero-exit"
    elif not parsed.get("terminal_seen"):
        parsed["error"] = "missing-terminal-result"
    elif not parsed.get("init_seen"):
        parsed["error"] = "missing-init"
    return parsed


def event_blocks(event: dict[str, Any]) -> list[dict[str, Any]]:
    message = event.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    return [block for block in content if isinstance(block, dict)] if isinstance(content, list) else []


def parse_stream(text: str) -> dict[str, Any]:
    parsed: dict[str, Any] = {
        "parse_warnings": 0,
        "init_seen": False,
        "terminal_seen": False,
        "available_skills": [],
        "resolved_model": None,
        "skill_uses": [],
        "reads": [],
        "tool_results": {},
        "result": "",
        "total_cost_usd": None,
    }
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            parsed["parse_warnings"] += 1
            continue
        if not isinstance(event, dict):
            parsed["parse_warnings"] += 1
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            parsed["init_seen"] = True
            parsed["resolved_model"] = event.get("model")
            skills = event.get("skills", [])
            parsed["available_skills"] = sorted(str(item) for item in skills if str(item).startswith("nase:"))
        for block in event_blocks(event):
            if block.get("type") == "tool_use":
                name = str(block.get("name", ""))
                inputs = block.get("input") if isinstance(block.get("input"), dict) else {}
                tool_id = str(block.get("id", ""))
                if name == "Skill":
                    parsed["skill_uses"].append({"skill": inputs.get("skill"), "tool_use_id": tool_id})
                elif name in {"Read", "Grep"}:
                    path = inputs.get("file_path") or inputs.get("path") or ""
                    parsed["reads"].append({"tool": name, "path": str(path), "tool_use_id": tool_id})
            elif block.get("type") == "tool_result":
                tool_id = str(block.get("tool_use_id", ""))
                content = block.get("content", "")
                if not isinstance(content, str):
                    content = json.dumps(content, sort_keys=True)
                parsed["tool_results"][tool_id] = {
                    "content": content,
                    "is_error": bool(block.get("is_error")),
                }
        if event.get("type") == "result":
            parsed["terminal_seen"] = True
            result = event.get("result", "")
            parsed["result"] = result if isinstance(result, str) else json.dumps(result, sort_keys=True)
            parsed["total_cost_usd"] = event.get("total_cost_usd", 0)
            parsed["duration_ms"] = event.get("duration_ms")
            parsed["resolved_model"] = event.get("model") or parsed["resolved_model"]
    return parsed


def cost_error(parsed: dict[str, Any], budget: float) -> str | None:
    value = parsed.get("total_cost_usd")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        return "invalid-cost-evidence"
    if value > budget:
        return "budget-exceeded"
    return None


def base_receipt(
    lane: str,
    behavior_scope: str,
    run_id: str,
    eval_path: Path,
    case: dict[str, Any],
    skill_path: Path,
    prompt: str,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "run_id": run_id,
        "recorded_at": utc_now(),
        "lane": lane,
        "behavior_scope": behavior_scope,
        "eval_set": {"path": relative_repo_path(eval_path), "sha256": file_sha(eval_path)},
        "case": {
            "id": case["id"],
            "score_case_id": case.get("score_case"),
            "prompt_sha256": sha256(prompt.encode()),
            "expect": case.get("expect"),
        },
        "skill": {
            "name": case["skill"],
            "path": relative_repo_path(skill_path),
            "sha256": file_sha(skill_path),
        },
        "skill_inventory": None,
        "fixture": None,
        "runtime": {},
        "invocation_evidence": None,
        "process": {},
        "output": None,
        "result": {"status": "error", "reason": "not-run"},
        "human_review": {"status": "pending", "reviewed_at": None, "note": None},
    }


def persist_receipt(receipt: dict[str, Any], manifest_dir: Path) -> Path:
    data = canonical_bytes(receipt)
    kind = scan_bytes(data)
    if kind:
        raise RunError(f"receipt-secret-scan:{kind}")
    target = manifest_dir / f"{receipt['run_id']}.json"
    atomic_write(target, data)
    return target


def prepare_runtime() -> tuple[str, dict[str, str], str]:
    claude = shutil.which("claude")
    if not claude:
        raise RunError("runtime-unavailable")
    auth, source = parent_auth(claude)
    return claude, auth, source


def run_routing(args: argparse.Namespace) -> int:
    eval_path = Path(args.eval_set).resolve()
    eval_set = EVAL.load_eval_set(str(eval_path))
    case = EVAL.find_routing_case(eval_set, args.routing_case)
    inventory = command_inventory()
    by_name = {item["name"]: item for item in inventory}
    target = by_name.get(case["skill"])
    if target is None:
        raise RunError("target skill is absent from tracked inventory")
    manifest_dir = safe_directory(args.manifest_dir, DEFAULT_MANIFEST_DIR, "manifest-dir")
    claude, auth, source = prepare_runtime()
    overall_ok = True
    batch_id = str(uuid.uuid4())
    for repetition_index in range(args.repetitions):
        run_id = str(uuid.uuid4())
        receipt = base_receipt(
            "routing", "automatic-routing", run_id, eval_path, case, REPO_ROOT / target["path"], case["prompt"]
        )
        receipt["skill_inventory"] = inventory_binding(inventory)
        with tempfile.TemporaryDirectory(prefix="nase-routing-") as temporary:
            base = Path(temporary)
            project = base / "project"
            home = base / "home"
            project.mkdir()
            home.mkdir(mode=0o700)
            initialize_repo(project)
            install_inventory(project, inventory)
            child = child_environment(home, source)
            verify_child_auth(claude, child, auth)
            version = claude_version(claude, child)
            parsed = invoke(
                claude,
                project,
                child,
                case["prompt"],
                args.model,
                args.max_budget_usd,
                args.timeout_seconds,
                "Skill",
                run_id,
            )
        expected_skills = sorted(by_name)
        error = parsed.get("error")
        if not error and parsed.get("available_skills") != expected_skills:
            error = "skill-inventory-mismatch"
        if not error and parsed.get("resolved_model") != args.model:
            error = "model-mismatch"
        if not error:
            error = cost_error(parsed, args.max_budget_usd)
        uses = parsed.get("skill_uses", [])
        target_use = next((item for item in uses if item.get("skill") == case["skill"]), None)
        adjacent_use = next((item for item in uses if item.get("skill") == case.get("adjacent_skill")), None)
        passed = bool(target_use) if case["expect"] == "invoke" else not bool(target_use)
        if error:
            status = "error"
            reason = str(error)
        else:
            status = "pass" if passed else "fail"
            reason = "expectation-met" if passed else "routing-expectation-mismatch"
        evidence = target_use or adjacent_use
        receipt["runtime"] = {
            "claude_code_version": version,
            "requested_model": args.model,
            "resolved_model": parsed.get("resolved_model"),
            "available_skills": parsed.get("available_skills", []),
            "isolation": {"environment_policy": "allowlist-v1", "filesystem_policy_sha256": None, "forbidden_canary_sha256": None, "forbidden_read_control": None},
            "auth": auth,
        }
        receipt["invocation_evidence"] = {
            "kind": "automatic-skill-tool-use" if target_use else ("adjacent-skill-tool-use" if adjacent_use else "none"),
            "session_id": run_id,
            "tool_use_id": evidence.get("tool_use_id") if evidence else None,
            "adjacent_skill": adjacent_use.get("skill") if adjacent_use else None,
        }
        result_bytes = str(parsed.get("result", "")).encode()
        receipt["process"] = {
            "batch_id": batch_id,
            "repetition_index": repetition_index + 1,
            "repetition_count": args.repetitions,
            "returncode": parsed.get("returncode"),
            "duration_ms": parsed.get("duration_ms"),
            "total_cost_usd": parsed.get("total_cost_usd", 0),
            "result_hash": sha256(result_bytes),
            "stderr_sha256": parsed.get("stderr_sha256"),
            "parse_warnings": parsed.get("parse_warnings", 0),
        }
        receipt["result"] = {"status": status, "reason": reason}
        receipt_path = persist_receipt(receipt, manifest_dir)
        print(json.dumps({"receipt": str(receipt_path), "status": status, "reason": reason}, sort_keys=True))
        overall_ok = overall_ok and status == "pass"
    return 0 if overall_ok else 1


def output_project(project: Path, case: dict[str, Any], eval_path: Path) -> tuple[Path, bytes]:
    skill_path = EVAL.command_path(REPO_ROOT, case["skill"])
    copy_file(skill_path, project / relative_repo_path(skill_path))
    for source in sorted((REPO_ROOT / ".claude" / "docs").glob("*.md")):
        copy_file(source, project / ".claude" / "docs" / source.name)
    fixture = eval_path.parent / case["fixture_dir"]
    shutil.copytree(fixture, project / "fixture")
    settings = canonical_bytes(FILESYSTEM_POLICY)
    atomic_write(project / ".claude" / "settings.json", settings)
    return skill_path, settings


def output_controls(parsed: dict[str, Any], case: dict[str, Any], forbidden: str) -> dict[str, Any]:
    reads = parsed.get("reads", [])
    results = parsed.get("tool_results", {})
    forbidden_reads = [item for item in reads if str(item.get("path", "")).endswith("forbidden-read/sentinel.txt")]
    denied = False
    for item in forbidden_reads:
        result = results.get(item.get("tool_use_id"), {})
        content = str(result.get("content", ""))
        denied = denied or bool(result.get("is_error")) or bool(re.search(r"(?i)(denied|not allowed|permission)", content))
    required: dict[str, bool] = {}
    for required_path in case["required_reads"]:
        expected = f"fixture/{required_path}"
        matching = [item for item in reads if str(item.get("path", "")).endswith(expected)]
        required[required_path] = any(
            item.get("tool_use_id") in results
            and not bool(results[item["tool_use_id"]].get("is_error"))
            and not re.search(
                r"(?i)(denied|not allowed|permission)",
                str(results[item["tool_use_id"]].get("content", "")),
            )
            for item in matching
        )
    result_text = str(parsed.get("result", ""))
    canaries = {sha256(item.encode()): item in result_text for item in case["required_canaries"]}
    transcript_text = result_text + "\n" + "\n".join(str(value.get("content", "")) for value in results.values())
    return {
        "filesystem_boundary_ok": bool(forbidden_reads) and denied and forbidden not in transcript_text,
        "required_reads": required,
        "required_reads_ok": all(required.values()),
        "canaries": canaries,
        "canaries_ok": all(canaries.values()),
    }


def run_output(args: argparse.Namespace) -> int:
    eval_path = Path(args.eval_set).resolve()
    eval_set = EVAL.load_eval_set(str(eval_path))
    case = EVAL.find_runtime_case(eval_set, args.runtime_case)
    manifest_dir = safe_directory(args.manifest_dir, DEFAULT_MANIFEST_DIR, "manifest-dir")
    output_dir = safe_directory(args.output_dir, DEFAULT_OUTPUT_DIR, "output-dir")
    claude, auth, source = prepare_runtime()
    overall_ok = True
    batch_id = str(uuid.uuid4())
    for repetition_index in range(args.repetitions):
        run_id = str(uuid.uuid4())
        effective_prompt = f"{case['prompt']}\n\n{BOUNDARY_INSTRUCTION}"
        skill_path = EVAL.command_path(REPO_ROOT, case["skill"])
        receipt = base_receipt(
            "output",
            "permission-confined-fixture-backed-no-write-output-contract",
            run_id,
            eval_path,
            case,
            skill_path,
            effective_prompt,
        )
        fixture_source = eval_path.parent / case["fixture_dir"]
        fixture_sha, fixture_hashes = tree_binding(fixture_source)
        forbidden = f"FORBIDDEN_{uuid.uuid4().hex}"
        with tempfile.TemporaryDirectory(prefix="nase-output-") as temporary:
            base = Path(temporary)
            project = base / "project"
            home = base / "home"
            project.mkdir()
            home.mkdir(mode=0o700)
            initialize_repo(project)
            _, settings = output_project(project, case, eval_path)
            forbidden_dir = base / "forbidden-read"
            forbidden_dir.mkdir()
            atomic_write(forbidden_dir / "sentinel.txt", forbidden.encode())
            child = child_environment(home, source)
            verify_child_auth(claude, child, auth)
            version = claude_version(claude, child)
            parsed = invoke(
                claude,
                project,
                child,
                effective_prompt,
                args.model,
                args.max_budget_usd,
                args.timeout_seconds,
                "Skill,Read,Grep,Glob",
                run_id,
            )
        controls = output_controls(parsed, case, forbidden)
        result_bytes = str(parsed.get("result", "")).encode()
        secret_kind = scan_bytes(result_bytes) if len(result_bytes) <= OUTPUT_LIMIT else "output-too-large"
        error = parsed.get("error")
        if not error and parsed.get("resolved_model") != args.model:
            error = "model-mismatch"
        if not error and parsed.get("available_skills") != [case["skill"]]:
            error = "output-skill-isolation-mismatch"
        if not error:
            error = cost_error(parsed, args.max_budget_usd)
        target_use = next(
            (item for item in parsed.get("skill_uses", []) if item.get("skill") == case["skill"]),
            None,
        )
        if not error and target_use is None:
            error = "explicit-command-expansion-missing"
        if secret_kind:
            error = "sensitive-output"
        if not controls["filesystem_boundary_ok"]:
            error = error or "filesystem-boundary-failed"
        output_path: Path | None = None
        score: dict[str, Any] = {"ok": False, "error": error or "output-controls-failed"}
        if not error and controls["required_reads_ok"] and controls["canaries_ok"]:
            output_path = output_dir / f"{run_id}.txt"
            atomic_write(output_path, result_bytes)
            score_case = EVAL.find_case(eval_set, case["score_case"])
            score = EVAL.score_case(score_case, str(output_path))
        passed = (
            not error
            and controls["filesystem_boundary_ok"]
            and controls["required_reads_ok"]
            and controls["canaries_ok"]
            and score.get("ok") is True
        )
        status = "pass" if passed else ("error" if error else "fail")
        receipt["fixture"] = {
            "path": case["fixture_dir"],
            "tree_sha256": fixture_sha,
            "required_read_hashes": {name: fixture_hashes[name] for name in case["required_reads"]},
            "canary_hashes": [sha256(item.encode()) for item in case["required_canaries"]],
        }
        receipt["runtime"] = {
            "claude_code_version": version,
            "requested_model": args.model,
            "resolved_model": parsed.get("resolved_model"),
            "available_skills": parsed.get("available_skills", []),
            "isolation": {
                "environment_policy": "allowlist-v1",
                "filesystem_policy_sha256": sha256(settings),
                "forbidden_canary_sha256": sha256(forbidden.encode()),
                "forbidden_read_control": "passed" if controls["filesystem_boundary_ok"] else "failed",
            },
            "auth": auth,
        }
        receipt["invocation_evidence"] = {
            "kind": "explicit-command-expansion",
            "session_id": run_id,
            "tool_use_id": target_use.get("tool_use_id") if target_use else None,
        }
        receipt["process"] = {
            "batch_id": batch_id,
            "repetition_index": repetition_index + 1,
            "repetition_count": args.repetitions,
            "returncode": parsed.get("returncode"),
            "duration_ms": parsed.get("duration_ms"),
            "total_cost_usd": parsed.get("total_cost_usd", 0),
            "result_hash": sha256(result_bytes),
            "stderr_sha256": parsed.get("stderr_sha256"),
            "parse_warnings": parsed.get("parse_warnings", 0),
        }
        receipt["output"] = {
            "path": str(output_path.resolve()) if output_path else None,
            "sha256": sha256(result_bytes) if output_path else None,
            "score": score,
            "filesystem_boundary_ok": controls["filesystem_boundary_ok"],
            "required_reads": controls["required_reads"],
            "required_reads_ok": controls["required_reads_ok"],
            "canaries": controls["canaries"],
            "canaries_ok": controls["canaries_ok"],
            "secret_scan": "passed" if secret_kind is None else "failed",
            "receipt_secret_scan": "passed",
        }
        receipt["result"] = {"status": status, "reason": "all-controls-passed" if passed else (error or "output-expectation-mismatch")}
        receipt_path = persist_receipt(receipt, manifest_dir)
        print(json.dumps({"receipt": str(receipt_path), "status": status, "reason": receipt["result"]["reason"]}, sort_keys=True))
        overall_ok = overall_ok and passed
    return 0 if overall_ok else 1


def current_binding(eval_path: Path, case: dict[str, Any], lane: str) -> dict[str, Any]:
    skill_path = EVAL.command_path(REPO_ROOT, case["skill"])
    prompt = case["prompt"] if lane == "routing" else f"{case['prompt']}\n\n{BOUNDARY_INSTRUCTION}"
    binding: dict[str, Any] = {
        "eval_sha": file_sha(eval_path),
        "skill_sha": file_sha(skill_path),
        "prompt_sha": sha256(prompt.encode()),
    }
    if lane == "routing":
        binding["inventory"] = inventory_binding(command_inventory())
    else:
        binding["fixture_sha"] = tree_binding(eval_path.parent / case["fixture_dir"])[0]
        binding["filesystem_policy_sha"] = sha256(canonical_bytes(FILESYSTEM_POLICY))
    return binding


def receipt_current(receipt: dict[str, Any], binding: dict[str, Any]) -> bool:
    if receipt.get("eval_set", {}).get("sha256") != binding["eval_sha"]:
        return False
    if receipt.get("skill", {}).get("sha256") != binding["skill_sha"]:
        return False
    if receipt.get("case", {}).get("prompt_sha256") != binding["prompt_sha"]:
        return False
    if "inventory" in binding and receipt.get("skill_inventory") != binding["inventory"]:
        return False
    if "fixture_sha" in binding and receipt.get("fixture", {}).get("tree_sha256") != binding["fixture_sha"]:
        return False
    if "filesystem_policy_sha" in binding and receipt.get("runtime", {}).get("isolation", {}).get("filesystem_policy_sha256") != binding["filesystem_policy_sha"]:
        return False
    return True


def load_receipts(directory: Path) -> tuple[list[dict[str, Any]], int]:
    receipts: list[dict[str, Any]] = []
    invalid = 0
    if not directory.exists():
        return receipts, invalid
    for path in sorted(directory.glob("*.json")):
        if path.is_symlink() or not path.is_file():
            invalid += 1
            continue
        try:
            value = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            invalid += 1
            continue
        if isinstance(value, dict) and value.get("schema_version") == 1:
            receipts.append(value)
        else:
            invalid += 1
    return receipts, invalid


def routing_batch_state(receipts: list[dict[str, Any]]) -> tuple[str, bool]:
    batches: dict[str, list[dict[str, Any]]] = {}
    for receipt in receipts:
        batch = str(receipt.get("process", {}).get("batch_id", ""))
        batches.setdefault(batch, []).append(receipt)
    eligible: list[list[dict[str, Any]]] = []
    for batch in batches.values():
        counts = {item.get("process", {}).get("repetition_count") for item in batch}
        if len(counts) != 1:
            continue
        count = next(iter(counts))
        indices = {item.get("process", {}).get("repetition_index") for item in batch}
        if (
            isinstance(count, int)
            and count >= REQUIRED_ROUTING_REPETITIONS
            and len(batch) == count
            and indices == set(range(1, count + 1))
        ):
            eligible.append(batch)
    latest = max(
        eligible,
        key=lambda batch: max(str(item.get("recorded_at", "")) for item in batch),
        default=[],
    )
    statuses = [item.get("result", {}).get("status") for item in latest]
    if "error" in statuses:
        return "error", False
    if statuses and all(status == "pass" for status in statuses):
        return "stable-pass", False
    if statuses and all(status == "fail" for status in statuses):
        return "stable-fail", False
    if statuses:
        return "unstable", True
    return "missing", False


def output_receipt_passes(receipt: dict[str, Any]) -> bool:
    output = receipt.get("output", {})
    raw_path = output.get("path")
    if not isinstance(raw_path, str):
        return False
    path = Path(raw_path)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        return False
    try:
        data = path.read_bytes()
    except OSError:
        return False
    return (
        receipt.get("result", {}).get("status") == "pass"
        and len(data) <= OUTPUT_LIMIT
        and output.get("sha256") == sha256(data)
        and scan_bytes(data) is None
        and output.get("score", {}).get("ok") is True
        and output.get("filesystem_boundary_ok") is True
        and output.get("required_reads_ok") is True
        and output.get("canaries_ok") is True
        and output.get("secret_scan") == "passed"
        and output.get("receipt_secret_scan") == "passed"
    )


def coverage(args: argparse.Namespace) -> int:
    manifest_dir = safe_directory(args.manifest_dir, DEFAULT_MANIFEST_DIR, "manifest-dir")
    receipts, invalid_receipts = load_receipts(manifest_dir)
    rows: list[dict[str, Any]] = []
    stale = 0
    errors = 0
    rejected = 0
    flips = 0
    missing_positive = 0
    missing_near_miss = 0
    for raw_eval in args.eval_set:
        eval_path = Path(raw_eval).resolve()
        eval_set = EVAL.load_eval_set(str(eval_path))
        skills = sorted(
            {
                case["skill"]
                for case in eval_set["cases"]
                if not str(case["skill"]).startswith("nase:workspace:")
            }
        )
        routing_by_skill = {skill: [case for case in eval_set.get("routing_cases", []) if case["skill"] == skill] for skill in skills}
        runtime_by_skill = {case["skill"]: case for case in eval_set.get("runtime_cases", [])}
        for skill in skills:
            routing_cases = routing_by_skill[skill]
            expectations = {case["expect"] for case in routing_cases}
            structural = "complete" if expectations == EVAL.ROUTING_EXPECTATIONS else "missing"
            missing_positive += "invoke" not in expectations
            missing_near_miss += "not_invoke" not in expectations
            invocation_states: list[str] = []
            for case in routing_cases:
                binding = current_binding(eval_path, case, "routing")
                candidates = [receipt for receipt in receipts if receipt.get("lane") == "routing" and receipt.get("case", {}).get("id") == case["id"]]
                current = [receipt for receipt in candidates if receipt_current(receipt, binding)]
                stale += len(candidates) - len(current)
                statuses = [receipt.get("result", {}).get("status") for receipt in current]
                errors += statuses.count("error")
                state, flipped = routing_batch_state(current)
                flips += flipped
                if state == "missing" and candidates and not current:
                    state = "stale"
                invocation_states.append(state)
            if invocation_states and all(state == "stable-pass" for state in invocation_states):
                invocation = "stable-pass"
            elif "error" in invocation_states:
                invocation = "error"
            elif "unstable" in invocation_states:
                invocation = "unstable"
            elif "stable-fail" in invocation_states:
                invocation = "stable-fail"
            elif "stale" in invocation_states:
                invocation = "stale"
            else:
                invocation = "missing"
            runtime_case = runtime_by_skill.get(skill)
            if runtime_case is None:
                outcome = "manual-only"
                human = "manual-only"
            else:
                binding = current_binding(eval_path, runtime_case, "output")
                candidates = [receipt for receipt in receipts if receipt.get("lane") == "output" and receipt.get("case", {}).get("id") == runtime_case["id"]]
                current = [receipt for receipt in candidates if receipt_current(receipt, binding)]
                stale += len(candidates) - len(current)
                passing = [receipt for receipt in current if output_receipt_passes(receipt)]
                errors += sum(receipt.get("result", {}).get("status") == "error" for receipt in current)
                rejected += sum(receipt.get("human_review", {}).get("status") == "rejected" for receipt in current)
                outcome = "fixture-backed-pass" if passing else (
                    "error" if any(receipt.get("result", {}).get("status") == "error" for receipt in current)
                    else "stale" if candidates and not current else "missing"
                )
                human = "accepted" if any(receipt.get("human_review", {}).get("status") == "accepted" for receipt in passing) else "pending"
            rows.append({"skill": skill, "structural": structural, "invocation": invocation, "outcome": outcome, "human": human})
    payload = {
        "schema_version": 1,
        "rows": sorted(rows, key=lambda row: row["skill"]),
        "diagnostics": {
            "stale_receipts": stale,
            "invalid_receipts": invalid_receipts,
            "error_receipts": errors,
            "routing_flips": flips,
            "missing_positive_cases": missing_positive,
            "missing_near_miss_cases": missing_near_miss,
            "rejected_human_reviews": rejected,
        },
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def review(args: argparse.Namespace) -> int:
    receipt_path = Path(args.receipt)
    if ".." in receipt_path.parts or receipt_path.is_symlink() or not receipt_path.is_file():
        raise RunError("receipt must be an existing non-symlink file")
    try:
        receipt = json.loads(receipt_path.read_text())
    except json.JSONDecodeError as exc:
        raise RunError("receipt is malformed") from exc
    if receipt.get("lane") != "output" or not output_receipt_passes(receipt):
        raise RunError("only passing output receipts can be reviewed")
    eval_path = REPO_ROOT / receipt.get("eval_set", {}).get("path", "")
    eval_set = EVAL.load_eval_set(str(eval_path))
    case = EVAL.find_runtime_case(eval_set, receipt.get("case", {}).get("id", ""))
    if not receipt_current(receipt, current_binding(eval_path, case, "output")):
        raise RunError("receipt is stale")
    receipt["human_review"] = {"status": args.status, "reviewed_at": utc_now(), "note": args.note}
    data = canonical_bytes(receipt)
    kind = scan_bytes(data)
    if kind:
        raise RunError(f"review-note-secret-scan:{kind}")
    atomic_write(receipt_path.resolve(), data)
    print(json.dumps({"receipt": str(receipt_path.resolve()), "status": args.status}, sort_keys=True))
    return 0


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def positive_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subparsers = root.add_subparsers(dest="command", required=True)
    for name, handler, case_flag in (
        ("run-routing", run_routing, "--routing-case"),
        ("run-output", run_output, "--runtime-case"),
    ):
        command = subparsers.add_parser(name)
        command.add_argument("--eval-set", required=True)
        command.add_argument(case_flag, required=True)
        command.add_argument("--model", required=True)
        command.add_argument("--repetitions", type=positive_int, default=1)
        command.add_argument("--max-budget-usd", type=positive_float, required=True)
        command.add_argument("--timeout-seconds", type=positive_int, required=True)
        command.add_argument("--manifest-dir")
        if name == "run-output":
            command.add_argument("--output-dir")
        command.set_defaults(handler=handler)
    command = subparsers.add_parser("coverage")
    command.add_argument("--eval-set", action="append", required=True)
    command.add_argument("--manifest-dir", required=True)
    command.set_defaults(handler=coverage)
    command = subparsers.add_parser("review")
    command.add_argument("--receipt", required=True)
    command.add_argument("--status", choices=("accepted", "rejected"), required=True)
    command.add_argument("--note", required=True)
    command.set_defaults(handler=review)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.handler(args))
    except (RunError, EVAL.EvalError, OSError, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
