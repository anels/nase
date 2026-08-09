#!/usr/bin/env bash

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(sys.argv[1])
sys.argv[:] = [sys.argv[0]]
GATE = ROOT / ".claude/scripts/fsd-review-gate.py"
BUNDLE = ROOT / ".claude/scripts/codex-verify-bundle.py"
QUALITY_AXES = (
    "correctness",
    "test_quality",
    "verification_evidence",
    "security_privacy",
    "reliability_data",
    "concurrency",
    "compatibility_migration",
    "performance",
    "ui_accessibility",
    "deployment_operability",
)


def run(*args: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, check=check, text=True, capture_output=True)


class ReviewGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.artifacts = Path(self.tmp.name) / "artifacts"
        self.artifacts.mkdir()
        run("git", "init", "-q", cwd=self.repo)
        run("git", "config", "user.email", "test@example.com", cwd=self.repo)
        run("git", "config", "user.name", "Test", cwd=self.repo)
        (self.repo / "app.py").write_text("def value():\n    return 1\n", encoding="utf-8")
        run("git", "add", "app.py", cwd=self.repo)
        run("git", "commit", "-q", "-m", "init", cwd=self.repo)
        self.base_oid = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()

        (self.repo / "app.py").write_text("def value():\n    return 2\n", encoding="utf-8")
        (self.repo / "test_app.py").write_text(
            "from app import value\n\ndef test_value():\n    assert value() == 2\n",
            encoding="utf-8",
        )
        self.inventory = self.artifacts / "inventory.json"
        self.inventory_data = [
            {"ref": "REQ-001", "id": "REQ-001", "summary": "value returns two"},
            {"ref": "REQ-002", "id": "REQ-002", "summary": "behavior is regression tested"},
        ]
        self.write_json(self.inventory, self.inventory_data)
        self.evidence = self.artifacts / "evidence.json"
        self.bundle = self.artifacts / "bundle.md"
        self.refresh_bundle()

    def refresh_bundle(self, *extra_args: str) -> None:
        candidate = json.loads(
            run(
                "python3",
                str(BUNDLE),
                "--repo",
                str(self.repo),
                "--base",
                self.base_oid,
                "--inventory-file",
                str(self.inventory),
                "--candidate-tree-only",
            ).stdout
        )["candidate_tree_oid"]
        self.write_json(
            self.evidence,
            {
                "candidate_tree_oid": candidate,
                "commands": [
                    {
                        "command": "python3 -m pytest test_app.py",
                        "exit_code": 0,
                        "summary": "1 passed",
                    }
                ],
            },
        )
        run(
            "python3",
            str(BUNDLE),
            "--repo",
            str(self.repo),
            "--base",
            self.base_oid,
            "--task",
            "change value to two",
            "--inventory-file",
            str(self.inventory),
            "--evidence-file",
            str(self.evidence),
            "--output",
            str(self.bundle),
            *extra_args,
        )
        first = self.bundle.read_text(encoding="utf-8").splitlines()[0]
        self.metadata = json.loads(first.removeprefix("<!-- fsd-artifact: ").removesuffix(" -->"))
        self.bundle_sha = hashlib.sha256(self.bundle.read_bytes()).hexdigest()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    @staticmethod
    def write_json(path: Path, value: object) -> None:
        path.write_text(json.dumps(value, ensure_ascii=True), encoding="utf-8")

    def artifact(self) -> dict[str, str]:
        return {
            "base_oid": self.metadata["base_oid"],
            "candidate_tree_oid": self.metadata["candidate_tree_oid"],
            "bundle_sha256": self.bundle_sha,
            "contract_inventory_sha256": self.metadata["contract_inventory_sha256"],
        }

    def axes(self) -> dict[str, dict[str, object]]:
        result: dict[str, dict[str, object]] = {}
        for axis in QUALITY_AXES:
            if axis in {"correctness", "test_quality", "verification_evidence"}:
                result[axis] = {
                    "status": "PASS",
                    "evidence": ["test_app.py:4"],
                    "reason": "Behavior is directly asserted and the focused command passed.",
                }
            else:
                result[axis] = {
                    "status": "NOT_APPLICABLE",
                    "evidence": [],
                    "reason": "The candidate does not touch this risk surface.",
                }
        return result

    def quality(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "kind": "quality",
            "artifact": self.artifact(),
            "axes": self.axes(),
            "lens_coverage": {
                lens: {
                    "status": "PASS",
                    "evidence": ["app.py and test_app.py reviewed together"],
                    "reason": "The candidate satisfies this review lens.",
                }
                for lens in ("problem_fit", "simple_design", "architecture_boundaries", "comment_accuracy")
            },
            "findings": [],
            "context_requests": [],
        }

    def spec(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "kind": "spec",
            "artifact": self.artifact(),
            "inventory_assessment": {
                "status": "COMPLETE",
                "evidence": ["task criterion value change -> REQ-001; regression test -> REQ-002"],
                "reason": "Every canonical task criterion is represented exactly once.",
                "autofixable": False,
                "human_blocker": None,
            },
            "requirements": [
                {
                    **item,
                    "status": "SATISFIED",
                    "evidence": ["app.py:2"],
                    "autofixable": False,
                    "human_blocker": None,
                }
                for item in self.inventory_data
            ],
            "scope_creep": [],
            "context_requests": [],
        }

    def reduce(
        self,
        kind: str,
        round_number: int,
        result: dict[str, object] | None,
        *,
        state: Path | None = None,
        inventory: Path | None = None,
        expected_bundle_sha: str | None = None,
        expected_base_oid: str | None = None,
    ) -> dict[str, object]:
        result_path = self.artifacts / f"{kind}-{round_number}-{os.urandom(4).hex()}.json"
        if result is not None:
            self.write_json(result_path, result)
        state_path = state or self.artifacts / f"state-{os.urandom(4).hex()}.json"
        completed = run(
            "python3",
            str(GATE),
            "reduce",
            "--kind",
            kind,
            "--round",
            str(round_number),
            "--repo",
            str(self.repo),
            "--inventory",
            str(inventory or self.inventory),
            "--bundle",
            str(self.bundle),
            "--expected-bundle-sha256",
            expected_bundle_sha or self.bundle_sha,
            "--expected-base-oid",
            expected_base_oid or self.base_oid,
            "--result",
            str(result_path),
            "--state",
            str(state_path),
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def reduce_spec(self, result: dict[str, object]) -> dict[str, object]:
        state = self.artifacts / f"spec-state-{os.urandom(4).hex()}.json"
        self.assertEqual(self.reduce("quality", 1, self.quality(), state=state)["action"], "PROCEED")
        return self.reduce("spec", 1, result, state=state)

    def reduce_quality_round_three(
        self,
        final: dict[str, object] | None,
        *,
        prior: dict[str, object] | None,
    ) -> dict[str, object]:
        state = self.artifacts / f"round-three-state-{os.urandom(4).hex()}.json"
        self.reduce("quality", 1, prior, state=state)
        self.reduce("quality", 2, prior, state=state)
        return self.reduce("quality", 3, final, state=state)

    def finding(
        self,
        *,
        axis: str = "correctness",
        severity: str = "P1",
        path: str | None = "app.py",
        autofixable: bool = True,
        blocker: str | None = None,
        ref: str = "FIND-001",
        behavior: str = "The changed behavior is not fully guarded.",
    ) -> dict[str, object]:
        return {
            "ref": ref,
            "axis": axis,
            "severity": severity,
            "path": path,
            "line": 2,
            "behavior": behavior,
            "consequence": "A regression can escape.",
            "evidence": ["app.py:2"],
            "smallest_fix": "Add the missing guard and regression assertion.",
            "verification": "python3 -m pytest test_app.py",
            "autofixable": autofixable,
            "human_blocker": blocker,
        }

    def test_contract_exposes_test_quality_lenses_and_exact_axes(self) -> None:
        completed = run("python3", str(GATE), "contract", "--kind", "quality")
        contract = json.loads(completed.stdout)
        self.assertEqual(list(contract["axes"]), list(QUALITY_AXES))
        self.assertEqual(
            set(contract["result_schema"]),
            {
                "schema_version",
                "kind",
                "artifact",
                "axes",
                "lens_coverage",
                "findings",
                "context_requests",
            },
        )
        self.assertEqual(set(contract["review_lenses"]), set(self.quality()["lens_coverage"]))
        self.assertEqual(contract["context_request_limit"], 64)
        lenses = " ".join(contract["test_quality_lenses"])
        self.assertIn("observable behavioral contract", lenses)
        self.assertIn("plausible mutation", lenses)
        self.assertIn("source-text grep", lenses)
        self.assertIn("coverage", lenses)

    def test_clean_quality_and_spec_proceed_on_same_artifact(self) -> None:
        state = self.artifacts / "clean-state.json"
        quality = self.reduce("quality", 1, self.quality(), state=state)
        spec = self.reduce("spec", 1, self.spec(), state=state)
        self.assertEqual(quality["action"], "PROCEED")
        self.assertEqual(spec["action"], "PROCEED")
        self.assertEqual(quality["candidate_tree_oid"], spec["candidate_tree_oid"])
        self.assertEqual(quality["bundle_sha256"], spec["bundle_sha256"])

    def test_bundle_body_tampering_is_stale_against_captured_hash(self) -> None:
        captured_sha = self.bundle_sha
        self.bundle.write_text(
            self.bundle.read_text(encoding="utf-8").replace("return 2", "return reviewed-only"),
            encoding="utf-8",
        )
        tampered_sha = hashlib.sha256(self.bundle.read_bytes()).hexdigest()
        result = self.quality()
        result["artifact"]["bundle_sha256"] = tampered_sha
        decision = self.reduce(
            "quality", 1, result, expected_bundle_sha=captured_sha
        )
        self.assertEqual(decision["action"], "STALE")
        self.assertIn("expected_bundle_sha256", decision["reason"])

    def test_stale_command_evidence_cannot_build_a_new_candidate(self) -> None:
        (self.repo / "app.py").write_text("def value():\n    return 3\n", encoding="utf-8")
        completed = run(
            "python3",
            str(BUNDLE),
            "--repo",
            str(self.repo),
            "--base",
            self.base_oid,
            "--task",
            "change value",
            "--inventory-file",
            str(self.inventory),
            "--evidence-file",
            str(self.evidence),
            "--output",
            str(self.artifacts / "stale-evidence.md"),
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("evidence candidate_tree_oid", completed.stderr)

        self.write_json(
            self.evidence,
            {
                "candidate_tree_oid": self.metadata["candidate_tree_oid"],
                "commands": [
                    {"command": "pytest", "exit_code": 1, "summary": "one failed"}
                ],
            },
        )
        (self.repo / "app.py").write_text("def value():\n    return 2\n", encoding="utf-8")
        completed = run(
            "python3",
            str(BUNDLE),
            "--repo",
            str(self.repo),
            "--base",
            self.base_oid,
            "--task",
            "change value",
            "--inventory-file",
            str(self.inventory),
            "--evidence-file",
            str(self.evidence),
            "--output",
            str(self.artifacts / "failed-evidence.md"),
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("exit_code must be zero", completed.stderr)

    def test_fixable_quality_requirement_and_scope_failures_autofix(self) -> None:
        quality = self.quality()
        quality["axes"]["security_privacy"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "Input validation is missing.",
        }
        quality["findings"] = [self.finding(axis="security_privacy")]
        self.assertEqual(self.reduce("quality", 1, quality)["action"], "AUTOFIX")

        spec = self.spec()
        spec["requirements"][0].update(status="MISSING", autofixable=True)
        self.assertEqual(self.reduce_spec(spec)["action"], "AUTOFIX")

        spec = self.spec()
        spec["inventory_assessment"].update(
            status="INCOMPLETE",
            evidence=["Canonical regression-test criterion has no inventory entry."],
            reason="The frozen inventory omitted a task criterion.",
            autofixable=True,
        )
        self.assertEqual(self.reduce_spec(spec)["action"], "AUTOFIX")

        spec = self.spec()
        spec["scope_creep"] = [
            {
                "ref": "SCOPE-001",
                "path": "app.py",
                "line": 2,
                "behavior": "The candidate changes an off-contract return path.",
                "consequence": "The change expands review scope.",
                "evidence": ["app.py:2"],
                "autofixable": True,
                "human_blocker": None,
            }
        ]
        self.assertEqual(self.reduce_spec(spec)["action"], "AUTOFIX")

    def test_round_three_never_autofixes_and_p2_only_proceeds(self) -> None:
        result = self.quality()
        result["axes"]["correctness"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "A verified P1 remains.",
        }
        result["findings"] = [self.finding()]
        terminal = self.reduce_quality_round_three(result, prior=result)
        self.assertEqual(terminal["action"], "NEEDS_HUMAN")
        self.assertEqual(terminal["human_blocker"], "QA_REPAIR_EXHAUSTED")

        p2 = self.quality()
        p2["findings"] = [self.finding(severity="P2", autofixable=False)]
        decision = self.reduce_quality_round_three(p2, prior=result)
        self.assertEqual(decision["action"], "PROCEED")
        self.assertEqual(decision["p2_deferred"], 1)

    def test_explicit_human_blocker_and_invalid_precedence(self) -> None:
        result = self.quality()
        result["axes"]["correctness"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "The product contract is ambiguous.",
        }
        result["findings"] = [
            self.finding(autofixable=False, blocker="PRODUCT_DECISION")
        ]
        self.assertEqual(self.reduce("quality", 1, result)["action"], "NEEDS_HUMAN")

        result["unexpected"] = True
        invalid = self.reduce("quality", 1, result)
        self.assertEqual(invalid["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "Repository authorization is required.",
        }
        result["findings"] = [
            self.finding(autofixable=False, blocker="CREDENTIAL_OR_PERMISSION")
        ]
        self.assertEqual(
            self.reduce("quality", 1, result)["human_blocker"],
            "CREDENTIAL_OR_PERMISSION",
        )

    def test_human_then_context_then_code_precedence(self) -> None:
        result = self.quality()
        result["axes"]["correctness"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "A verified P1 remains.",
        }
        result["axes"]["verification_evidence"] = {
            "status": "UNVERIFIABLE",
            "evidence": [],
            "reason": "More bound context is required.",
        }
        result["findings"] = [
            self.finding(ref="FIX", autofixable=True),
            self.finding(
                ref="HUMAN",
                axis="correctness",
                path=None,
                autofixable=False,
                blocker="TEST_ORACLE_AMBIGUITY",
            ),
        ]
        result["context_requests"] = [
            {
                "ref": "CTX",
                "target_type": "axis",
                "target_ref": "verification_evidence",
                "tree": "CANDIDATE",
                "path": "app.py",
                "reason": "Need the exact candidate source.",
            }
        ]
        self.assertEqual(self.reduce("quality", 1, result)["action"], "NEEDS_HUMAN")

        result["findings"] = [result["findings"][0]]
        self.assertEqual(self.reduce("quality", 1, result)["action"], "CONTEXT")

    def test_malformed_unknown_enum_and_axis_inconsistency_are_invalid(self) -> None:
        self.assertEqual(self.reduce("quality", 1, None)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"]["status"] = "MAYBE"
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"]["status"] = "FAIL"
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["axes"]["test_quality"] = {
            "status": "PASS",
            "evidence": ["grep -q guard app.py", "100 percent line coverage"],
            "reason": "The grep assertion rejects a missing guard and therefore proves behavior.",
        }
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"]["status"] = []
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"]["status"] = "FAIL"
        result["findings"] = [self.finding()]
        result["findings"][0]["severity"] = {}
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"]["status"] = "FAIL"
        result["findings"] = [self.finding(autofixable=False)]
        result["findings"][0]["human_blocker"] = []
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"] = {
            "status": "UNVERIFIABLE",
            "evidence": [],
            "reason": "More bound context is required.",
        }
        result["context_requests"] = [
            {
                "ref": "CTX",
                "target_type": [],
                "target_ref": "correctness",
                "tree": "CANDIDATE",
                "path": "app.py",
                "reason": "Need the exact candidate source.",
            }
        ]
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"]["status"] = "FAIL"
        result["findings"] = [self.finding(path="\ud800.py")]
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["lens_coverage"].pop("simple_design")
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        result = self.quality()
        result["lens_coverage"]["architecture_boundaries"]["status"] = "FAIL"
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

        spec = self.spec()
        spec["inventory_assessment"]["evidence"] = []
        self.assertEqual(self.reduce_spec(spec)["action"], "INVALID")

        empty_inventory = self.artifacts / "empty-inventory.json"
        self.write_json(empty_inventory, [])
        self.assertEqual(
            self.reduce("quality", 1, self.quality(), inventory=empty_inventory)["action"],
            "INVALID",
        )

    def test_stale_artifact_and_inventory_mismatches_fail_closed(self) -> None:
        for key, value in (
            ("base_oid", "0" * 40),
            ("candidate_tree_oid", "0" * 40),
            ("bundle_sha256", "0" * 64),
        ):
            with self.subTest(key=key):
                result = self.quality()
                result["artifact"][key] = value
                self.assertEqual(self.reduce("quality", 1, result)["action"], "STALE")

        wrong_base = self.reduce(
            "quality", 1, self.quality(), expected_base_oid="0" * 40
        )
        self.assertEqual(wrong_base["action"], "STALE")
        self.assertIn("expected_base_oid", wrong_base["reason"])

        for mutation in ("omission", "duplicate", "rewrite", "reorder", "addition"):
            with self.subTest(mutation=mutation):
                result = self.spec()
                if mutation == "omission":
                    result["requirements"].pop()
                elif mutation == "duplicate":
                    result["requirements"][1] = copy.deepcopy(result["requirements"][0])
                elif mutation == "rewrite":
                    result["requirements"][0]["summary"] = "rewritten"
                elif mutation == "reorder":
                    result["requirements"].reverse()
                else:
                    result["requirements"].append(copy.deepcopy(result["requirements"][0]))
                self.assertEqual(self.reduce_spec(result)["action"], "INVALID")

    def test_worktree_change_after_bundle_is_stale(self) -> None:
        (self.repo / "app.py").write_text(
            "def value():\n    return 3\n",
            encoding="utf-8",
        )
        decision = self.reduce("quality", 1, self.quality())
        self.assertEqual(decision["action"], "STALE")
        self.assertIn("current_candidate_tree_oid", decision["reason"])

    def test_no_progress_signature_ignores_reviewer_wording_and_ref(self) -> None:
        state = self.artifacts / "qa-state.json"
        first = self.quality()
        first["axes"]["correctness"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "A verified P1 remains.",
        }
        first["findings"] = [self.finding(ref="OLD", behavior="old wording")]
        initial = self.reduce("quality", 1, first, state=state)
        self.assertEqual(initial["action"], "AUTOFIX")

        second = copy.deepcopy(first)
        second["findings"][0]["ref"] = "NEW"
        second["findings"][0]["behavior"] = "different wording"
        repeated = self.reduce("quality", 2, second, state=state)
        self.assertEqual(len(repeated["no_progress"]), 1)
        self.assertEqual(initial["repair_signatures"], repeated["repair_signatures"])

    def test_path_normalization_and_rejection(self) -> None:
        signatures = []
        for path in ("./café.py", "café.py", ".\\café.py"):
            result = self.quality()
            result["axes"]["correctness"] = {
                "status": "FAIL",
                "evidence": ["app.py:2"],
                "reason": "A verified P1 remains.",
            }
            result["findings"] = [self.finding(path=path)]
            signatures.append(self.reduce("quality", 1, result)["repair_signatures"][0])
        self.assertEqual(len(set(signatures)), 1)

        for path in ("../app.py", "/tmp/app.py", ".", "bad\x00path"):
            with self.subTest(path=path):
                result = self.quality()
                result["axes"]["correctness"] = {
                    "status": "FAIL",
                    "evidence": ["app.py:2"],
                    "reason": "A verified P1 remains.",
                }
                result["findings"] = [self.finding(path=path)]
                self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

    def test_context_is_deduplicated_and_round_three_missing_blob_is_evidence_blocker(self) -> None:
        result = self.quality()
        result["axes"]["correctness"] = {
            "status": "UNVERIFIABLE",
            "evidence": [],
            "reason": "A bound blob is required.",
        }
        request = {
            "ref": "CTX-001",
            "target_type": "axis",
            "target_ref": "correctness",
            "tree": "CANDIDATE",
            "path": "missing.py",
            "reason": "Need the exact candidate blob.",
        }
        result["context_requests"] = [request, {**request, "ref": "CTX-002"}]
        context = self.reduce("quality", 1, result)
        self.assertEqual(context["action"], "CONTEXT")
        self.assertEqual(len(context["context_requests"]), 1)

        oversized = copy.deepcopy(result)
        oversized["context_requests"] = [
            {**request, "ref": f"CTX-{index:03d}", "path": f"missing-{index}.py"}
            for index in range(65)
        ]
        self.assertEqual(self.reduce("quality", 1, oversized)["action"], "INVALID")

        terminal = self.reduce_quality_round_three(result, prior=None)
        self.assertEqual(terminal["terminal_status"], "blocked-evidence")

    def test_declared_candidate_gap_blocks_without_reviewer_request(self) -> None:
        os.symlink("app.py", self.repo / "link.py")
        self.refresh_bundle()
        first = self.reduce("quality", 1, self.quality())
        self.assertEqual(first["action"], "CONTEXT")
        self.assertEqual(first["context_evidence_gaps"][0]["reason"], "symlink")
        terminal = self.reduce_quality_round_three(self.quality(), prior=self.quality())
        self.assertEqual(terminal["terminal_status"], "blocked-evidence")

    def test_large_diff_credential_omission_blocks_proceed(self) -> None:
        marker = "Authorization: " + "Bearer " + "large_diff_canary_17a2"
        (self.repo / "auth.txt").write_text(
            marker + "\nauthorization_guard=true\n", encoding="utf-8"
        )
        run("git", "add", "-A", cwd=self.repo)
        run("git", "commit", "-q", "-m", "sensitive base", cwd=self.repo)
        self.base_oid = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()
        (self.repo / "auth.txt").write_text("authorization_guard=false\n", encoding="utf-8")
        self.refresh_bundle("--max-full-diff-lines", "0")

        self.assertEqual(
            self.metadata["evidence_gaps"],
            [
                {
                    "path": "auth.txt",
                    "reason": "credential_like_diff_omitted",
                    "tree": "BASE",
                }
            ],
        )
        self.assertNotIn("large_diff_canary_17a2", self.bundle.read_text(encoding="utf-8"))
        self.assertEqual(self.reduce("quality", 1, self.quality())["action"], "CONTEXT")

    def test_deleted_credential_bearing_path_is_redacted_and_blocks_proceed(self) -> None:
        sensitive_name = "ADMIN_" + "PASS" + "WORD=deleted_path_canary_17a2.txt"
        (self.repo / sensitive_name).write_text("safe content\n", encoding="utf-8")
        run("git", "add", "-A", cwd=self.repo)
        run("git", "commit", "-q", "-m", "sensitive path base", cwd=self.repo)
        self.base_oid = run("git", "rev-parse", "HEAD", cwd=self.repo).stdout.strip()
        (self.repo / sensitive_name).unlink()
        self.refresh_bundle()

        bundle = self.bundle.read_text(encoding="utf-8")
        self.assertNotIn("deleted_path_canary_17a2", bundle)
        self.assertIn("<redacted-path:", bundle)
        self.assertEqual(
            self.metadata["evidence_gaps"][0]["reason"],
            "credential_like_path_redacted",
        )
        self.assertEqual(self.reduce("quality", 1, self.quality())["action"], "CONTEXT")

    def test_inventory_unverifiable_context_and_human_blocker(self) -> None:
        spec = self.spec()
        spec["inventory_assessment"].update(
            status="UNVERIFIABLE",
            evidence=["The invocation refers to a design artifact not present in the bundle."],
            reason="Need the bound design source.",
        )
        spec["context_requests"] = [
            {
                "ref": "CTX-INVENTORY",
                "target_type": "inventory",
                "target_ref": "INVENTORY",
                "tree": "BASE",
                "path": "app.py",
                "reason": "Need the bound design source used to derive the inventory.",
            }
        ]
        self.assertEqual(self.reduce_spec(spec)["action"], "CONTEXT")

        spec = self.spec()
        spec["inventory_assessment"].update(
            status="UNVERIFIABLE",
            evidence=["Two product criteria conflict."],
            reason="A product decision is required.",
            human_blocker="CONTRACT_CONFLICT",
        )
        self.assertEqual(self.reduce_spec(spec)["human_blocker"], "CONTRACT_CONFLICT")

    def test_round_three_provider_failure_is_infrastructure_blocker(self) -> None:
        terminal = self.reduce_quality_round_three(None, prior=None)
        self.assertEqual(terminal["terminal_status"], "blocked-infrastructure")

    def test_shared_round_order_and_reducer_owned_exhaustion(self) -> None:
        fresh_state = self.artifacts / "transition-state.json"
        self.assertEqual(self.reduce("spec", 1, self.spec(), state=fresh_state)["action"], "INVALID")
        self.assertEqual(self.reduce("quality", 1, self.quality(), state=fresh_state)["action"], "PROCEED")
        self.assertEqual(self.reduce("quality", 2, self.quality(), state=fresh_state)["action"], "INVALID")
        self.assertEqual(self.reduce("spec", 1, self.spec(), state=fresh_state)["action"], "PROCEED")
        self.assertEqual(self.reduce("quality", 2, self.quality(), state=fresh_state)["action"], "INVALID")

        result = self.quality()
        result["axes"]["correctness"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "A verified P1 remains.",
        }
        result["findings"] = [
            self.finding(autofixable=False, blocker="QA_REPAIR_EXHAUSTED")
        ]
        self.assertEqual(self.reduce("quality", 1, result)["action"], "INVALID")

    def test_corrupt_state_fails_closed(self) -> None:
        state = self.artifacts / "corrupt-state.json"
        self.write_json(state, {"schema_version": 1, "unexpected": True})
        decision = self.reduce("quality", 1, self.quality(), state=state)
        self.assertEqual(decision["action"], "INVALID")

        state = self.artifacts / "corrupt-history.json"
        self.write_json(
            state,
            {
                "schema_version": 1,
                "pending_repairs": {"quality": [], "spec": []},
                "history": [
                    42,
                    {"kind": "quality", "qa_round": 1, "action": "AUTOFIX"},
                ],
            },
        )
        decision = self.reduce("quality", 2, self.quality(), state=state)
        self.assertEqual(decision["action"], "INVALID")


if __name__ == "__main__":
    unittest.main(verbosity=2)
PY
