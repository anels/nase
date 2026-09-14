#!/usr/bin/env bash
# Behavioural tests for .claude/scripts/grill-frontier.py.
#
# The grill loop used to run cycle detection, transitive closure, a dependency-closed
# cap, and a budget by hand every round, and the only checks on any of it were
# assert_contains on the prose that described it. These assert the algorithm instead.
#
# Run from repo root:  bash tests/scripts/test-grill-frontier.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

python3 - "$ROOT" <<'PY'
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(sys.argv[1])
SCRIPT = ROOT / ".claude" / "scripts" / "grill-frontier.py"


def run(payload: dict) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
    )


def ok(payload: dict) -> dict:
    proc = run(payload)
    if proc.returncode != 0:
        raise AssertionError(f"expected success, got {proc.returncode}: {proc.stderr}")
    return json.loads(proc.stdout)


CHAIN = [
    {"id": "a", "depends_on": []},
    {"id": "b", "depends_on": ["a"]},
    {"id": "c", "depends_on": ["b"]},
]


class GrillFrontierTests(unittest.TestCase):
    def test_frontier_is_only_the_unblocked_head(self) -> None:
        result = ok({"branches": CHAIN})
        self.assertEqual(result["frontier_ids"], ["a"])
        self.assertEqual(result["blocked_ids"], ["b", "c"])
        self.assertFalse(result["terminated"])

    def test_resolving_a_prerequisite_advances_the_frontier(self) -> None:
        result = ok({"branches": CHAIN, "resolved": ["a"]})
        self.assertEqual(result["frontier_ids"], ["b"])
        self.assertEqual(result["blocked_ids"], ["c"])

    def test_a_resolved_branch_never_returns_to_the_frontier(self) -> None:
        result = ok({"branches": CHAIN, "resolved": ["a", "b"]})
        self.assertEqual(result["frontier_ids"], ["c"])
        self.assertNotIn("a", result["kept_ids"])

    def test_deferral_carries_transitive_dependents_out(self) -> None:
        result = ok({"branches": CHAIN, "deferred": ["b"]})
        self.assertEqual(result["open_after_grill_ids"], ["b", "c"])
        self.assertEqual(result["frontier_ids"], ["a"])

    def test_everything_settled_terminates(self) -> None:
        result = ok({"branches": CHAIN, "resolved": ["a", "b", "c"]})
        self.assertTrue(result["terminated"])
        self.assertEqual(result["frontier_ids"], [])

    def test_cycle_is_rejected_and_named(self) -> None:
        proc = run(
            {"branches": [{"id": "a", "depends_on": ["b"]}, {"id": "b", "depends_on": ["a"]}]}
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("dependency cycle", proc.stderr)

    def test_self_dependency_is_rejected(self) -> None:
        proc = run({"branches": [{"id": "a", "depends_on": ["a"]}]})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("depends on itself", proc.stderr)

    def test_unknown_dependency_id_is_rejected(self) -> None:
        proc = run({"branches": [{"id": "a", "depends_on": ["nope"]}]})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("unknown id", proc.stderr)

    def test_duplicate_id_is_rejected(self) -> None:
        proc = run({"branches": [{"id": "a"}, {"id": "a"}]})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("duplicate branch id", proc.stderr)

    def test_resolved_naming_an_unknown_branch_is_rejected(self) -> None:
        proc = run({"branches": [{"id": "a"}], "resolved": ["ghost"]})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("unknown id", proc.stderr)

    def test_cap_never_keeps_a_branch_without_its_prerequisite(self) -> None:
        branches = [{"id": f"f{i}", "depends_on": []} for i in range(14)]
        branches.append({"id": "dep", "depends_on": []})
        branches.append({"id": "big", "depends_on": ["dep"], "load_bearing": True})
        result = ok({"branches": branches, "cap": 3})
        self.assertIn("big", result["kept_ids"])
        self.assertIn("dep", result["kept_ids"])
        self.assertLessEqual(len(result["kept_ids"]), 3)
        for kept in result["kept_ids"]:
            for dep in next(b for b in branches if b["id"] == kept).get("depends_on", []):
                self.assertIn(dep, result["kept_ids"])

    def test_cap_drop_carries_dependents_out_too(self) -> None:
        branches = [
            {"id": "keep", "depends_on": [], "load_bearing": True},
            {"id": "drop", "depends_on": []},
            {"id": "child", "depends_on": ["drop"]},
        ]
        result = ok({"branches": branches, "cap": 1})
        self.assertEqual(result["kept_ids"], ["keep"])
        self.assertIn("drop", result["cap_dropped_ids"])
        self.assertIn("child", result["cap_dropped_ids"])

    def test_load_bearing_branches_are_capped_in_first(self) -> None:
        branches = [
            {"id": "shallow1", "depends_on": []},
            {"id": "shallow2", "depends_on": []},
            {"id": "security", "depends_on": [], "load_bearing": True},
        ]
        result = ok({"branches": branches, "cap": 1})
        self.assertEqual(result["kept_ids"], ["security"])

    def test_budget_bounds_the_ask_allowance(self) -> None:
        branches = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
        result = ok({"branches": branches, "budget_total": 25, "budget_spent": 23})
        self.assertEqual(result["budget_remaining"], 2)
        self.assertEqual(result["ask_allowance"], 2)

    def test_ask_allowance_never_exceeds_the_frontier(self) -> None:
        result = ok({"branches": [{"id": "a"}], "budget_total": 25, "budget_spent": 0})
        self.assertEqual(result["ask_allowance"], 1)

    def test_branch_fields_survive_the_round_trip(self) -> None:
        result = ok(
            {"branches": [{"id": "a", "topic": "rollout", "persona": "sre"}]}
        )
        self.assertEqual(result["frontier"][0]["topic"], "rollout")
        self.assertEqual(result["frontier"][0]["persona"], "sre")

    def test_malformed_input_is_rejected(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(SCRIPT)], input="not json", text=True, capture_output=True
        )
        self.assertEqual(proc.returncode, 1)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
