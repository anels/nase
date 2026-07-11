#!/usr/bin/env python3
"""Verify ignored workspace skill sources against generated command wrappers."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path


MANIFEST_VERSION = 1
MARKER = "<!-- NASE-GENERATED-WORKSPACE-SKILL"


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def manifest_path(root: Path) -> Path:
    return root / "workspace" / "skills" / ".nase-manifest.json"


def source_files(root: Path) -> dict[str, Path]:
    directory = root / "workspace" / "skills"
    return {path.stem: path for path in sorted(directory.glob("*.md")) if path.is_file()}


def frontmatter_block(text: str, key: str) -> str | None:
    match = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    if not match:
        return None
    lines = match.group(1).splitlines()
    start = next((index for index, line in enumerate(lines) if line.startswith(f"{key}:")), None)
    if start is None:
        return None
    end = start + 1
    while end < len(lines) and not re.match(r"^[A-Za-z0-9_-]+:\s*", lines[end]):
        end += 1
    return "\n".join(lines[start:end])


RUNTIME_METADATA = (
    "argument-hint",
    "when_to_use",
    "model",
    "effort",
    "context",
    "agent",
    "allowed-tools",
    "disallowed-tools",
    "disable-model-invocation",
)


def mirror_errors(root: Path, sources: dict[str, Path]) -> list[str]:
    """Return source-to-generated-wrapper parity and legacy-mirror errors."""
    errors: list[str] = []
    for name, source_path in sources.items():
        source = source_path.read_text(encoding="utf-8")
        wrapper = root / ".claude" / "commands" / "nase" / "workspace" / f"{name}.md"
        if not wrapper.is_file():
            errors.append(f"{name}: generated wrapper is missing")
        else:
            wrapper_text = wrapper.read_text(encoding="utf-8")
            if f"Read `workspace/skills/{name}.md`" not in wrapper_text:
                errors.append(f"{name}: wrapper points at the wrong source")
            for key in RUNTIME_METADATA:
                block = frontmatter_block(source, key)
                if block and block not in wrapper_text:
                    errors.append(f"{name}: wrapper {key} metadata differs")

    for native in sorted((root / ".claude" / "skills").glob("nase-workspace-*/SKILL.md")):
        native_text = native.read_text(encoding="utf-8")
        if MARKER in native_text:
            errors.append(f"{native}: obsolete generated native mirror remains")
    return errors


def write_manifest(root: Path) -> dict[str, object]:
    source_paths = source_files(root)
    errors = mirror_errors(root, source_paths)
    if errors:
        raise ValueError(
            "refusing to refresh the manifest while generated mirrors drift: "
            + "; ".join(errors)
        )
    sources = {
        name: digest(path.read_text(encoding="utf-8"))
        for name, path in source_paths.items()
    }
    payload = {"version": MANIFEST_VERSION, "sources": sources}
    path = manifest_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    return payload


def load_manifest(root: Path) -> dict[str, object]:
    path = manifest_path(root)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError("local skill manifest is missing; run write-manifest after reviewing local sources") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"local skill manifest is invalid: {exc}") from exc
    if payload.get("version") != MANIFEST_VERSION or not isinstance(payload.get("sources"), dict):
        raise ValueError("local skill manifest schema is invalid")
    return payload


def check(root: Path) -> dict[str, object]:
    errors: list[str] = []
    try:
        manifest = load_manifest(root)
        manifest_sources = manifest["sources"]
    except ValueError as exc:
        return {"ok": False, "errors": [str(exc)]}

    sources = source_files(root)
    if set(manifest_sources) != set(sources):
        errors.append("manifest source set differs from local workspace skills")

    for name, source_path in sources.items():
        source = source_path.read_text(encoding="utf-8")
        if manifest_sources.get(name) != digest(source):
            errors.append(f"{name}: manifest hash differs from source")

    errors.extend(mirror_errors(root, sources))

    return {"ok": not errors, "errors": errors}


def changed(root: Path) -> dict[str, object]:
    """List local source names whose content differs from the reviewed baseline."""
    try:
        manifest = load_manifest(root)
        manifest_sources = manifest["sources"]
    except ValueError as exc:
        return {"ok": False, "errors": [str(exc)], "changed": []}

    sources = source_files(root)
    names = sorted(set(manifest_sources) | set(sources))
    changed_names = [
        name
        for name in names
        if name not in sources
        or name not in manifest_sources
        or manifest_sources[name] != digest(sources[name].read_text(encoding="utf-8"))
    ]
    return {"ok": True, "errors": [], "changed": changed_names}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("write-manifest", help="refresh the ignored local source hashes")
    commands.add_parser("check", help="verify source, wrapper, and legacy-mirror cleanup")
    commands.add_parser("changed", help="list local sources that differ from the reviewed manifest")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    root = args.root.resolve()
    if args.command == "write-manifest":
        try:
            result = write_manifest(root)
        except ValueError as exc:
            print(json.dumps({"ok": False, "errors": [str(exc)]}, indent=2))
            return 1
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if args.command == "changed":
        result = changed(root)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["ok"] else 1
    result = check(root)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
