#!/usr/bin/env bash

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(sys.argv[1])
sys.argv[:] = [sys.argv[0]]
GATE = ROOT / ".claude/scripts/fsd-review-gate.py"
BUNDLE = ROOT / ".claude/scripts/verify-bundle.py"
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
    # The fixture is a git repo plus a built verification bundle: 6 git subprocesses and
    # 2 verify-bundle.py invocations, about 1.5s. Building it per test method cost ~115s
    # across this file - the slowest single file in the whole suite and the thing that
    # bounded a parallel `check-all` run. Build it once, then hand each test a filesystem
    # copy: tests still mutate the repo and rebuild the bundle freely, but a copytree of a
    # four-file repo is milliseconds. Git tree OIDs are content-addressed, so the copy
    # resolves to the same candidate_tree_oid the bundle metadata was built against.
    inventory_data = [
        {"ref": "REQ-001", "id": "REQ-001", "summary": "value returns two"},
        {"ref": "REQ-002", "id": "REQ-002", "summary": "behavior is regression tested"},
    ]

    @classmethod
    def setUpClass(cls) -> None:
        cls._template = tempfile.TemporaryDirectory()
        root = Path(cls._template.name)
        repo = root / "repo"
        repo.mkdir()
        artifacts = root / "artifacts"
        artifacts.mkdir()
        run("git", "init", "-q", cwd=repo)
        run("git", "config", "user.email", "test@example.com", cwd=repo)
        run("git", "config", "user.name", "Test", cwd=repo)
        (repo / "app.py").write_text("def value():\n    return 1\n", encoding="utf-8")
        run("git", "add", "app.py", cwd=repo)
        run("git", "commit", "-q", "-m", "init", cwd=repo)
        cls._base_oid = run("git", "rev-parse", "HEAD", cwd=repo).stdout.strip()

        (repo / "app.py").write_text("def value():\n    return 2\n", encoding="utf-8")
        (repo / "test_app.py").write_text(
            "from app import value\n\ndef test_value():\n    assert value() == 2\n",
            encoding="utf-8",
        )
        cls.write_json(artifacts / "inventory.json", cls.inventory_data)

        # Build the bundle through a throwaway instance so refresh_bundle stays the single
        # definition of how a bundle is produced.
        seed = cls.__new__(cls)
        seed.repo, seed.artifacts = repo, artifacts
        seed.base_oid = cls._base_oid
        seed.inventory = artifacts / "inventory.json"
        seed.evidence = artifacts / "evidence.json"
        seed.bundle = artifacts / "bundle.md"
        seed.refresh_bundle()

    @classmethod
    def tearDownClass(cls) -> None:
        cls._template.cleanup()

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        shutil.copytree(self._template.name, self.tmp.name, dirs_exist_ok=True)
        self.repo = Path(self.tmp.name) / "repo"
        self.artifacts = Path(self.tmp.name) / "artifacts"
        self.base_oid = self._base_oid
        self.inventory = self.artifacts / "inventory.json"
        self.evidence = self.artifacts / "evidence.json"
        self.bundle = self.artifacts / "bundle.md"
        self.load_bundle_identity()

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
        self.load_bundle_identity()

    def load_bundle_identity(self) -> None:
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

    def precheck(
        self,
        result: dict[str, object],
        *,
        inventory: Path | None = None,
        expected_bundle_sha: str | None = None,
        expected_base_oid: str | None = None,
    ) -> tuple[int, dict[str, object]]:
        result_path = self.artifacts / f"precheck-{os.urandom(4).hex()}.json"
        self.write_json(result_path, result)
        completed = run(
            "python3",
            str(GATE),
            "precheck",
            "--round",
            "1",
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
            check=False,
        )
        return completed.returncode, json.loads(completed.stdout)

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

    def combined_axes(self) -> dict[str, object]:
        required = ("correctness", "test_quality", "verification_evidence")
        axes: dict[str, object] = {}
        for axis in QUALITY_AXES:
            node: dict[str, object] = {
                "status": "PASS",
                "evidence": ["app.py:2 and test_app.py:3 reviewed together"],
            }
            if axis in required:
                node["reason"] = "The candidate satisfies this axis."
            axes[axis] = node
        return axes

    def combined_with_finding(self, **overrides: object) -> dict[str, object]:
        finding = overrides.pop("finding", None) or self.finding()
        axes = self.combined_axes()
        axes[finding["axis"]] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "The candidate does not satisfy this axis.",
        }
        lenses = {
            lens: {"status": "PASS", "evidence": ["app.py and test_app.py reviewed together"]}
            for lens in ("problem_fit", "simple_design", "architecture_boundaries", "comment_quality")
        }
        return self.combined(axes=axes, lenses=lenses, findings=[finding], **overrides)

    def combined(self, **overrides: object) -> dict[str, object]:
        result = {
            "schema_version": 1,
            "kind": "combined",
            "artifact": self.artifact(),
            "axes": self.combined_axes(),
            "lenses": {
                lens: {"status": "PASS", "evidence": ["app.py and test_app.py reviewed together"]}
                for lens in ("problem_fit", "simple_design", "architecture_boundaries", "comment_quality")
            },
            "findings": [],
            "deferred": [],
            "requirements": {item["ref"]: "SATISFIED" for item in self.inventory_data},
            "requirement_exceptions": [],
            "inventory_assessment": {
                "status": "COMPLETE",
                "evidence": ["task criterion value change -> REQ-001; regression test -> REQ-002"],
                "reason": "Every canonical task criterion is represented exactly once.",
                "autofixable": False,
                "human_blocker": None,
            },
            "scope_creep": [],
            "context_requests": [],
        }
        result.update(overrides)
        return result

    def test_combined_contract_cannot_express_a_deferred_repair(self) -> None:
        contract = json.loads(run("python3", str(GATE), "contract", "--kind", "combined").stdout)
        # The old schema let a reviewer file a non-blocking finding carrying repair
        # fields, which the reducer then rejected on a rule the reviewer could not
        # see. Deferred notes are now plain strings, so that slip is unrepresentable.
        self.assertEqual(contract["finding_severities"], ["P0", "P1"])
        self.assertEqual(
            set(contract["result_schema"]),
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
        )
        self.assertIsInstance(contract["result_schema"]["deferred"][0], str)
        self.assertNotIn("QA_REPAIR_EXHAUSTED", contract["human_blockers"])
        self.assertEqual(
            tuple(contract["required_axes"] + contract["conditional_axes"]), QUALITY_AXES
        )
        self.assertEqual(set(contract["review_lenses"]), set(contract["result_schema"]["lenses"]))
        self.assertEqual(contract["context_request_limit"], 64)

    def test_combined_clean_result_proceeds_in_one_pass(self) -> None:
        decision = self.reduce("combined", 1, self.combined())
        self.assertEqual(decision["action"], "PROCEED")
        self.assertEqual(decision["reviewed_candidate_tree_oid"], decision["candidate_tree_oid"])
        self.assertFalse(decision["disclose_unreviewed_repair"])

    def test_combined_deferred_notes_are_counted_but_never_gate(self) -> None:
        decision = self.reduce(
            "combined",
            1,
            self.combined(deferred=["app.py:2 - the helper name could be clearer", "test_app.py:3 - fixture is broad"]),
        )
        self.assertEqual(decision["action"], "PROCEED")
        self.assertEqual(decision["p2_deferred"], 2)
        self.assertEqual(decision["repair_signatures"], [])

    def test_combined_p2_severity_is_rejected_outright(self) -> None:
        decision = self.reduce(
            "combined", 1, self.combined_with_finding(finding=self.finding(severity="P2", autofixable=False))
        )
        self.assertEqual(decision["action"], "INVALID")

    def test_combined_autofix_flags_disclosure_and_ends_the_pass(self) -> None:
        state = self.artifacts / "combined-autofix-state.json"
        decision = self.reduce("combined", 1, self.combined_with_finding(), state=state)
        self.assertEqual(decision["action"], "AUTOFIX")
        # The repaired tree is never re-reviewed, so the decision must carry the flag
        # Phase 10 uses to say the shipped tree is not the reviewed one.
        self.assertTrue(decision["disclose_unreviewed_repair"])
        again = self.reduce("combined", 1, self.combined(), state=state)
        self.assertEqual(again["action"], "INVALID")

    def test_combined_malformed_result_buys_exactly_one_retry(self) -> None:
        state = self.artifacts / "combined-retry-state.json"
        broken = self.combined()
        del broken["deferred"]
        first = self.reduce("combined", 1, broken, state=state)
        self.assertEqual(first["action"], "INVALID")
        # A result the reducer cannot parse says nothing about the candidate, so it
        # must not consume the only pass.
        recovered = self.reduce("combined", 1, self.combined(), state=state)
        self.assertEqual(recovered["action"], "PROCEED")

    def test_combined_second_malformed_result_exhausts_the_pass(self) -> None:
        state = self.artifacts / "combined-retry-exhausted-state.json"
        broken = self.combined()
        del broken["deferred"]
        self.assertEqual(self.reduce("combined", 1, broken, state=state)["action"], "INVALID")
        self.assertEqual(self.reduce("combined", 1, broken, state=state)["action"], "INVALID")
        third = self.reduce("combined", 1, self.combined(), state=state)
        self.assertEqual(third["action"], "INVALID")
        self.assertIn("retry", third["reason"])

    def test_combined_requirements_must_enumerate_the_inventory_exactly(self) -> None:
        partial = self.combined()
        partial["requirements"] = {self.inventory_data[0]["ref"]: "SATISFIED"}
        self.assertEqual(self.reduce("combined", 1, partial)["action"], "INVALID")

    def test_combined_unsatisfied_requirement_needs_a_matching_exception(self) -> None:
        orphan = self.combined()
        ref = self.inventory_data[-1]["ref"]
        orphan["requirements"][ref] = "MISSING"
        self.assertEqual(self.reduce("combined", 1, orphan)["action"], "INVALID")
        repaired = self.combined()
        repaired["requirements"][ref] = "MISSING"
        repaired["requirement_exceptions"] = [
            {
                "ref": ref,
                "status": "MISSING",
                "evidence": ["app.py:2 has no regression assertion"],
                "autofixable": True,
                "human_blocker": None,
            }
        ]
        decision = self.reduce("combined", 1, repaired)
        self.assertEqual(decision["action"], "AUTOFIX")
        self.assertTrue(decision["disclose_unreviewed_repair"])

    def test_combined_tolerates_an_unrequested_reason_on_a_passing_axis(self) -> None:
        # Failing a reviewer for supplying more than the contract asked for is the
        # exact class of slip this schema exists to stop, so an extra reason is
        # accepted and simply not required.
        generous = self.combined()
        generous["axes"]["performance"]["reason"] = "No hot path changed."
        self.assertEqual(self.reduce("combined", 1, generous)["action"], "PROCEED")

    def test_combined_requirements_ignore_key_order(self) -> None:
        shuffled = self.combined()
        shuffled["requirements"] = dict(reversed(list(shuffled["requirements"].items())))
        self.assertEqual(self.reduce("combined", 1, shuffled)["action"], "PROCEED")

    def test_combined_overlong_deferred_is_trimmed_not_rejected(self) -> None:
        noisy = self.combined(deferred=[f"app.py:{index} - " + "x" * 400 for index in range(40)])
        decision = self.reduce("combined", 1, noisy)
        self.assertEqual(decision["action"], "PROCEED")
        self.assertEqual(decision["p2_deferred"], 25)
        self.assertTrue(all(len(note) <= 240 for note in decision["deferred"]))
        # The trimmed tail is reported: 40 nits must not read as 25.
        self.assertEqual(decision["deferred"][-1], "... 16 more deferred note(s) trimmed by the gate")

    def test_combined_deferred_at_the_cap_carries_no_trim_notice(self) -> None:
        exact = self.combined(deferred=[f"app.py:{index} - nit" for index in range(25)])
        decision = self.reduce("combined", 1, exact)
        self.assertEqual(decision["p2_deferred"], 25)
        self.assertNotIn("trimmed by the gate", decision["deferred"][-1])

    def test_combined_malformed_deferred_past_the_cap_still_fails(self) -> None:
        broken = self.combined(deferred=[f"app.py:{index} - nit" for index in range(30)] + [""])
        self.assertEqual(self.reduce("combined", 1, broken)["action"], "INVALID")

    def test_non_combined_kind_is_rejected_by_the_cli(self) -> None:
        # The two-pass kinds are gone from the gate, so argparse - not a reducer
        # decision - is what a caller now hits.
        for command in ("contract", "reduce"):
            for kind in ("quality", "spec"):
                with self.subTest(command=command, kind=kind):
                    completed = run("python3", str(GATE), command, "--kind", kind, check=False)
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn("invalid choice", completed.stderr)

    def test_legacy_kind_keyed_state_still_loads(self) -> None:
        # State written by the retired two-pass flow must read back as a stale but
        # parseable file rather than crashing the reducer.
        state = self.artifacts / "legacy-pending-state.json"
        self.write_json(
            state,
            {"schema_version": 1, "pending_repairs": {"quality": [], "spec": []}, "history": []},
        )
        self.assertEqual(self.reduce("combined", 1, self.combined(), state=state)["action"], "PROCEED")

    def test_bundle_body_tampering_is_stale_against_captured_hash(self) -> None:
        captured_sha = self.bundle_sha
        self.bundle.write_text(
            self.bundle.read_text(encoding="utf-8").replace("return 2", "return reviewed-only"),
            encoding="utf-8",
        )
        tampered_sha = hashlib.sha256(self.bundle.read_bytes()).hexdigest()
        result = self.combined()
        result["artifact"]["bundle_sha256"] = tampered_sha
        decision = self.reduce(
            "combined", 1, result, expected_bundle_sha=captured_sha
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

    def test_fixable_finding_inventory_and_scope_failures_autofix(self) -> None:
        finding = self.combined_with_finding(finding=self.finding(axis="security_privacy"))
        self.assertEqual(self.reduce("combined", 1, finding)["action"], "AUTOFIX")

        incomplete = self.combined()
        incomplete["inventory_assessment"].update(
            status="INCOMPLETE",
            evidence=["Canonical regression-test criterion has no inventory entry."],
            reason="The frozen inventory omitted a task criterion.",
            autofixable=True,
        )
        self.assertEqual(self.reduce("combined", 1, incomplete)["action"], "AUTOFIX")

        creep = self.combined(
            scope_creep=[
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
        )
        self.assertEqual(self.reduce("combined", 1, creep)["action"], "AUTOFIX")

    def test_explicit_human_blocker_and_invalid_precedence(self) -> None:
        result = self.combined_with_finding(
            finding=self.finding(autofixable=False, blocker="PRODUCT_DECISION")
        )
        self.assertEqual(self.reduce("combined", 1, result)["action"], "NEEDS_HUMAN")

        result["unexpected"] = True
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        credential = self.combined_with_finding(
            finding=self.finding(autofixable=False, blocker="CREDENTIAL_OR_PERMISSION")
        )
        self.assertEqual(
            self.reduce("combined", 1, credential)["human_blocker"],
            "CREDENTIAL_OR_PERMISSION",
        )

    def test_human_then_context_then_code_precedence(self) -> None:
        axes = self.combined_axes()
        axes["correctness"] = {
            "status": "FAIL",
            "evidence": ["app.py:2"],
            "reason": "A verified P1 remains.",
        }
        axes["verification_evidence"] = {
            "status": "UNVERIFIABLE",
            "evidence": [],
            "reason": "More bound context is required.",
        }
        findings = [
            self.finding(ref="FIX", autofixable=True),
            self.finding(
                ref="HUMAN",
                axis="correctness",
                path=None,
                autofixable=False,
                blocker="TEST_ORACLE_AMBIGUITY",
            ),
        ]
        result = self.combined(
            axes=axes,
            findings=findings,
            context_requests=[
                {
                    "ref": "CTX",
                    "target_type": "axis",
                    "target_ref": "verification_evidence",
                    "tree": "CANDIDATE",
                    "path": "app.py",
                    "reason": "Need the exact candidate source.",
                }
            ],
        )
        self.assertEqual(self.reduce("combined", 1, result)["action"], "NEEDS_HUMAN")

        result["findings"] = [findings[0]]
        self.assertEqual(self.reduce("combined", 1, result)["action"], "CONTEXT")

    def test_malformed_unknown_enum_and_axis_inconsistency_are_invalid(self) -> None:
        self.assertEqual(self.reduce("combined", 1, None)["action"], "INVALID")

        result = self.combined()
        result["axes"]["correctness"]["status"] = "MAYBE"
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined()
        result["axes"]["correctness"]["status"] = "FAIL"
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined()
        result["axes"]["test_quality"] = {
            "status": "PASS",
            "evidence": ["grep -q guard app.py", "100 percent line coverage"],
            "reason": "The grep assertion rejects a missing guard and therefore proves behavior.",
        }
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined()
        result["axes"]["correctness"]["status"] = []
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined_with_finding()
        result["findings"][0]["severity"] = {}
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined_with_finding(finding=self.finding(autofixable=False))
        result["findings"][0]["human_blocker"] = []
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        axes = self.combined_axes()
        axes["correctness"] = {
            "status": "UNVERIFIABLE",
            "evidence": [],
            "reason": "More bound context is required.",
        }
        result = self.combined(
            axes=axes,
            context_requests=[
                {
                    "ref": "CTX",
                    "target_type": [],
                    "target_ref": "correctness",
                    "tree": "CANDIDATE",
                    "path": "app.py",
                    "reason": "Need the exact candidate source.",
                }
            ],
        )
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined_with_finding(finding=self.finding(path="\ud800.py"))
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined()
        result["lenses"].pop("simple_design")
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined()
        result["lenses"]["architecture_boundaries"]["status"] = "FAIL"
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        result = self.combined()
        result["inventory_assessment"]["evidence"] = []
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

        empty_inventory = self.artifacts / "empty-inventory.json"
        self.write_json(empty_inventory, [])
        self.assertEqual(
            self.reduce("combined", 1, self.combined(), inventory=empty_inventory)["action"],
            "INVALID",
        )

    def test_stale_artifact_mismatches_fail_closed(self) -> None:
        for key, value in (
            ("base_oid", "0" * 40),
            ("candidate_tree_oid", "0" * 40),
            ("bundle_sha256", "0" * 64),
        ):
            with self.subTest(key=key):
                result = self.combined()
                result["artifact"][key] = value
                self.assertEqual(self.reduce("combined", 1, result)["action"], "STALE")

        wrong_base = self.reduce(
            "combined", 1, self.combined(), expected_base_oid="0" * 40
        )
        self.assertEqual(wrong_base["action"], "STALE")
        self.assertIn("expected_base_oid", wrong_base["reason"])

    def test_combined_qa_must_start_at_round_one(self) -> None:
        # The round-order half of the retired test_shared_round_order_and_reducer_owned
        # _exhaustion. Its "already resolved" half survives in the autofix test above and
        # its exhaustion half in test_qa_repair_exhausted_stays_reducer_owned, but nothing
        # was left asserting the entry condition at fsd-review-gate.py's
        # validate_combined_transition: an empty history may only be entered at round 1.
        fresh = self.artifacts / "round-entry-state.json"
        decision = self.reduce("combined", 2, self.combined(), state=fresh)
        self.assertEqual(decision["action"], "INVALID", decision)
        self.assertIn("round 1", decision["reason"])
        self.assertEqual(
            self.reduce("combined", 1, self.combined(), state=fresh)["action"], "PROCEED"
        )

    def test_requirements_must_cover_the_inventory_exactly(self) -> None:
        # The predecessor of test_stale_artifact_mismatches_fail_closed also mutated the
        # requirements block five ways and expected rejection. Three of those shapes
        # (duplicate/reorder/rewrite) stopped being expressible when `requirements` became
        # a ref->status object, but omission and addition still are, and
        # fsd-review-gate.py rejects both - so keep asserting it.
        missing = self.combined()
        dropped = self.inventory_data[-1]["ref"]
        del missing["requirements"][dropped]
        code, out = self.precheck(missing)
        self.assertEqual(code, 1, out)
        self.assertTrue(any(dropped in item for item in out["problems"]), out)

        unknown = self.combined()
        unknown["requirements"]["REQ-404"] = "SATISFIED"
        code, out = self.precheck(unknown)
        self.assertEqual(code, 1, out)
        self.assertTrue(any("REQ-404" in item for item in out["problems"]), out)

    def test_worktree_change_after_bundle_is_stale(self) -> None:
        (self.repo / "app.py").write_text(
            "def value():\n    return 3\n",
            encoding="utf-8",
        )
        decision = self.reduce("combined", 1, self.combined())
        self.assertEqual(decision["action"], "STALE")
        self.assertIn("current_candidate_tree_oid", decision["reason"])

    def test_repair_signature_ignores_reviewer_wording_and_ref(self) -> None:
        # The signature is what a follow-up run compares against, so it must survive
        # the reviewer rewording the same defect or renumbering its ref.
        first = self.reduce(
            "combined", 1, self.combined_with_finding(finding=self.finding(ref="OLD", behavior="old wording"))
        )
        second = self.reduce(
            "combined",
            1,
            self.combined_with_finding(finding=self.finding(ref="NEW", behavior="different wording")),
        )
        self.assertEqual(first["action"], "AUTOFIX")
        self.assertEqual(len(first["repair_signatures"]), 1)
        self.assertEqual(first["repair_signatures"], second["repair_signatures"])

    def test_path_normalization_and_rejection(self) -> None:
        signatures = []
        for path in ("./café.py", "café.py", ".\\café.py"):
            result = self.combined_with_finding(finding=self.finding(path=path))
            signatures.append(self.reduce("combined", 1, result)["repair_signatures"][0])
        self.assertEqual(len(set(signatures)), 1)

        for path in ("../app.py", "/tmp/app.py", ".", "bad\x00path"):
            with self.subTest(path=path):
                result = self.combined_with_finding(finding=self.finding(path=path))
                self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

    def test_context_is_deduplicated_and_round_two_missing_blob_is_evidence_blocker(self) -> None:
        axes = self.combined_axes()
        axes["correctness"] = {
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
        result = self.combined(
            axes=axes, context_requests=[request, {**request, "ref": "CTX-002"}]
        )
        state = self.artifacts / "context-state.json"
        context = self.reduce("combined", 1, result, state=state)
        self.assertEqual(context["action"], "CONTEXT")
        self.assertEqual(len(context["context_requests"]), 1)

        oversized = copy.deepcopy(result)
        oversized["context_requests"] = [
            {**request, "ref": f"CTX-{index:03d}", "path": f"missing-{index}.py"}
            for index in range(65)
        ]
        self.assertEqual(self.reduce("combined", 1, oversized)["action"], "INVALID")

        # The single context refill is spent; a second miss ends the pass.
        terminal = self.reduce("combined", 2, result, state=state)
        self.assertEqual(terminal["terminal_status"], "blocked-evidence")

    def test_declared_candidate_gap_blocks_without_reviewer_request(self) -> None:
        os.symlink("app.py", self.repo / "link.py")
        self.refresh_bundle()
        state = self.artifacts / "gap-state.json"
        first = self.reduce("combined", 1, self.combined(), state=state)
        self.assertEqual(first["action"], "CONTEXT")
        self.assertEqual(first["context_evidence_gaps"][0]["reason"], "symlink")
        terminal = self.reduce("combined", 2, self.combined(), state=state)
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
        self.assertEqual(self.reduce("combined", 1, self.combined())["action"], "CONTEXT")

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
        self.assertEqual(self.reduce("combined", 1, self.combined())["action"], "CONTEXT")

    def test_inventory_unverifiable_context_and_human_blocker(self) -> None:
        result = self.combined()
        result["inventory_assessment"].update(
            status="UNVERIFIABLE",
            evidence=["The invocation refers to a design artifact not present in the bundle."],
            reason="Need the bound design source.",
        )
        result["context_requests"] = [
            {
                "ref": "CTX-INVENTORY",
                "target_type": "inventory",
                "target_ref": "INVENTORY",
                "tree": "BASE",
                "path": "app.py",
                "reason": "Need the bound design source used to derive the inventory.",
            }
        ]
        self.assertEqual(self.reduce("combined", 1, result)["action"], "CONTEXT")

        blocked = self.combined()
        blocked["inventory_assessment"].update(
            status="UNVERIFIABLE",
            evidence=["Two product criteria conflict."],
            reason="A product decision is required.",
            human_blocker="CONTRACT_CONFLICT",
        )
        self.assertEqual(self.reduce("combined", 1, blocked)["human_blocker"], "CONTRACT_CONFLICT")

    def test_qa_repair_exhausted_stays_reducer_owned(self) -> None:
        # A reviewer cannot declare the repair budget spent. The combined finding
        # schema drops the blocker outright, so the reachable claim is through a
        # requirement exception, and the reducer rejects it there.
        ref = self.inventory_data[0]["ref"]
        result = self.combined()
        result["requirements"][ref] = "MISSING"
        result["requirement_exceptions"] = [
            {
                "ref": ref,
                "status": "MISSING",
                "evidence": ["app.py:2 has no regression assertion"],
                "autofixable": False,
                "human_blocker": "QA_REPAIR_EXHAUSTED",
            }
        ]
        self.assertEqual(self.reduce("combined", 1, result)["action"], "INVALID")

    def test_corrupt_state_fails_closed(self) -> None:
        state = self.artifacts / "corrupt-state.json"
        self.write_json(state, {"schema_version": 1, "unexpected": True})
        decision = self.reduce("combined", 1, self.combined(), state=state)
        self.assertEqual(decision["action"], "INVALID")

        state = self.artifacts / "corrupt-history.json"
        self.write_json(
            state,
            {
                "schema_version": 1,
                "pending_repairs": {"combined": []},
                "history": [
                    42,
                    {"kind": "combined", "qa_round": 1, "action": "AUTOFIX"},
                ],
            },
        )
        decision = self.reduce("combined", 2, self.combined(), state=state)
        self.assertEqual(decision["action"], "INVALID")

    # --- precheck ------------------------------------------------------------
    # `reduce` writes an INVALID decision into state and spends the round's single
    # retry, so a malformed reviewer reply must be caught before it gets there.

    def test_precheck_accepts_a_well_formed_result(self) -> None:
        code, out = self.precheck(self.combined())
        self.assertEqual(code, 0, out)
        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["problems"], [])

    def test_precheck_rejects_a_malformed_result_without_writing_state(self) -> None:
        broken = self.combined()
        del broken["artifact"]
        code, out = self.precheck(broken)
        self.assertEqual(code, 1)
        self.assertEqual(out["status"], "invalid")
        self.assertTrue(any("result:" in item for item in out["problems"]), out)
        # The point is that the round keeps its budget, and the only way to observe that
        # is through reduce: if precheck had recorded anything, the state file would carry
        # history and validate_combined_transition would reject this as a re-entry at
        # round 1 instead of letting a good result through.
        state = self.artifacts / "after-precheck-state.json"
        self.assertFalse(state.exists())
        self.assertEqual(
            self.reduce("combined", 1, self.combined(), state=state)["action"], "PROCEED"
        )

    def test_precheck_catches_a_bundle_sha_mismatch(self) -> None:
        code, out = self.precheck(self.combined(), expected_bundle_sha="0" * 64)
        self.assertEqual(code, 1)
        self.assertTrue(
            any("expected-bundle-sha256" in item for item in out["problems"]), out
        )

    def test_precheck_catches_a_base_oid_mismatch(self) -> None:
        code, out = self.precheck(self.combined(), expected_base_oid="0" * 40)
        self.assertEqual(code, 1)
        self.assertTrue(
            any("expected-base-oid" in item for item in out["problems"]), out
        )

    def test_precheck_catches_an_inventory_not_bound_to_the_bundle(self) -> None:
        other = self.artifacts / "other-inventory.json"
        self.write_json(
            other,
            [{"ref": "REQ-001", "id": "other", "summary": "a different requirement"}],
        )
        code, out = self.precheck(self.combined(), inventory=other)
        self.assertEqual(code, 1)
        self.assertTrue(
            any("contract_inventory_sha256" in item for item in out["problems"]), out
        )

    def test_precheck_rejects_a_reducer_owned_blocker(self) -> None:
        # reduce() rejects QA_REPAIR_EXHAUSTED before round 3 and writes the INVALID
        # to state, spending the round's one retry. precheck must catch it first.
        ref = self.inventory_data[0]["ref"]
        result = self.combined()
        result["requirements"][ref] = "MISSING"
        result["requirement_exceptions"] = [
            {
                "ref": ref,
                "status": "MISSING",
                "evidence": ["app.py:2 has no regression assertion"],
                "autofixable": False,
                "human_blocker": "QA_REPAIR_EXHAUSTED",
            }
        ]
        # The same payload reduce() rejects at test_qa_repair_exhausted_stays_reducer_owned,
        # caught one step earlier so the round keeps its retry.
        code, out = self.precheck(result)
        self.assertEqual(code, 1, out)
        self.assertTrue(
            any("QA_REPAIR_EXHAUSTED" in item for item in out["problems"]), out
        )
        # The token is reducer-owned in every reachable round, so there is no round in
        # which precheck should let it through. Round 3 is not reachable and is no longer
        # an accepted --round value, which is what removed the old fail-open.
        rejected = run(
            "python3", str(GATE), "precheck", "--round", "3",
            "--inventory", str(self.inventory), "--bundle", str(self.bundle),
            "--expected-bundle-sha256", self.bundle_sha,
            "--expected-base-oid", self.base_oid,
            "--result", str(self.artifacts / "unused.json"),
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("invalid choice", rejected.stderr)

    def test_precheck_reports_every_problem_in_one_pass(self) -> None:
        # The point of precheck is that one run tells the operator everything to fix.
        # Both expectation checks once shared a `try`, so the first bad value hid the
        # second and a two-problem result took two rounds to diagnose.
        # Malformed, not merely mismatched: all-zero hex is a VALID sha256/OID shape and
        # would only trip the separate binding checks those two other tests cover.
        code, out = self.precheck(
            self.combined(), expected_bundle_sha="not-a-sha", expected_base_oid="not-an-oid"
        )
        self.assertEqual(code, 1, out)
        self.assertTrue(any("SHA-256" in item for item in out["problems"]), out)
        self.assertTrue(any("base OID" in item for item in out["problems"]), out)

    def test_precheck_reports_a_bad_inventory_shape(self) -> None:
        bad = self.artifacts / "bad-inventory.json"
        self.write_json(bad, [{"ref": "REQ-009", "id": "x", "summary": "out of order"}])
        code, out = self.precheck(self.combined(), inventory=bad)
        self.assertEqual(code, 1)
        self.assertTrue(any("inventory:" in item for item in out["problems"]), out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
PY
