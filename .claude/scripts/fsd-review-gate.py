#!/usr/bin/env python3
"""Validate FSD review results and reduce them to deterministic gate actions."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import subprocess
import tempfile
import unicodedata
from pathlib import Path
from typing import Any


REQUIRED_AXES = ("correctness", "test_quality", "verification_evidence")
CONDITIONAL_AXES = (
    "security_privacy",
    "reliability_data",
    "concurrency",
    "compatibility_migration",
    "performance",
    "ui_accessibility",
    "deployment_operability",
)
QUALITY_AXES = REQUIRED_AXES + CONDITIONAL_AXES
AXIS_STATUSES = {"PASS", "FAIL", "UNVERIFIABLE", "NOT_APPLICABLE"}
SEVERITIES = {"P0", "P1", "P2"}
REQUIREMENT_STATUSES = {"SATISFIED", "MISSING", "UNVERIFIABLE"}
INVENTORY_STATUSES = {"COMPLETE", "INCOMPLETE", "UNVERIFIABLE"}
QUALITY_REVIEW_LENSES = {
    "problem_fit": ("correctness",),
    "simple_design": ("correctness",),
    "architecture_boundaries": (
        "correctness",
        "security_privacy",
        "reliability_data",
        "compatibility_migration",
        "deployment_operability",
    ),
    "comment_quality": ("correctness",),
}
# A diff that neither adds nor touches a comment has nothing for this lens to judge,
# so it is the only lens that may come back NOT_APPLICABLE.
OPTIONAL_QUALITY_LENS = "comment_quality"
# The combined kind carries only severities that gate. A deferred nit has no
# severity field at all, so the "P2 must not be autofixable" rule that a reviewer
# can silently violate simply has nothing to attach to.
BLOCKING_SEVERITIES = ("P0", "P1")
DEFERRED_LIMIT = 25
DEFERRED_MAX_CHARS = 240
KINDS = ("quality", "spec", "combined")
# There is no repair round to exhaust in a single pass, so the reducer never emits
# this blocker for the combined kind and a reviewer must not claim it either.
COMBINED_EXCLUDED_BLOCKER = "QA_REPAIR_EXHAUSTED"
HUMAN_BLOCKERS = {
    "PRODUCT_DECISION",
    "CONTRACT_CONFLICT",
    "CREDENTIAL_OR_PERMISSION",
    "EXTERNAL_OR_CROSS_OWNER",
    "DESTRUCTIVE_OR_IRREVERSIBLE",
    "SECRET_UNCERTAINTY",
    "TEST_ORACLE_AMBIGUITY",
    "QA_REPAIR_EXHAUSTED",
}
OID_RE = re.compile(r"^[0-9a-f]{40,64}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
BUNDLE_PREFIX = "<!-- fsd-artifact: "
BUNDLE_SUFFIX = " -->"
INPUT_LIMIT = 512 * 1024
CONTEXT_REQUEST_LIMIT = 64


class InvalidResult(ValueError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path) -> Any:
    try:
        if path.stat().st_size > INPUT_LIMIT:
            raise InvalidResult(f"JSON input exceeds 512 KiB: {path}")
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise InvalidResult(f"cannot read valid JSON from {path}: {exc}") from exc


def exact_keys(value: Any, keys: set[str], where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InvalidResult(f"{where} must be an object")
    actual = set(value)
    if actual != keys:
        missing = sorted(keys - actual)
        unknown = sorted(actual - keys)
        raise InvalidResult(f"{where} keys mismatch: missing={missing}, unknown={unknown}")
    return value


def nonempty_string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InvalidResult(f"{where} must be a non-empty string")
    try:
        value.encode("utf-8", "strict")
    except UnicodeEncodeError as exc:
        raise InvalidResult(f"{where} must be valid UTF-8") from exc
    return value


def string_list(value: Any, where: str, *, nonempty: bool = False) -> list[str]:
    if not isinstance(value, list):
        raise InvalidResult(f"{where} must be a list of non-empty strings")
    if nonempty and not value:
        raise InvalidResult(f"{where} must not be empty")
    for index, item in enumerate(value):
        nonempty_string(item, f"{where}[{index}]")
    return value


def enum_string(value: Any, allowed: set[str] | tuple[str, ...], where: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise InvalidResult(f"{where} is invalid")
    return value


def strict_bool(value: Any, where: str) -> bool:
    if type(value) is not bool:
        raise InvalidResult(f"{where} must be boolean")
    return value


def line_number(value: Any, where: str) -> int:
    if type(value) is not int or value < 0:
        raise InvalidResult(f"{where} must be a non-negative integer")
    return value


def normalize_path(value: Any, where: str) -> str:
    value = nonempty_string(value, where)
    path = unicodedata.normalize("NFC", value).replace("\\", "/")
    if "\0" in path or path.startswith("/"):
        raise InvalidResult(f"{where} must be a relative UTF-8 repository path")
    while path.startswith("./"):
        path = path[2:]
    if not path or any(part == ".." for part in path.split("/")):
        raise InvalidResult(f"{where} must not be empty or traverse parents")
    path = posixpath.normpath(path)
    if path in ("", ".") or path.startswith("../"):
        raise InvalidResult(f"{where} must name a repository file")
    return path


def validate_inventory(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list) or not value:
        raise InvalidResult("inventory must be a non-empty array")
    result: list[dict[str, str]] = []
    ids: set[str] = set()
    for index, item in enumerate(value, 1):
        item = exact_keys(item, {"ref", "id", "summary"}, f"inventory[{index - 1}]")
        expected_ref = f"REQ-{index:03d}"
        if item["ref"] != expected_ref:
            raise InvalidResult(f"inventory ref must be {expected_ref}")
        requirement_id = nonempty_string(item["id"], f"inventory[{index - 1}].id")
        if requirement_id in ids:
            raise InvalidResult("inventory ids must be unique")
        ids.add(requirement_id)
        result.append(
            {
                "ref": expected_ref,
                "id": requirement_id,
                "summary": nonempty_string(item["summary"], f"inventory[{index - 1}].summary"),
            }
        )
    return result


def parse_bundle(path: Path) -> tuple[dict[str, Any], str]:
    try:
        if path.stat().st_size > INPUT_LIMIT:
            raise InvalidResult("bundle exceeds the 512 KiB limit")
        data = path.read_bytes()
        first = data.splitlines()[0].decode("utf-8", "strict")
    except (OSError, UnicodeError, IndexError) as exc:
        raise InvalidResult(f"cannot read bundle metadata: {exc}") from exc
    if not first.startswith(BUNDLE_PREFIX) or not first.endswith(BUNDLE_SUFFIX):
        raise InvalidResult("bundle is missing the fsd-artifact metadata header")
    try:
        metadata = json.loads(first[len(BUNDLE_PREFIX) : -len(BUNDLE_SUFFIX)])
    except json.JSONDecodeError as exc:
        raise InvalidResult(f"bundle metadata is malformed: {exc}") from exc
    metadata = exact_keys(
        metadata,
        {
            "schema_version",
            "base_oid",
            "current_base_oid",
            "head_oid",
            "candidate_tree_oid",
            "contract_inventory_sha256",
            "current_candidate_tree_oid",
            "changed_path_count",
            "changed_paths_sha256",
            "evidence_candidate_tree_oid",
            "evidence",
            "context_blob_metadata",
            "evidence_gaps",
            "binary_path_metadata",
        },
        "bundle metadata",
    )
    if metadata.get("schema_version") != 1:
        raise InvalidResult("bundle metadata schema_version is invalid")
    for key in ("base_oid", "current_base_oid", "head_oid", "candidate_tree_oid", "current_candidate_tree_oid"):
        if not isinstance(metadata[key], str) or not OID_RE.fullmatch(metadata[key]):
            raise InvalidResult(f"bundle metadata {key} is invalid")
    if not isinstance(metadata["contract_inventory_sha256"], str) or not SHA256_RE.fullmatch(
        metadata["contract_inventory_sha256"]
    ):
        raise InvalidResult("bundle metadata contract_inventory_sha256 is invalid")
    if metadata["evidence_candidate_tree_oid"] != metadata["candidate_tree_oid"]:
        raise InvalidResult("bundle evidence is not bound to candidate_tree_oid")
    if type(metadata["changed_path_count"]) is not int or metadata["changed_path_count"] < 0:
        raise InvalidResult("bundle metadata changed_path_count is invalid")
    if not isinstance(metadata["changed_paths_sha256"], str) or not SHA256_RE.fullmatch(
        metadata["changed_paths_sha256"]
    ):
        raise InvalidResult("bundle metadata changed_paths_sha256 is invalid")
    evidence = exact_keys(
        metadata["evidence"], {"byte_count", "sha256", "encoding", "truncated"}, "bundle evidence"
    )
    if type(evidence["byte_count"]) is not int or evidence["byte_count"] < 0:
        raise InvalidResult("bundle evidence byte_count is invalid")
    if not isinstance(evidence["sha256"], str) or not SHA256_RE.fullmatch(evidence["sha256"]):
        raise InvalidResult("bundle evidence sha256 is invalid")
    enum_string(evidence["encoding"], {"utf-8", "binary"}, "bundle evidence encoding")
    strict_bool(evidence["truncated"], "bundle evidence truncated")
    if not isinstance(metadata["context_blob_metadata"], list):
        raise InvalidResult("bundle context_blob_metadata must be an array")
    allowed_context_keys = {
        "tree", "tree_oid", "path", "mode", "type", "oid", "byte_count", "sha256",
        "encoding", "truncated", "evidence_gap",
    }
    for index, context in enumerate(metadata["context_blob_metadata"]):
        if not isinstance(context, dict) or not {"tree", "tree_oid", "path"}.issubset(context):
            raise InvalidResult(f"bundle context_blob_metadata[{index}] is malformed")
        if set(context) - allowed_context_keys:
            raise InvalidResult(f"bundle context_blob_metadata[{index}] has unknown keys")
        enum_string(context["tree"], {"BASE", "CANDIDATE"}, f"bundle context[{index}].tree")
        if not isinstance(context["tree_oid"], str) or not OID_RE.fullmatch(context["tree_oid"]):
            raise InvalidResult(f"bundle context[{index}].tree_oid is invalid")
        expected_context_oid = (
            metadata["base_oid"] if context["tree"] == "BASE" else metadata["candidate_tree_oid"]
        )
        if context["tree_oid"] != expected_context_oid:
            raise InvalidResult(f"bundle context[{index}].tree_oid is stale")
        normalize_path(context["path"], f"bundle context[{index}].path")
        for key in ("byte_count",):
            if key in context and (type(context[key]) is not int or context[key] < 0):
                raise InvalidResult(f"bundle context[{index}].{key} is invalid")
        if "sha256" in context and (
            not isinstance(context["sha256"], str) or not SHA256_RE.fullmatch(context["sha256"])
        ):
            raise InvalidResult(f"bundle context[{index}].sha256 is invalid")
        if "truncated" in context:
            strict_bool(context["truncated"], f"bundle context[{index}].truncated")
        if "encoding" in context:
            enum_string(context["encoding"], {"utf-8", "binary"}, f"bundle context[{index}].encoding")
        if "evidence_gap" in context:
            nonempty_string(context["evidence_gap"], f"bundle context[{index}].evidence_gap")
    if not isinstance(metadata["evidence_gaps"], list):
        raise InvalidResult("bundle evidence_gaps must be an array")
    normalized_gaps: list[dict[str, str]] = []
    for index, gap in enumerate(metadata["evidence_gaps"]):
        gap = exact_keys(gap, {"tree", "path", "reason"}, f"bundle evidence_gaps[{index}]")
        normalized_gaps.append(
            {
                "tree": enum_string(gap["tree"], {"BASE", "CANDIDATE"}, f"bundle gap[{index}].tree"),
                "path": normalize_path(gap["path"], f"bundle gap[{index}].path"),
                "reason": nonempty_string(gap["reason"], f"bundle gap[{index}].reason"),
            }
        )
    metadata["evidence_gaps"] = normalized_gaps
    if not isinstance(metadata["binary_path_metadata"], list):
        raise InvalidResult("bundle binary_path_metadata must be an array")
    for index, item in enumerate(metadata["binary_path_metadata"]):
        item = exact_keys(item, {"path", "base", "candidate"}, f"bundle binary[{index}]")
        normalize_path(item["path"], f"bundle binary[{index}].path")
        for side in ("base", "candidate"):
            entry = item[side]
            if entry is None:
                continue
            entry = exact_keys(entry, {"mode", "type", "oid", "byte_count"}, f"bundle binary[{index}].{side}")
            nonempty_string(entry["mode"], f"bundle binary[{index}].{side}.mode")
            nonempty_string(entry["type"], f"bundle binary[{index}].{side}.type")
            if not isinstance(entry["oid"], str) or not OID_RE.fullmatch(entry["oid"]):
                raise InvalidResult(f"bundle binary[{index}].{side}.oid is invalid")
            if type(entry["byte_count"]) is not int or entry["byte_count"] < 0:
                raise InvalidResult(f"bundle binary[{index}].{side}.byte_count is invalid")
    return metadata, digest(data)


def git(repo: Path, *args: str, env: dict[str, str] | None = None, check: bool = True) -> bytes:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=merged_env,
    )
    if check and result.returncode != 0:
        raise InvalidResult(result.stderr.decode("utf-8", "replace").strip() or "git command failed")
    return result.stdout


def current_candidate_tree(repo: Path) -> str:
    with tempfile.TemporaryDirectory(prefix="fsd-review-index-") as temp_dir:
        env = {"GIT_INDEX_FILE": str(Path(temp_dir) / "index")}
        git(repo, "read-tree", "HEAD", env=env)
        git(repo, "add", "-A", "--", ".", env=env)
        return git(repo, "write-tree", env=env).decode("ascii").strip()


def validate_artifact(value: Any) -> dict[str, str]:
    artifact = exact_keys(
        value,
        {"base_oid", "candidate_tree_oid", "bundle_sha256", "contract_inventory_sha256"},
        "artifact",
    )
    for key in ("base_oid", "candidate_tree_oid"):
        if not isinstance(artifact[key], str) or not OID_RE.fullmatch(artifact[key]):
            raise InvalidResult(f"artifact.{key} must be a lowercase Git OID")
    for key in ("bundle_sha256", "contract_inventory_sha256"):
        if not isinstance(artifact[key], str) or not SHA256_RE.fullmatch(artifact[key]):
            raise InvalidResult(f"artifact.{key} must be a lowercase SHA-256")
    return artifact


def validate_context_requests(
    value: Any,
    *,
    kind: str,
    axes: set[str],
    finding_refs: set[str],
    requirement_refs: set[str],
    scope_refs: set[str],
) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise InvalidResult("context_requests must be an array")
    if len(value) > CONTEXT_REQUEST_LIMIT:
        raise InvalidResult(f"context_requests must contain at most {CONTEXT_REQUEST_LIMIT} items")
    result: list[dict[str, str]] = []
    refs: set[str] = set()
    for index, request in enumerate(value):
        request = exact_keys(
            request,
            {"ref", "target_type", "target_ref", "tree", "path", "reason"},
            f"context_requests[{index}]",
        )
        ref = nonempty_string(request["ref"], f"context_requests[{index}].ref")
        if ref in refs:
            raise InvalidResult("context request refs must be unique")
        refs.add(ref)
        if kind == "quality":
            allowed_targets = {"axis": axes, "finding": finding_refs}
        elif kind == "spec":
            allowed_targets = {
                "inventory": {"INVENTORY"},
                "requirement": requirement_refs,
                "scope_creep": scope_refs,
            }
        else:
            allowed_targets = {
                "axis": axes,
                "finding": finding_refs,
                "inventory": {"INVENTORY"},
                "requirement": requirement_refs,
                "scope_creep": scope_refs,
            }
        target_type = enum_string(
            request["target_type"], set(allowed_targets), f"context_requests[{index}].target_type"
        )
        target_ref = nonempty_string(request["target_ref"], f"context_requests[{index}].target_ref")
        if target_ref not in allowed_targets[target_type]:
            raise InvalidResult(f"context_requests[{index}] target is not linked to this result")
        tree = enum_string(
            request["tree"], ("BASE", "CANDIDATE"), f"context_requests[{index}].tree"
        )
        result.append(
            {
                "ref": ref,
                "target_type": target_type,
                "target_ref": target_ref,
                "tree": tree,
                "path": normalize_path(request["path"], f"context_requests[{index}].path"),
                "reason": nonempty_string(request["reason"], f"context_requests[{index}].reason"),
            }
        )
    return result


def validate_finding(value: Any, index: int) -> dict[str, Any]:
    finding = exact_keys(
        value,
        {
            "ref",
            "axis",
            "severity",
            "path",
            "line",
            "behavior",
            "consequence",
            "evidence",
            "smallest_fix",
            "verification",
            "autofixable",
            "human_blocker",
        },
        f"findings[{index}]",
    )
    ref = nonempty_string(finding["ref"], f"findings[{index}].ref")
    axis = enum_string(finding["axis"], QUALITY_AXES, f"findings[{index}].axis")
    severity = enum_string(finding["severity"], SEVERITIES, f"findings[{index}].severity")
    path = None if finding["path"] is None else normalize_path(finding["path"], f"findings[{index}].path")
    autofixable = strict_bool(finding["autofixable"], f"findings[{index}].autofixable")
    blocker = finding["human_blocker"]
    if blocker is not None:
        blocker = enum_string(blocker, HUMAN_BLOCKERS, f"findings[{index}].human_blocker")
    if severity in ("P0", "P1"):
        if autofixable == (blocker is not None):
            raise InvalidResult(f"findings[{index}] must be autofixable or have one human blocker")
    elif autofixable or blocker is not None:
        raise InvalidResult("P2 findings must be deferred without autofix or a human blocker")
    return {
        **finding,
        "ref": ref,
        "axis": axis,
        "severity": severity,
        "path": path,
        "line": line_number(finding["line"], f"findings[{index}].line"),
        "behavior": nonempty_string(finding["behavior"], f"findings[{index}].behavior"),
        "consequence": nonempty_string(finding["consequence"], f"findings[{index}].consequence"),
        "evidence": string_list(finding["evidence"], f"findings[{index}].evidence", nonempty=True),
        "smallest_fix": nonempty_string(finding["smallest_fix"], f"findings[{index}].smallest_fix"),
        "verification": nonempty_string(finding["verification"], f"findings[{index}].verification"),
        "autofixable": autofixable,
        "human_blocker": blocker,
    }


def validate_quality(value: Any) -> dict[str, Any]:
    result = exact_keys(
        value,
        {
            "schema_version",
            "kind",
            "artifact",
            "axes",
            "lens_coverage",
            "findings",
            "context_requests",
        },
        "quality result",
    )
    if type(result["schema_version"]) is not int or result["schema_version"] != 1 or result["kind"] != "quality":
        raise InvalidResult("quality schema_version or kind is invalid")
    artifact = validate_artifact(result["artifact"])
    axes = exact_keys(result["axes"], set(QUALITY_AXES), "axes")
    normalized_axes: dict[str, dict[str, Any]] = {}
    for axis in QUALITY_AXES:
        item = exact_keys(axes[axis], {"status", "evidence", "reason"}, f"axes.{axis}")
        status = enum_string(item["status"], AXIS_STATUSES, f"axes.{axis}.status")
        if axis in REQUIRED_AXES and status == "NOT_APPLICABLE":
            raise InvalidResult(f"required axis {axis} cannot be NOT_APPLICABLE")
        evidence = string_list(item["evidence"], f"axes.{axis}.evidence")
        if status == "PASS" and not evidence:
            raise InvalidResult(f"PASS axis {axis} requires evidence")
        if axis == "test_quality" and status == "PASS":
            theater = ("grep", "coverage", "snapshot", "test count")
            if evidence and all(any(term in entry.lower() for term in theater) for entry in evidence):
                raise InvalidResult("test_quality cannot PASS on grep, coverage, snapshot, or test count alone")
        normalized_axes[axis] = {
            "status": status,
            "evidence": evidence,
            "reason": nonempty_string(item["reason"], f"axes.{axis}.reason"),
        }
    if not isinstance(result["findings"], list):
        raise InvalidResult("findings must be an array")
    findings = [validate_finding(item, index) for index, item in enumerate(result["findings"])]
    finding_refs = [item["ref"] for item in findings]
    if len(finding_refs) != len(set(finding_refs)):
        raise InvalidResult("finding refs must be unique")
    contexts = validate_context_requests(
        result["context_requests"],
        kind="quality",
        axes=set(QUALITY_AXES),
        finding_refs=set(finding_refs),
        requirement_refs=set(),
        scope_refs=set(),
    )
    context_axes = {item["target_ref"] for item in contexts if item["target_type"] == "axis"}
    context_findings = {item["target_ref"] for item in contexts if item["target_type"] == "finding"}
    for axis, item in normalized_axes.items():
        blocking = [finding for finding in findings if finding["axis"] == axis and finding["severity"] in ("P0", "P1")]
        if item["status"] == "FAIL" and not blocking:
            raise InvalidResult(f"FAIL axis {axis} requires a P0/P1 finding")
        if item["status"] in ("PASS", "NOT_APPLICABLE") and blocking:
            raise InvalidResult(f"axis {axis} contradicts its blocking finding")
        if item["status"] == "UNVERIFIABLE":
            has_context = axis in context_axes or any(finding["ref"] in context_findings for finding in blocking)
            has_blocker = any(finding["human_blocker"] for finding in blocking)
            if not has_context and not has_blocker:
                raise InvalidResult(f"UNVERIFIABLE axis {axis} requires linked context or a human blocker")
    lenses = exact_keys(result["lens_coverage"], set(QUALITY_REVIEW_LENSES), "lens_coverage")
    normalized_lenses: dict[str, dict[str, Any]] = {}
    for lens, mapped_axes in QUALITY_REVIEW_LENSES.items():
        item = exact_keys(lenses[lens], {"status", "evidence", "reason"}, f"lens_coverage.{lens}")
        status = enum_string(item["status"], AXIS_STATUSES, f"lens_coverage.{lens}.status")
        if lens != OPTIONAL_QUALITY_LENS and status == "NOT_APPLICABLE":
            raise InvalidResult(f"quality lens {lens} cannot be NOT_APPLICABLE")
        evidence = string_list(item["evidence"], f"lens_coverage.{lens}.evidence")
        if status == "PASS" and not evidence:
            raise InvalidResult(f"PASS quality lens {lens} requires evidence")
        mapped_findings = [
            finding
            for finding in findings
            if finding["axis"] in mapped_axes and finding["severity"] in ("P0", "P1")
        ]
        if status == "FAIL" and not mapped_findings:
            raise InvalidResult(f"FAIL quality lens {lens} requires a mapped P0/P1 finding")
        if status == "UNVERIFIABLE" and not any(
            normalized_axes[axis]["status"] == "UNVERIFIABLE" for axis in mapped_axes
        ):
            raise InvalidResult(f"UNVERIFIABLE quality lens {lens} requires a mapped unverifiable axis")
        normalized_lenses[lens] = {
            "status": status,
            "evidence": evidence,
            "reason": nonempty_string(item["reason"], f"lens_coverage.{lens}.reason"),
        }
    return {
        "artifact": artifact,
        "axes": normalized_axes,
        "lens_coverage": normalized_lenses,
        "findings": findings,
        "context_requests": contexts,
    }


def validate_inventory_assessment(value: Any) -> dict[str, Any]:
    item = exact_keys(
        value,
        {"status", "evidence", "reason", "autofixable", "human_blocker"},
        "inventory_assessment",
    )
    status = enum_string(item["status"], INVENTORY_STATUSES, "inventory_assessment.status")
    evidence = string_list(item["evidence"], "inventory_assessment.evidence", nonempty=True)
    autofixable = strict_bool(item["autofixable"], "inventory_assessment.autofixable")
    blocker = item["human_blocker"]
    if blocker is not None:
        blocker = enum_string(blocker, HUMAN_BLOCKERS, "inventory_assessment.human_blocker")
    if status == "COMPLETE" and (autofixable or blocker is not None):
        raise InvalidResult("COMPLETE inventory cannot be autofixable or blocked")
    if status == "INCOMPLETE" and autofixable == (blocker is not None):
        raise InvalidResult("INCOMPLETE inventory must be autofixable or have one human blocker")
    if status == "UNVERIFIABLE" and autofixable:
        raise InvalidResult("UNVERIFIABLE inventory cannot be autofixable")
    return {
        "status": status,
        "evidence": evidence,
        "reason": nonempty_string(item["reason"], "inventory_assessment.reason"),
        "autofixable": autofixable,
        "human_blocker": blocker,
    }


def validate_requirement(value: Any, inventory_item: dict[str, str], index: int) -> dict[str, Any]:
    item = exact_keys(
        value,
        {"ref", "id", "summary", "status", "evidence", "autofixable", "human_blocker"},
        f"requirements[{index}]",
    )
    for key in ("ref", "id", "summary"):
        if item[key] != inventory_item[key]:
            raise InvalidResult(f"requirements[{index}].{key} does not exactly match inventory")
    status = enum_string(item["status"], REQUIREMENT_STATUSES, f"requirements[{index}].status")
    evidence = string_list(item["evidence"], f"requirements[{index}].evidence", nonempty=True)
    autofixable = strict_bool(item["autofixable"], f"requirements[{index}].autofixable")
    blocker = item["human_blocker"]
    if blocker is not None:
        blocker = enum_string(blocker, HUMAN_BLOCKERS, f"requirements[{index}].human_blocker")
    if status == "SATISFIED" and (autofixable or blocker is not None):
        raise InvalidResult("SATISFIED requirements cannot be autofixable or blocked")
    if status == "MISSING" and autofixable == (blocker is not None):
        raise InvalidResult("MISSING requirements must be autofixable or have one human blocker")
    if status == "UNVERIFIABLE" and autofixable:
        raise InvalidResult("UNVERIFIABLE requirements cannot be autofixable")
    return {
        **item,
        "status": status,
        "evidence": evidence,
        "autofixable": autofixable,
        "human_blocker": blocker,
    }


def validate_scope(value: Any, index: int) -> dict[str, Any]:
    item = exact_keys(
        value,
        {"ref", "path", "line", "behavior", "consequence", "evidence", "autofixable", "human_blocker"},
        f"scope_creep[{index}]",
    )
    autofixable = strict_bool(item["autofixable"], f"scope_creep[{index}].autofixable")
    blocker = item["human_blocker"]
    if blocker is not None:
        blocker = enum_string(blocker, HUMAN_BLOCKERS, f"scope_creep[{index}].human_blocker")
    if autofixable == (blocker is not None):
        raise InvalidResult("scope creep must be autofixable or have one human blocker")
    return {
        **item,
        "ref": nonempty_string(item["ref"], f"scope_creep[{index}].ref"),
        "path": normalize_path(item["path"], f"scope_creep[{index}].path"),
        "line": line_number(item["line"], f"scope_creep[{index}].line"),
        "behavior": nonempty_string(item["behavior"], f"scope_creep[{index}].behavior"),
        "consequence": nonempty_string(item["consequence"], f"scope_creep[{index}].consequence"),
        "evidence": string_list(item["evidence"], f"scope_creep[{index}].evidence", nonempty=True),
        "autofixable": autofixable,
        "human_blocker": blocker,
    }


def validate_spec(value: Any, inventory: list[dict[str, str]]) -> dict[str, Any]:
    result = exact_keys(
        value,
        {
            "schema_version",
            "kind",
            "artifact",
            "inventory_assessment",
            "requirements",
            "scope_creep",
            "context_requests",
        },
        "spec result",
    )
    if type(result["schema_version"]) is not int or result["schema_version"] != 1 or result["kind"] != "spec":
        raise InvalidResult("spec schema_version or kind is invalid")
    artifact = validate_artifact(result["artifact"])
    inventory_assessment = validate_inventory_assessment(result["inventory_assessment"])
    if not isinstance(result["requirements"], list) or len(result["requirements"]) != len(inventory):
        raise InvalidResult("requirements must have the exact inventory length")
    requirements = [
        validate_requirement(item, inventory[index], index)
        for index, item in enumerate(result["requirements"])
    ]
    if not isinstance(result["scope_creep"], list):
        raise InvalidResult("scope_creep must be an array")
    scope = [validate_scope(item, index) for index, item in enumerate(result["scope_creep"])]
    scope_refs = [item["ref"] for item in scope]
    if len(scope_refs) != len(set(scope_refs)):
        raise InvalidResult("scope creep refs must be unique")
    contexts = validate_context_requests(
        result["context_requests"],
        kind="spec",
        axes=set(),
        finding_refs=set(),
        requirement_refs={item["ref"] for item in requirements},
        scope_refs=set(scope_refs),
    )
    context_targets = {(item["target_type"], item["target_ref"]) for item in contexts}
    for item in requirements:
        if item["status"] == "UNVERIFIABLE" and item["human_blocker"] is None:
            if ("requirement", item["ref"]) not in context_targets:
                raise InvalidResult(f"UNVERIFIABLE requirement {item['ref']} requires linked context")
    if inventory_assessment["status"] == "UNVERIFIABLE" and inventory_assessment["human_blocker"] is None:
        if ("inventory", "INVENTORY") not in context_targets:
            raise InvalidResult("UNVERIFIABLE inventory requires linked context")
    return {
        "artifact": artifact,
        "inventory_assessment": inventory_assessment,
        "requirements": requirements,
        "scope_creep": scope,
        "context_requests": contexts,
    }


def validate_blocking_finding(value: Any, index: int) -> dict[str, Any]:
    """A combined-kind finding. Only P0/P1 are representable, so a reviewer cannot
    file a deferred nit here with repair fields it was never allowed to set."""
    finding = exact_keys(
        value,
        {
            "ref",
            "axis",
            "severity",
            "path",
            "line",
            "behavior",
            "consequence",
            "evidence",
            "smallest_fix",
            "verification",
            "autofixable",
            "human_blocker",
        },
        f"findings[{index}]",
    )
    severity = enum_string(finding["severity"], set(BLOCKING_SEVERITIES), f"findings[{index}].severity")
    autofixable = strict_bool(finding["autofixable"], f"findings[{index}].autofixable")
    blocker = finding["human_blocker"]
    if blocker is not None:
        blocker = enum_string(
            blocker, HUMAN_BLOCKERS - {COMBINED_EXCLUDED_BLOCKER}, f"findings[{index}].human_blocker"
        )
    if autofixable == (blocker is not None):
        raise InvalidResult(f"findings[{index}] must be autofixable or have one human blocker")
    return {
        "ref": nonempty_string(finding["ref"], f"findings[{index}].ref"),
        "axis": enum_string(finding["axis"], QUALITY_AXES, f"findings[{index}].axis"),
        "severity": severity,
        "path": None if finding["path"] is None else normalize_path(finding["path"], f"findings[{index}].path"),
        "line": line_number(finding["line"], f"findings[{index}].line"),
        "behavior": nonempty_string(finding["behavior"], f"findings[{index}].behavior"),
        "consequence": nonempty_string(finding["consequence"], f"findings[{index}].consequence"),
        "evidence": string_list(finding["evidence"], f"findings[{index}].evidence", nonempty=True),
        "smallest_fix": nonempty_string(finding["smallest_fix"], f"findings[{index}].smallest_fix"),
        "verification": nonempty_string(finding["verification"], f"findings[{index}].verification"),
        "autofixable": autofixable,
        "human_blocker": blocker,
    }


def validate_deferred(value: Any) -> list[str]:
    """Deferred observations are plain one-line strings. They never gate, so giving
    them structure would only buy schema surface a reviewer can trip over."""
    if not isinstance(value, list):
        raise InvalidResult("deferred must be an array of strings")
    notes: list[str] = []
    # These never gate, so length is bounded by trimming rather than by failing the
    # whole review over a field that carries no decision.
    for index, item in enumerate(value[:DEFERRED_LIMIT]):
        note = " ".join(nonempty_string(item, f"deferred[{index}]").split())
        notes.append(note[: DEFERRED_MAX_CHARS - 1] + "…" if len(note) > DEFERRED_MAX_CHARS else note)
    return notes


def validate_requirement_exception(value: Any, allowed_refs: set[str], index: int) -> dict[str, Any]:
    item = exact_keys(
        value,
        {"ref", "status", "evidence", "autofixable", "human_blocker"},
        f"requirement_exceptions[{index}]",
    )
    ref = nonempty_string(item["ref"], f"requirement_exceptions[{index}].ref")
    if ref not in allowed_refs:
        raise InvalidResult(f"requirement_exceptions[{index}].ref is not in the inventory")
    status = enum_string(
        item["status"], {"MISSING", "UNVERIFIABLE"}, f"requirement_exceptions[{index}].status"
    )
    autofixable = strict_bool(item["autofixable"], f"requirement_exceptions[{index}].autofixable")
    blocker = item["human_blocker"]
    if blocker is not None:
        blocker = enum_string(blocker, HUMAN_BLOCKERS, f"requirement_exceptions[{index}].human_blocker")
    if status == "MISSING" and autofixable == (blocker is not None):
        raise InvalidResult(f"MISSING requirement {ref} must be autofixable or have one human blocker")
    if status == "UNVERIFIABLE" and autofixable:
        raise InvalidResult(f"UNVERIFIABLE requirement {ref} cannot be autofixable")
    return {
        "ref": ref,
        "status": status,
        "evidence": string_list(item["evidence"], f"requirement_exceptions[{index}].evidence", nonempty=True),
        "autofixable": autofixable,
        "human_blocker": blocker,
    }


def validate_combined(value: Any, inventory: list[dict[str, str]]) -> dict[str, Any]:
    """One review covering both code quality and spec conformance.

    Two shape choices carry most of the token saving. Axis and lens prose is
    required only where the status carries a decision - a PASS conditional axis
    proves it was looked at with one evidence string instead of a paragraph. And
    requirements come back as a {ref: status} map, which still proves the reviewer
    enumerated every one of them while dropping the verbatim summary echo that
    made the old spec result mostly a copy of its own input.
    """
    result = exact_keys(
        value,
        {
            "schema_version",
            "kind",
            "artifact",
            "axes",
            "lenses",
            "findings",
            "deferred",
            "requirements",
            "requirement_exceptions",
            "inventory_assessment",
            "scope_creep",
            "context_requests",
        },
        "combined result",
    )
    if type(result["schema_version"]) is not int or result["schema_version"] != 1 or result["kind"] != "combined":
        raise InvalidResult("combined schema_version or kind is invalid")
    artifact = validate_artifact(result["artifact"])

    axes = exact_keys(result["axes"], set(QUALITY_AXES), "axes")
    normalized_axes: dict[str, dict[str, Any]] = {}
    for axis in QUALITY_AXES:
        item = axes[axis]
        if not isinstance(item, dict) or "status" not in item:
            raise InvalidResult(f"axes.{axis} must be an object with a status")
        status = enum_string(item["status"], AXIS_STATUSES, f"axes.{axis}.status")
        needs_reason = status != "PASS" or axis in REQUIRED_AXES
        # A reason is required where the status carries a decision and merely
        # unnecessary elsewhere. Rejecting a reviewer for supplying more than it
        # was asked for is the exact failure this schema exists to stop.
        if set(item) - {"status", "evidence", "reason"}:
            item = exact_keys(item, {"status", "evidence", "reason"}, f"axes.{axis}")
        if "evidence" not in item:
            raise InvalidResult(f"axes.{axis} keys mismatch: missing=['evidence']")
        if axis in REQUIRED_AXES and status == "NOT_APPLICABLE":
            raise InvalidResult(f"required axis {axis} cannot be NOT_APPLICABLE")
        evidence = string_list(item["evidence"], f"axes.{axis}.evidence")
        if status == "PASS" and not evidence:
            raise InvalidResult(f"PASS axis {axis} requires evidence")
        if axis == "test_quality" and status == "PASS":
            theater = ("grep", "coverage", "snapshot", "test count")
            if evidence and all(any(term in entry.lower() for term in theater) for entry in evidence):
                raise InvalidResult("test_quality cannot PASS on grep, coverage, snapshot, or test count alone")
        normalized_axes[axis] = {"status": status, "evidence": evidence}
        if needs_reason:
            normalized_axes[axis]["reason"] = nonempty_string(item["reason"], f"axes.{axis}.reason")

    if not isinstance(result["findings"], list):
        raise InvalidResult("findings must be an array")
    findings = [validate_blocking_finding(item, index) for index, item in enumerate(result["findings"])]
    finding_refs = [item["ref"] for item in findings]
    if len(finding_refs) != len(set(finding_refs)):
        raise InvalidResult("finding refs must be unique")
    deferred = validate_deferred(result["deferred"])

    inventory_refs = [item["ref"] for item in inventory]
    requirements = result["requirements"]
    if not isinstance(requirements, dict):
        raise InvalidResult("requirements must be an object keyed by inventory ref")
    # Coverage is the property that matters; key order carries no information, so
    # requiring it would only add a way to fail a complete answer.
    if set(requirements) != set(inventory_refs):
        missing = sorted(set(inventory_refs) - set(requirements))
        unknown = sorted(set(requirements) - set(inventory_refs))
        raise InvalidResult(f"requirements must cover every inventory ref: missing={missing}, unknown={unknown}")
    normalized_requirements = {
        ref: enum_string(requirements[ref], REQUIREMENT_STATUSES, f"requirements.{ref}")
        for ref in inventory_refs
    }
    if not isinstance(result["requirement_exceptions"], list):
        raise InvalidResult("requirement_exceptions must be an array")
    exceptions = [
        validate_requirement_exception(item, set(inventory_refs), index)
        for index, item in enumerate(result["requirement_exceptions"])
    ]
    exception_refs = [item["ref"] for item in exceptions]
    if len(exception_refs) != len(set(exception_refs)):
        raise InvalidResult("requirement_exceptions refs must be unique")
    flagged = {ref for ref, status in normalized_requirements.items() if status != "SATISFIED"}
    if flagged != set(exception_refs):
        raise InvalidResult("every non-SATISFIED requirement needs exactly one matching exception entry")
    for item in exceptions:
        if item["status"] != normalized_requirements[item["ref"]]:
            raise InvalidResult(f"requirement_exceptions {item['ref']} status disagrees with requirements")

    inventory_assessment = validate_inventory_assessment(result["inventory_assessment"])
    if not isinstance(result["scope_creep"], list):
        raise InvalidResult("scope_creep must be an array")
    scope = [validate_scope(item, index) for index, item in enumerate(result["scope_creep"])]
    scope_refs = [item["ref"] for item in scope]
    if len(scope_refs) != len(set(scope_refs)):
        raise InvalidResult("scope creep refs must be unique")

    contexts = validate_context_requests(
        result["context_requests"],
        kind="combined",
        axes=set(QUALITY_AXES),
        finding_refs=set(finding_refs),
        requirement_refs=set(inventory_refs),
        scope_refs=set(scope_refs),
    )
    context_axes = {item["target_ref"] for item in contexts if item["target_type"] == "axis"}
    context_findings = {item["target_ref"] for item in contexts if item["target_type"] == "finding"}
    context_targets = {(item["target_type"], item["target_ref"]) for item in contexts}

    for axis, item in normalized_axes.items():
        blocking = [finding for finding in findings if finding["axis"] == axis]
        if item["status"] == "FAIL" and not blocking:
            raise InvalidResult(f"FAIL axis {axis} requires a P0/P1 finding")
        if item["status"] in ("PASS", "NOT_APPLICABLE") and blocking:
            raise InvalidResult(f"axis {axis} contradicts its blocking finding")
        if item["status"] == "UNVERIFIABLE":
            has_context = axis in context_axes or any(finding["ref"] in context_findings for finding in blocking)
            has_blocker = any(finding["human_blocker"] for finding in blocking)
            if not has_context and not has_blocker:
                raise InvalidResult(f"UNVERIFIABLE axis {axis} requires linked context or a human blocker")

    lenses = exact_keys(result["lenses"], set(QUALITY_REVIEW_LENSES), "lenses")
    normalized_lenses: dict[str, dict[str, Any]] = {}
    for lens, mapped_axes in QUALITY_REVIEW_LENSES.items():
        item = exact_keys(lenses[lens], {"status", "evidence"}, f"lenses.{lens}")
        status = enum_string(item["status"], AXIS_STATUSES, f"lenses.{lens}.status")
        if lens != OPTIONAL_QUALITY_LENS and status == "NOT_APPLICABLE":
            raise InvalidResult(f"lens {lens} cannot be NOT_APPLICABLE")
        evidence = string_list(item["evidence"], f"lenses.{lens}.evidence")
        if status in ("PASS", "FAIL") and not evidence:
            raise InvalidResult(f"{status} lens {lens} requires evidence")
        mapped_findings = [finding for finding in findings if finding["axis"] in mapped_axes]
        if status == "FAIL" and not mapped_findings:
            raise InvalidResult(f"FAIL lens {lens} requires a mapped P0/P1 finding")
        if status == "UNVERIFIABLE" and not any(
            normalized_axes[axis]["status"] == "UNVERIFIABLE" for axis in mapped_axes
        ):
            raise InvalidResult(f"UNVERIFIABLE lens {lens} requires a mapped unverifiable axis")
        normalized_lenses[lens] = {"status": status, "evidence": evidence}

    for item in exceptions:
        if item["status"] == "UNVERIFIABLE" and item["human_blocker"] is None:
            if ("requirement", item["ref"]) not in context_targets:
                raise InvalidResult(f"UNVERIFIABLE requirement {item['ref']} requires linked context")
    if inventory_assessment["status"] == "UNVERIFIABLE" and inventory_assessment["human_blocker"] is None:
        if ("inventory", "INVENTORY") not in context_targets:
            raise InvalidResult("UNVERIFIABLE inventory requires linked context")

    return {
        "artifact": artifact,
        "axes": normalized_axes,
        "lenses": normalized_lenses,
        "findings": findings,
        "deferred": deferred,
        "requirements": normalized_requirements,
        "requirement_exceptions": exceptions,
        "inventory_assessment": inventory_assessment,
        "scope_creep": scope,
        "context_requests": contexts,
    }


def quality_signature(finding: dict[str, Any]) -> str:
    path = finding["path"] or "@verification"
    return digest(f"quality\0{finding['axis']}\0{finding['severity']}\0{path}".encode("utf-8"))


def spec_signature(requirement: dict[str, Any]) -> str:
    return digest(f"spec-requirement\0{requirement['ref']}".encode("utf-8"))


def inventory_signature() -> str:
    return digest(b"spec-inventory\0incomplete")


def scope_signature(item: dict[str, Any]) -> str:
    return digest(f"scope\0{item['path']}".encode("utf-8"))


def dedupe_contexts(requests: list[dict[str, str]]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for request in requests:
        key = (request["tree"], request["path"])
        if key not in seen:
            seen.add(key)
            result.append(request)
    return result


def dedupe_gaps(gaps: list[dict[str, str]]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()
    for gap in gaps:
        key = (gap["tree"], gap["path"], gap["reason"])
        if key not in seen:
            seen.add(key)
            result.append(gap)
    return result


def context_gaps(repo: Path, metadata: dict[str, Any], requests: list[dict[str, str]]) -> list[dict[str, str]]:
    gaps: list[dict[str, str]] = []
    for request in requests:
        tree_oid = metadata["base_oid"] if request["tree"] == "BASE" else metadata["candidate_tree_oid"]
        pathspec = f":(literal){request['path']}"
        raw = git(repo, "ls-tree", "-z", tree_oid, "--", pathspec, check=False)
        if not raw:
            gaps.append({"tree": request["tree"], "path": request["path"], "reason": "missing_path"})
            continue
        header = raw.split(b"\t", 1)[0].decode("ascii")
        mode, kind, oid = header.split(" ")
        object_type = git(repo, "cat-file", "-t", oid, check=False).decode("ascii", "replace").strip()
        if mode == "120000":
            reason = "symlink"
        elif mode == "160000":
            reason = "gitlink"
        elif kind != "blob":
            reason = "special_file"
        elif object_type != "blob":
            reason = "missing_blob"
        else:
            continue
        gaps.append({"tree": request["tree"], "path": request["path"], "reason": reason})
    return gaps


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {
            "schema_version": 1,
            "pending_repairs": {kind: [] for kind in KINDS},
            "history": [],
        }
    state = read_json(path)
    allowed = {
        "schema_version",
        "pending_repairs",
        "history",
        "qa_round",
        "base_oid",
        "candidate_tree_oid",
        "bundle_sha256",
        "contract_inventory_sha256",
    }
    if not isinstance(state, dict) or not {"schema_version", "pending_repairs", "history"}.issubset(state):
        raise InvalidResult("QA state is malformed")
    if set(state) - allowed or state["schema_version"] != 1:
        raise InvalidResult("QA state keys or version are invalid")
    pending = state["pending_repairs"]
    if not isinstance(pending, dict) or not set(pending) or not set(pending).issubset(set(KINDS)):
        raise InvalidResult("QA pending_repairs is malformed")
    for kind in pending:
        if not isinstance(pending[kind], list) or any(not isinstance(item, str) for item in pending[kind]):
            raise InvalidResult(f"QA pending_repairs.{kind} is malformed")
    if not isinstance(state["history"], list) or any(
        not isinstance(item, dict) for item in state["history"]
    ):
        raise InvalidResult("QA history is malformed")
    return state


def write_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("wb", dir=path.parent, delete=False) as handle:
        handle.write(canonical_bytes(state) + b"\n")
        temp_path = Path(handle.name)
    temp_path.replace(path)


def validate_combined_transition(history: list[dict[str, Any]], round_number: int) -> None:
    """Single-pass sequencing.

    The pass itself happens once. Two attempts do not count against it, because
    neither reflects on the candidate: a result the reducer could not parse is a
    format slip by the reviewer, and a context request means the reviewer could
    not see a blob the bundle should have carried. Letting either consume the one
    pass would turn a clerical problem into a shipped-without-review outcome.
    """
    mine = [item for item in history if item.get("kind") == "combined"]
    if not mine:
        if round_number != 1:
            raise InvalidResult("combined QA must start at round 1")
        return
    last = mine[-1]
    if not isinstance(last, dict) or not {"kind", "qa_round", "action"}.issubset(last):
        raise InvalidResult("QA history entry is malformed")
    last_round = last["qa_round"]
    if type(last_round) is not int or last_round not in (1, 2):
        raise InvalidResult("QA history round is invalid")
    if last["action"] in ("PROCEED", "AUTOFIX", "NEEDS_HUMAN") or last.get("terminal_status"):
        raise InvalidResult("combined QA is already resolved")
    if last["action"] == "INVALID":
        if sum(1 for item in mine if item["action"] == "INVALID") > 1:
            raise InvalidResult("combined QA already used its one malformed-result retry")
        expected = last_round
    elif last["action"] == "CONTEXT":
        if sum(1 for item in mine if item["action"] == "CONTEXT") > 1:
            raise InvalidResult("combined QA already used its one context refill")
        expected = last_round + 1
    elif last["action"] == "STALE":
        raise InvalidResult(
            "the candidate moved after the review; rebuild the bundle from Phase 6 with a fresh QA state file"
        )
    else:
        raise InvalidResult("combined QA has no remaining attempt")
    if round_number != expected:
        raise InvalidResult(f"next combined QA attempt must be round {expected}")


def validate_transition(state: dict[str, Any], kind: str, round_number: int) -> None:
    history = state["history"]
    if kind == "combined" or any(item.get("kind") == "combined" for item in history):
        if kind != "combined":
            raise InvalidResult("this QA state is single-pass; use --kind combined")
        validate_combined_transition(history, round_number)
        return
    if not history:
        if kind != "quality" or round_number != 1:
            raise InvalidResult("QA state must start with quality round 1")
        return
    last = history[-1]
    if not isinstance(last, dict) or not {"kind", "qa_round", "action"}.issubset(last):
        raise InvalidResult("QA history entry is malformed")
    last_round = last["qa_round"]
    if type(last_round) is not int or last_round not in (1, 2, 3):
        raise InvalidResult("QA history round is invalid")
    if last.get("terminal_status") or last["action"] == "NEEDS_HUMAN":
        raise InvalidResult("QA state is already terminal")
    if last["kind"] == "quality" and last["action"] == "PROCEED":
        expected = ("spec", last_round)
    elif last["kind"] == "spec" and last["action"] == "PROCEED":
        raise InvalidResult("QA state is already approved")
    elif last["kind"] in ("quality", "spec") and last_round < 3:
        expected = ("quality", last_round + 1)
    else:
        raise InvalidResult("QA state has no remaining round")
    if (kind, round_number) != expected:
        raise InvalidResult(f"next QA review must be {expected[0]} round {expected[1]}")


def contract(kind: str) -> dict[str, Any]:
    artifact = {
        "base_oid": "copy exactly from the trusted artifact identity",
        "candidate_tree_oid": "copy exactly from the trusted artifact identity",
        "bundle_sha256": "copy exactly from the trusted artifact identity",
        "contract_inventory_sha256": "copy exactly from the trusted artifact identity",
    }
    if kind == "combined":
        return {
            "schema_version": 1,
            "kind": "combined",
            "context_request_limit": CONTEXT_REQUEST_LIMIT,
            "deferred_limit": DEFERRED_LIMIT,
            "artifact": artifact,
            "required_axes": list(REQUIRED_AXES),
            "conditional_axes": list(CONDITIONAL_AXES),
            "review_lenses": {
                lens: {"mapped_axes": list(mapped), "required": lens != OPTIONAL_QUALITY_LENS}
                for lens, mapped in QUALITY_REVIEW_LENSES.items()
            },
            "axis_statuses": sorted(AXIS_STATUSES),
            "requirement_statuses": sorted(REQUIREMENT_STATUSES),
            "finding_severities": list(BLOCKING_SEVERITIES),
            "human_blockers": sorted(HUMAN_BLOCKERS - {COMBINED_EXCLUDED_BLOCKER}),
            "validation_rules": [
                "Return exactly the result_schema keys and no Markdown fences.",
                "Every axis in required_axes plus conditional_axes appears in `axes`. A PASS conditional axis carries only status and one short evidence string - omit `reason` there. Required axes and any non-PASS status carry status, evidence, and reason.",
                "Required axes cannot be NOT_APPLICABLE, and any PASS axis needs evidence.",
                "test_quality cannot PASS on grep, coverage, snapshots, or test count alone.",
                "`findings` holds only P0 and P1 - things that must change before this ships. Each is autofixable or carries exactly one human blocker.",
                "Anything worth mentioning but not worth blocking goes in `deferred` as a one-line string including path:line. These never gate and are never repaired, so keep them short.",
                "`requirements` is an object mapping every inventory ref, in inventory order, to SATISFIED, MISSING, or UNVERIFIABLE. Do not echo the summaries back.",
                "Every non-SATISFIED requirement needs exactly one matching entry in `requirement_exceptions` carrying the evidence.",
                "FAIL needs a linked P0/P1 finding; UNVERIFIABLE needs a linked context request or a human blocker.",
            ],
            "result_schema": {
                "schema_version": 1,
                "kind": "combined",
                "artifact": artifact,
                "axes": {
                    "<required axis>": {
                        "status": "PASS | FAIL | UNVERIFIABLE",
                        "evidence": ["file:line or command result"],
                        "reason": "required explanation",
                    },
                    "<conditional axis, PASS>": {
                        "status": "PASS",
                        "evidence": ["one short file:line or command result"],
                    },
                    "<conditional axis, not PASS>": {
                        "status": "FAIL | UNVERIFIABLE | NOT_APPLICABLE",
                        "evidence": ["file:line or command result"],
                        "reason": "required explanation",
                    },
                },
                "lenses": {
                    lens: {
                        "status": "PASS | FAIL | UNVERIFIABLE"
                        + (" | NOT_APPLICABLE" if lens == OPTIONAL_QUALITY_LENS else ""),
                        "evidence": ["file:line or review observation"],
                    }
                    for lens in QUALITY_REVIEW_LENSES
                },
                "findings": [
                    {
                        "ref": "artifact-local reference",
                        "axis": "one quality axis",
                        "severity": "P0 | P1",
                        "path": "repo-relative path or null",
                        "line": 0,
                        "behavior": "observable defect",
                        "consequence": "escaped regression or operational impact",
                        "evidence": ["file:line, test, or command"],
                        "smallest_fix": "bounded repair",
                        "verification": "exact focused check",
                        "autofixable": True,
                        "human_blocker": None,
                    }
                ],
                "deferred": ["path/to/file.ext:12 - one-line observation that does not gate"],
                "requirements": {"REQ-001": "SATISFIED", "REQ-002": "MISSING"},
                "requirement_exceptions": [
                    {
                        "ref": "REQ-002",
                        "status": "MISSING | UNVERIFIABLE",
                        "evidence": ["file:line, test, or command"],
                        "autofixable": True,
                        "human_blocker": None,
                    }
                ],
                "inventory_assessment": {
                    "status": "COMPLETE | INCOMPLETE | UNVERIFIABLE",
                    "evidence": ["canonical task or design criterion reference"],
                    "reason": "required explanation",
                    "autofixable": False,
                    "human_blocker": None,
                },
                "scope_creep": [
                    {
                        "ref": "SCOPE-001",
                        "path": "repo-relative path",
                        "line": 0,
                        "behavior": "change not traceable to any requirement",
                        "consequence": "review or rollback impact",
                        "evidence": ["file:line"],
                        "autofixable": True,
                        "human_blocker": None,
                    }
                ],
                "context_requests": [
                    {
                        "ref": "CTX-001",
                        "target_type": "axis | finding | inventory | requirement | scope_creep",
                        "target_ref": "linked ref, or INVENTORY",
                        "tree": "BASE | CANDIDATE",
                        "path": "repo-relative path",
                        "reason": "exact missing evidence",
                    }
                ],
            },
        }
    if kind == "quality":
        axis_template = {
            axis: {
                "status": "PASS | FAIL | UNVERIFIABLE | NOT_APPLICABLE",
                "evidence": ["file:line or command result"],
                "reason": "required explanation",
            }
            for axis in QUALITY_AXES
        }
        return {
            "schema_version": 1,
            "kind": "quality",
            "context_request_limit": CONTEXT_REQUEST_LIMIT,
            "artifact": artifact,
            "axes": {axis: {"required": axis in REQUIRED_AXES} for axis in QUALITY_AXES},
            "review_lenses": {
                lens: {"mapped_axes": list(mapped_axes), "required": lens != OPTIONAL_QUALITY_LENS}
                for lens, mapped_axes in QUALITY_REVIEW_LENSES.items()
            },
            "axis_statuses": sorted(AXIS_STATUSES),
            "finding_severities": sorted(SEVERITIES),
            "validation_rules": [
                "Return exactly the result_schema keys and no Markdown fences.",
                "Required axes cannot be NOT_APPLICABLE; PASS needs evidence.",
                "Assess every review lens explicitly; only comment_quality may be NOT_APPLICABLE.",
                "test_quality cannot PASS on grep, coverage, snapshots, or test count alone.",
                "FAIL needs a linked P0/P1 finding; UNVERIFIABLE needs linked context or a human blocker.",
                "P0/P1 is either autofixable with no blocker or non-autofixable with one allowed blocker.",
                "P2 is non-autofixable, has no blocker, and is deferred.",
            ],
            "result_schema": {
                "schema_version": 1,
                "kind": "quality",
                "artifact": artifact,
                "axes": axis_template,
                "lens_coverage": {
                    lens: {
                        "status": "PASS | FAIL | UNVERIFIABLE | NOT_APPLICABLE",
                        "evidence": ["file:line or review observation"],
                        "reason": "required explanation",
                    }
                    for lens in QUALITY_REVIEW_LENSES
                },
                "findings": [
                    {
                        "ref": "artifact-local reference",
                        "axis": "one quality axis",
                        "severity": "P0 | P1 | P2",
                        "path": "repo-relative path or null",
                        "line": 0,
                        "behavior": "observable defect",
                        "consequence": "escaped regression or operational impact",
                        "evidence": ["file:line, test, or command"],
                        "smallest_fix": "bounded repair",
                        "verification": "exact focused check",
                        "autofixable": True,
                        "human_blocker": None,
                    }
                ],
                "context_requests": [
                    {
                        "ref": "CTX-001",
                        "target_type": "axis | finding",
                        "target_ref": "linked axis or finding ref",
                        "tree": "BASE | CANDIDATE",
                        "path": "repo-relative path",
                        "reason": "exact missing evidence",
                    }
                ],
            },
            "test_quality_lenses": [
                "Assert an observable behavioral contract through the real public boundary.",
                "Name plausible mutation or failure power when fresh RED evidence is unavailable.",
                "Cover positive, negative, boundary, and error paths in proportion to risk.",
                "Preserve regression fidelity for the reported bug or changed user path.",
                "Assert values, state, side effects, and required absence conditions concretely.",
                "Isolate clock, random, network, filesystem, environment, and shared state.",
                "Mocks must not bypass the contract the test claims to verify.",
                "Check retry, ordering, concurrency, locale, and timezone determinism when relevant.",
                "Parameterized cases must add distinct behavioral evidence.",
                "source-text grep, incidental snapshots, and line coverage cannot alone prove behavior.",
            ],
            "human_blockers": sorted(HUMAN_BLOCKERS),
        }
    return {
        "schema_version": 1,
        "kind": "spec",
        "context_request_limit": CONTEXT_REQUEST_LIMIT,
        "artifact": artifact,
        "requirement_statuses": sorted(REQUIREMENT_STATUSES),
        "inventory_rule": (
            "Audit the canonical task and Phase 2/design success criteria against the supplied inventory, "
            "report any omitted criterion through inventory_assessment, then preserve requirement count, "
            "order, ref, id, and summary exactly"
        ),
        "validation_rules": [
            "Return exactly the result_schema keys and no Markdown fences.",
            "Inventory COMPLETE needs concrete task-to-requirement mapping evidence; omissions are INCOMPLETE.",
            "SATISFIED needs evidence and cannot be autofixable or blocked.",
            "MISSING is autofixable or carries one allowed human blocker.",
            "UNVERIFIABLE has exact evidence linkage through context or one allowed human blocker.",
            "Every scope item is autofixable or carries one allowed human blocker.",
        ],
        "result_schema": {
            "schema_version": 1,
            "kind": "spec",
            "artifact": artifact,
            "inventory_assessment": {
                "status": "COMPLETE | INCOMPLETE | UNVERIFIABLE",
                "evidence": ["canonical task/design criterion mapped to REQ, or exact omission"],
                "reason": "required explanation",
                "autofixable": False,
                "human_blocker": None,
            },
            "requirements": [
                {
                    "ref": "exact inventory ref",
                    "id": "exact inventory id",
                    "summary": "exact inventory summary",
                    "status": "SATISFIED | MISSING | UNVERIFIABLE",
                    "evidence": ["file:line, test, or command"],
                    "autofixable": False,
                    "human_blocker": None,
                }
            ],
            "scope_creep": [
                {
                    "ref": "SCOPE-001",
                    "path": "repo-relative path",
                    "line": 0,
                    "behavior": "off-contract change",
                    "consequence": "review or maintenance risk",
                    "evidence": ["file:line"],
                    "autofixable": True,
                    "human_blocker": None,
                }
            ],
            "context_requests": [
                {
                    "ref": "CTX-001",
                    "target_type": "inventory | requirement | scope_creep",
                    "target_ref": "INVENTORY or linked requirement/scope ref",
                    "tree": "BASE | CANDIDATE",
                    "path": "repo-relative path",
                    "reason": "exact missing evidence",
                }
            ],
        },
        "human_blockers": sorted(HUMAN_BLOCKERS),
    }


def invalid_decision(
    kind: str, round_number: int, message: str, *, terminal: bool = False
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "action": "INVALID",
        "kind": kind,
        "qa_round": round_number,
        "reason": message,
        "repair_signatures": [],
        "no_progress": [],
        "context_requests": [],
        "p2_deferred": 0,
    }
    if terminal and round_number == 3:
        result["terminal_status"] = "blocked-infrastructure"
    return result


def reduce(args: argparse.Namespace) -> dict[str, Any]:
    state_path = Path(args.state)
    try:
        state = load_state(state_path)
        validate_transition(state, args.kind, args.round)
    except InvalidResult as exc:
        return invalid_decision(args.kind, args.round, str(exc))
    try:
        if not isinstance(args.expected_bundle_sha256, str) or not SHA256_RE.fullmatch(
            args.expected_bundle_sha256
        ):
            raise InvalidResult("expected bundle SHA-256 is invalid")
        if not isinstance(args.expected_base_oid, str) or not OID_RE.fullmatch(args.expected_base_oid):
            raise InvalidResult("expected base OID is invalid")
        inventory = validate_inventory(read_json(Path(args.inventory)))
        raw_result = read_json(Path(args.result))
        if args.kind == "combined":
            validated = validate_combined(raw_result, inventory)
        elif args.kind == "quality":
            validated = validate_quality(raw_result)
        else:
            validated = validate_spec(raw_result, inventory)
        metadata, bundle_sha = parse_bundle(Path(args.bundle))
    except InvalidResult as exc:
        decision = invalid_decision(args.kind, args.round, str(exc), terminal=True)
        state["history"].append(decision)
        write_state(state_path, state)
        return decision

    inventory_sha = digest(canonical_bytes(inventory))
    expected = {
        "base_oid": metadata["base_oid"],
        "candidate_tree_oid": metadata["candidate_tree_oid"],
        "bundle_sha256": bundle_sha,
        "contract_inventory_sha256": inventory_sha,
    }
    stale_reasons = [key for key, value in expected.items() if validated["artifact"][key] != value]
    if bundle_sha != args.expected_bundle_sha256:
        stale_reasons.append("expected_bundle_sha256")
    if metadata["base_oid"] != args.expected_base_oid:
        stale_reasons.append("expected_base_oid")
    if metadata["contract_inventory_sha256"] != inventory_sha:
        stale_reasons.append("bundle_contract_inventory_sha256")
    try:
        changed_paths = [
            item.decode("utf-8", "strict")
            for item in git(
                Path(args.repo).resolve(),
                "diff",
                "--name-only",
                "-z",
                metadata["base_oid"],
                metadata["candidate_tree_oid"],
            ).split(b"\0")
            if item
        ]
        if len(changed_paths) != metadata["changed_path_count"]:
            stale_reasons.append("changed_path_count")
        if digest(canonical_bytes(changed_paths)) != metadata["changed_paths_sha256"]:
            stale_reasons.append("changed_paths_sha256")
    except (InvalidResult, UnicodeDecodeError) as exc:
        stale_reasons.append(f"changed_paths_error:{exc}")
    if args.kind == "spec":
        for key in ("base_oid", "candidate_tree_oid", "bundle_sha256", "contract_inventory_sha256"):
            if state.get(key) != expected[key]:
                stale_reasons.append(f"quality_{key}")
    try:
        if current_candidate_tree(Path(args.repo).resolve()) != metadata["candidate_tree_oid"]:
            stale_reasons.append("current_candidate_tree_oid")
    except InvalidResult as exc:
        stale_reasons.append(f"candidate_tree_error:{exc}")
    if stale_reasons:
        decision = {
            "action": "STALE",
            "kind": args.kind,
            "qa_round": args.round,
            "reason": "artifact mismatch: " + ", ".join(sorted(set(stale_reasons))),
            "base_oid": metadata["base_oid"],
            "candidate_tree_oid": metadata["candidate_tree_oid"],
            "bundle_sha256": bundle_sha,
            "repair_signatures": [],
            "no_progress": [],
            "context_requests": [],
            "p2_deferred": 0,
        }
        if args.round == 3:
            decision["terminal_status"] = "blocked-infrastructure"
        state["history"].append(decision)
        write_state(state_path, state)
        return decision

    if args.kind == "combined":
        exceptions = validated["requirement_exceptions"]
        missing = [item for item in exceptions if item["status"] == "MISSING"]
        scope = validated["scope_creep"]
        blockers = validated["findings"] + missing + scope
        signatures = (
            [quality_signature(item) for item in validated["findings"]]
            + [spec_signature(item) for item in missing]
            + [scope_signature(item) for item in scope]
        )
        if validated["inventory_assessment"]["status"] == "INCOMPLETE":
            blockers.append(validated["inventory_assessment"])
            signatures.append(inventory_signature())
        p2_deferred = len(validated["deferred"])
    elif args.kind == "quality":
        blockers = [
            item for item in validated["findings"] if item["severity"] in ("P0", "P1")
        ]
        signatures = [quality_signature(item) for item in blockers]
        p2_deferred = sum(item["severity"] == "P2" for item in validated["findings"])
    else:
        missing = [item for item in validated["requirements"] if item["status"] == "MISSING"]
        scope = validated["scope_creep"]
        blockers = missing + scope
        signatures = [spec_signature(item) for item in missing] + [scope_signature(item) for item in scope]
        if validated["inventory_assessment"]["status"] == "INCOMPLETE":
            blockers.append(validated["inventory_assessment"])
            signatures.append(inventory_signature())
        p2_deferred = 0
    human_sources = blockers
    if args.kind == "spec":
        human_sources = (
            validated["requirements"]
            + validated["scope_creep"]
            + [validated["inventory_assessment"]]
        )
    elif args.kind == "combined":
        human_sources = (
            validated["findings"]
            + validated["requirement_exceptions"]
            + validated["scope_creep"]
            + [validated["inventory_assessment"]]
        )
    human = sorted({item["human_blocker"] for item in human_sources if item["human_blocker"]})
    if "QA_REPAIR_EXHAUSTED" in human and args.round < 3:
        decision = invalid_decision(
            args.kind,
            args.round,
            "QA_REPAIR_EXHAUSTED is reducer-owned before round 3",
        )
        state["history"].append(decision)
        write_state(state_path, state)
        return decision
    contexts = dedupe_contexts(validated["context_requests"])
    gaps = dedupe_gaps(
        metadata["evidence_gaps"]
        + [
            {"tree": item["tree"], "path": item["path"], "reason": item["evidence_gap"]}
            for item in metadata["context_blob_metadata"]
            if "evidence_gap" in item
        ]
        + context_gaps(Path(args.repo).resolve(), metadata, contexts)
    )
    previous = set(state["pending_repairs"].get(args.kind, []))
    no_progress = sorted(previous.intersection(signatures))
    previous_history = [item for item in state["history"] if item.get("kind") == args.kind]
    previous_tree = previous_history[-1].get("candidate_tree_oid") if previous_history else None
    no_change = bool(previous and previous_tree == metadata["candidate_tree_oid"])

    if args.kind == "combined":
        # One pass: the reviewer's verdict is applied, not re-litigated. AUTOFIX is
        # therefore terminal for the pass - repairs land and the deterministic gates
        # re-run, but no reviewer sees the repaired tree, which is why the decision
        # carries the flag that forces Phase 10 to say so out loud.
        if human:
            action, human_blocker, terminal_status = "NEEDS_HUMAN", human[0], None
        elif contexts or gaps:
            action, human_blocker = "CONTEXT", None
            terminal_status = "blocked-evidence" if args.round >= 2 else None
        elif signatures:
            action, human_blocker, terminal_status = "AUTOFIX", None, None
        else:
            action, human_blocker, terminal_status = "PROCEED", None, None
    elif human:
        action = "NEEDS_HUMAN"
        human_blocker = human[0]
        terminal_status = None
    elif contexts or gaps:
        action = "CONTEXT"
        human_blocker = None
        terminal_status = "blocked-evidence" if args.round == 3 else None
    elif signatures and args.round < 3:
        action = "AUTOFIX"
        human_blocker = None
        terminal_status = None
    elif signatures:
        action = "NEEDS_HUMAN"
        human_blocker = "QA_REPAIR_EXHAUSTED"
        terminal_status = None
    else:
        action = "PROCEED"
        human_blocker = None
        terminal_status = None

    decision = {
        "action": action,
        "kind": args.kind,
        "qa_round": args.round,
        "base_oid": metadata["base_oid"],
        "candidate_tree_oid": metadata["candidate_tree_oid"],
        "bundle_sha256": bundle_sha,
        "contract_inventory_sha256": inventory_sha,
        "repair_signatures": signatures,
        "no_progress": no_progress,
        "no_change": no_change,
        "context_requests": contexts,
        "context_evidence_gaps": gaps,
        "p2_deferred": p2_deferred,
        "human_blocker": human_blocker,
    }
    if terminal_status:
        decision["terminal_status"] = terminal_status
    if args.kind == "combined":
        decision["reviewed_candidate_tree_oid"] = metadata["candidate_tree_oid"]
        decision["deferred"] = validated["deferred"]
        # Set only when repairs will land after the single review, so the tree that
        # ships is not the tree that was reviewed. Phase 10 must disclose this.
        decision["disclose_unreviewed_repair"] = action == "AUTOFIX"
    state["qa_round"] = args.round
    state["base_oid"] = metadata["base_oid"]
    state["candidate_tree_oid"] = metadata["candidate_tree_oid"]
    state["bundle_sha256"] = bundle_sha
    state["contract_inventory_sha256"] = inventory_sha
    if action == "AUTOFIX":
        state["pending_repairs"][args.kind] = signatures
    elif action == "PROCEED":
        state["pending_repairs"][args.kind] = []
    state["history"].append(decision)
    write_state(state_path, state)
    return decision


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    contract_parser = subparsers.add_parser("contract")
    contract_parser.add_argument("--kind", choices=KINDS, required=True)
    reduce_parser = subparsers.add_parser("reduce")
    reduce_parser.add_argument("--kind", choices=KINDS, required=True)
    reduce_parser.add_argument("--round", type=int, choices=(1, 2, 3), required=True)
    reduce_parser.add_argument("--repo", required=True)
    reduce_parser.add_argument("--inventory", required=True)
    reduce_parser.add_argument("--bundle", required=True)
    reduce_parser.add_argument("--expected-bundle-sha256", required=True)
    reduce_parser.add_argument("--expected-base-oid", required=True)
    reduce_parser.add_argument("--result", required=True)
    reduce_parser.add_argument("--state", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "contract":
        print(json.dumps(contract(args.kind), ensure_ascii=False, indent=2))
    else:
        print(json.dumps(reduce(args), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
