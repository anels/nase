#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

PYTHON_BIN=$(command -v python3)
SCRIPT=".claude/scripts/effort-rollup-evidence.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
FIXTURE="$TMPDIR_TEST/nase"
LOCAL_REPO="$TMPDIR_TEST/service"
BIN="$TMPDIR_TEST/bin"
MONTH="2026-08"
mkdir -p "$FIXTURE/workspace/efforts/done" "$FIXTURE/workspace/efforts/archive/2026" "$FIXTURE/.claude/scripts" "$LOCAL_REPO" "$BIN"
cp .claude/scripts/month-efforts.sh "$FIXTURE/.claude/scripts/month-efforts.sh"
git -C "$LOCAL_REPO" init -q
git -C "$LOCAL_REPO" remote add origin https://github.com/example/service.git

cat > "$FIXTURE/workspace/context.md" <<'MD'
# Context

## Repos

- `service` (example/service) - synthetic service

## Team
MD

cat > "$FIXTURE/workspace/config.md" <<'CFG'
github_org: example
work_gh_account: alice
personal_gh_account: personal
CFG

printf 'service=%s\nignored=%s\n' "$LOCAL_REPO" "$TMPDIR_TEST/ignored" > "$FIXTURE/.local-paths"

write_effort() {
  local name="$1" body="$2"
  printf '%s\n' "$body" > "$FIXTURE/workspace/efforts/done/$name.md"
  touch -t 202608081200 "$FIXTURE/workspace/efforts/done/$name.md"
}

write_effort effort-a '---
status: completed
repo: service
pr: https://github.com/example/service/pull/1
---
## Lifecycle
- [x] PR opened - https://github.com/example/service/pull/1'
write_effort effort-b '---
status: completed
repo: service
prs:
  - https://github.com/example/service/pull/1 reused
---
## Lifecycle
- [x] PR opened - https://github.com/example/service/pull/1'
write_effort effort-earlier '---
status: completed
repo: service
phase_2_pr: https://github.com/example/service/pull/2
---'
write_effort effort-closed '---
status: wontfix
repo: service
pr: https://github.com/example/service/pull/3
---'
write_effort effort-tracked '---
status: completed
repo: service
owner: Other Engineer
tracking_only: true
pr: https://github.com/example/service/pull/4
---'
write_effort effort-dependency '---
status: completed
repo: service
blocked-by:
  - https://github.com/example/service/pull/5
---'
write_effort effort-context '---
status: completed
repo: service
---
Context only: https://github.com/example/service/pull/6'
write_effort effort-mixedcase '---
status: completed
repo: service
pr: https://github.com/Example/Service/pull/8
---
## Lifecycle
- [x] PR opened - https://github.com/Example/Service/pull/8'

GH_LOG="$TMPDIR_TEST/gh.log"
export GH_LOG
cat > "$BIN/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["GH_LOG"], "a", encoding="utf-8") as handle:
    handle.write("\t".join(args) + "\n")
mode = os.environ.get("GH_MODE", "ok")
if args == ["--version"]:
    print("gh version fake-1")
    raise SystemExit(0)
if args in (["search", "prs", "--help"], ["pr", "view", "--help"]):
    print("help")
    raise SystemExit(0)
if args[:2] == ["auth", "status"]:
    if mode == "auth-fail":
        print("authentication failed", file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps({"hosts": {"github.com": [{"state": "success", "active": True, "login": "reader", "tokenSource": "fixture-secret-source"}]}}))
    raise SystemExit(0)
if args[:2] == ["api", "rate_limit"]:
    print(json.dumps({"resources": {"search": {"remaining": 30, "reset": 0}}}))
    raise SystemExit(0)
if args[:2] == ["search", "prs"]:
    if mode == "failed-search":
        print("network connection failed", file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps([
        {"number": 1, "title": "One", "url": "https://github.com/example/service/pull/1", "state": "closed", "author": {"login": "alice"}, "createdAt": "2026-07-01T00:00:00Z", "closedAt": "2026-08-02T00:00:00Z"},
        {"number": 7, "title": "Seven", "url": "https://github.com/example/service/pull/7", "state": "closed", "author": {"login": "alice"}, "createdAt": "2026-08-01T00:00:00Z", "closedAt": "2026-08-03T00:00:00Z"}
    ]))
    raise SystemExit(0)
if args[:2] == ["pr", "view"]:
    number = int(args[2])
    merged = {
        1: "2026-08-02T00:00:00Z",
        2: "2026-07-28T00:00:00Z",
        3: None,
        4: "2026-08-04T00:00:00Z",
        5: "2026-08-05T00:00:00Z",
        6: "2026-08-06T00:00:00Z",
        7: "2026-08-03T00:00:00Z",
        8: "2026-08-07T00:00:00Z",
    }[number]
    title = "ghp_" + "A" * 24 if mode == "secret-title" else f"PR {number}"
    slug = "Example/Service" if number == 8 else "example/service"
    print(json.dumps({"number": number, "title": title, "state": "MERGED" if merged else "CLOSED", "mergedAt": merged, "author": {"login": "alice"}, "url": f"https://github.com/{slug}/pull/{number}"}))
    raise SystemExit(0)
print("unexpected command", file=sys.stderr)
raise SystemExit(9)
PY
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

failures=0
source "$ROOT/tests/lib/assert.sh"

collect_bundle() {
  "$PYTHON_BIN" "$SCRIPT" collect --root "$FIXTURE" --month "$MONTH" --bundle "$1" --format json
}

expect_fail() {
  if "$@"; then return 1; fi
  return 0
}

BUNDLE="$TMPDIR_TEST/bundle"
assert_cmd "valid complete bundle collects" collect_bundle "$BUNDLE"
assert_cmd "scope and critical totals are derived" "$PYTHON_BIN" - "$BUNDLE/run.json" "$BUNDLE/evidence.json" <<'PY'
import json
import sys
run = json.load(open(sys.argv[1], encoding="utf-8"))
evidence = json.load(open(sys.argv[2], encoding="utf-8"))
assert [repo["alias"] for repo in run["scope"]["expected_repos"]] == ["service"]
assert run["scope"]["local_availability"] == [{"alias": "service", "status": "available"}]
assert [source["account"] for source in run["scope"]["github_sources"]] == ["alice"]
assert evidence["coverage"] == {"status": "complete-for-declared-sources", "gaps": []}
assert evidence["totals"] == {
    "delivered_efforts": 4,
    "merged_delivery_prs_in_month": 2,
    "tracked_external_efforts": 1,
    "untracked_merged_pr_candidates": 1,
}
efforts = {item["slug"]: item for item in evidence["efforts"]}
assert efforts["effort-a"]["bucket"] == "merged-in-month"
assert efforts["effort-b"]["countable"] is True
assert efforts["effort-earlier"]["bucket"] == "merged-earlier"
assert efforts["effort-closed"]["countable"] is False
assert efforts["effort-tracked"]["bucket"] == "tracked-external"
assert efforts["effort-dependency"]["classification_errors"] == []
prs = {item["number"]: item for item in evidence["prs"]}
assert prs[1]["countable"] is True
assert prs[5]["role"] == "dependency" and prs[5]["countable"] is False
assert prs[6]["role"] == "context-only" and prs[6]["countable"] is False
assert prs[7]["role"] == "untracked-candidate" and prs[7]["countable"] is False
assert prs[8]["owner"] == "Example" and prs[8]["repo"] == "Service"
assert prs[8]["url"] == "https://github.com/Example/Service/pull/8"
assert prs[8]["countable"] is True
PY

assert_cmd "exact repo author and month query is owned by helper" grep -Fq $'search\tprs\t--repo\texample/service\t--author\talice\t--merged-at\t2026-08-01..2026-08-31\t--limit\t1000\t--json\tnumber,title,url,state,author,createdAt,closedAt' "$GH_LOG"
assert_cmd "extra local-path aliases do not expand scope" bash -c '! grep -Fq ignored "$1"' _ "$BUNDLE/run.json"
assert_cmd "pre-render validation re-derives evidence" "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json

EVIDENCE_SHA=$(shasum -a 256 "$BUNDLE/evidence.json" | awk '{print $1}')
cat > "$BUNDLE/report.fresh.md" <<EOF
# Rollup
Evidence SHA: $EVIDENCE_SHA
Measurement basis: effort-rollup-v2
Coverage: complete-for-declared-sources
Delivered efforts: 4
Merged delivery PRs in month: 2
effort:effort-a
effort:effort-b
effort:effort-earlier
effort:effort-mixedcase
https://github.com/example/service/pull/1
https://github.com/Example/Service/pull/8
EOF
assert_cmd "rendered Markdown binds evidence and counted records" "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --markdown "$BUNDLE/report.fresh.md" --format json

cp "$BUNDLE/evidence.json" "$TMPDIR_TEST/evidence.original"
cp "$BUNDLE/run.json" "$TMPDIR_TEST/run.original"
"$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["totals"]["delivered_efforts"] += 1
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "declared total drift fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

first_capture=$("$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["captures"][0]["capture_path"])
PY
)
cp "$BUNDLE/$first_capture" "$TMPDIR_TEST/capture.original"
printf 'drift\n' >> "$BUNDLE/$first_capture"
assert_cmd "capture hash drift fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/capture.original" "$BUNDLE/$first_capture"

cp "$FIXTURE/workspace/context.md" "$TMPDIR_TEST/context.original"
printf '\n' >> "$FIXTURE/workspace/context.md"
assert_cmd "context hash drift fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/context.original" "$FIXTURE/workspace/context.md"

"$PYTHON_BIN" - "$BUNDLE/run.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
del data["input_hashes"][".local-paths"]
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "missing required input hash fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/run.original" "$BUNDLE/run.json"

"$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
entry = next(item for item in data["captures"] if item["kind"] == "github-search")
old = "2026-08-01..2026-08-31"
new = "2026-08-01..2026-08-15"
entry["source_id"] = entry["source_id"].replace(old, new)
entry["logical_window"]["end"] = "2026-08-15"
entry["command"][entry["command"].index("--merged-at") + 1] = new
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "narrowed search window cannot replace full-month capture" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

"$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
entry = next(item for item in data["captures"] if item["kind"] == "github-search")
entry["record_count"] += 1
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "capture record-count drift fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

"$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["ignored"] = "ghp_" + "A" * 24
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "secret-bearing manifest fails validation" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

pr_one_capture=$("$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
entry = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["captures"] if item["kind"] == "github-pr" and item["logical_window"]["pr"].endswith("#1"))
print(entry["capture_path"])
PY
)
cp "$BUNDLE/$pr_one_capture" "$TMPDIR_TEST/pr-one.original"
"$PYTHON_BIN" - "$BUNDLE/evidence.json" "$BUNDLE/$pr_one_capture" <<'PY'
import hashlib
import json
import sys
manifest, capture = sys.argv[1:]
data = json.load(open(manifest, encoding="utf-8"))
entry = next(item for item in data["captures"] if item["kind"] == "github-pr" and item["logical_window"]["pr"].endswith("#1"))
value = json.load(open(capture, encoding="utf-8"))
value["number"] = 99
value["url"] = "https://github.com/example/service/pull/99"
raw = (json.dumps(value) + "\n").encode()
open(capture, "wb").write(raw)
entry["sha256"] = hashlib.sha256(raw).hexdigest()
json.dump(data, open(manifest, "w", encoding="utf-8"))
PY
assert_cmd "PR response identity drift fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/pr-one.original" "$BUNDLE/$pr_one_capture"
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

"$PYTHON_BIN" - "$BUNDLE/evidence.json" "$BUNDLE" <<'PY'
import hashlib
import json
import sys
manifest, bundle = sys.argv[1:]
data = json.load(open(manifest, encoding="utf-8"))
template = next(item for item in data["captures"] if item["kind"] == "github-pr")
value = {"number": 99, "title": "Extra", "state": "MERGED", "mergedAt": "2026-08-09T00:00:00Z", "author": {"login": "alice"}, "url": "https://github.com/example/service/pull/99"}
raw = (json.dumps(value) + "\n").encode()
capture_path = f"{bundle}/captures/9999-github-pr.json"
open(capture_path, "wb").write(raw)
entry = dict(template)
entry.update({
    "source_id": "github-pr:example/service#99",
    "logical_window": {"pr": "example/service#99"},
    "command": ["gh", "pr", "view", "99", "--repo", "example/service", "--json", "number,title,state,mergedAt,author,url"],
    "capture_path": "captures/9999-github-pr.json",
    "sha256": hashlib.sha256(raw).hexdigest(),
})
data["captures"].append(entry)
json.dump(data, open(manifest, "w", encoding="utf-8"))
PY
assert_cmd "unexpected canonical PR capture fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
rm "$BUNDLE/captures/9999-github-pr.json"
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

"$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["efforts"][0]["bucket"] = "excluded"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "model-facing bucket drift fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

"$PYTHON_BIN" - "$BUNDLE/evidence.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["captures"][0]["capture_path"] = "../escape.json"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "capture path escape fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/evidence.original" "$BUNDLE/evidence.json"

"$PYTHON_BIN" - "$BUNDLE/run.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["collection_finished_at"] = "2000-01-01T00:00:00Z"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
assert_cmd "stale collection fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json
cp "$TMPDIR_TEST/run.original" "$BUNDLE/run.json"

printf '{"ignored":true}\n' > "$BUNDLE/supplemental/jira.json"
assert_cmd "supplemental bytes cannot alter canonical totals" "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --format json

cat > "$BUNDLE/report.bad.md" <<'MD'
Evidence SHA: wrong
Measurement basis: effort-rollup-v2
Coverage: complete-for-declared-sources
Delivered efforts: 3
Merged delivery PRs in month: 1
MD
assert_cmd "Markdown missing evidence and canonical records fails" expect_fail "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$BUNDLE/evidence.json" --markdown "$BUNDLE/report.bad.md" --format json

assert_cmd "non-empty bundle refuses implicit resume" expect_fail collect_bundle "$BUNDLE"
assert_cmd "foreign repo filter fails closed" expect_fail "$PYTHON_BIN" "$SCRIPT" collect --root "$FIXTURE" --month "$MONTH" --bundle "$TMPDIR_TEST/foreign" --repo absent --format json
assert_cmd "unsupported scope argument is rejected" expect_fail "$PYTHON_BIN" "$SCRIPT" collect --root "$FIXTURE" --month "$MONTH" --bundle "$TMPDIR_TEST/scope" --scope narrow --format json

FILTERED="$TMPDIR_TEST/filtered"
assert_cmd "declared repo filter collects" "$PYTHON_BIN" "$SCRIPT" collect --root "$FIXTURE" --month "$MONTH" --bundle "$FILTERED" --repo service --format json
assert_cmd "repo filter is stored visibly" "$PYTHON_BIN" - "$FILTERED/run.json" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["scope"]["repo_filter"] == "service"
PY

cp "$FIXTURE/workspace/context.md" "$TMPDIR_TEST/context.valid"
"$PYTHON_BIN" - "$FIXTURE/workspace/context.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("## Team", "- `service` (example/service) - duplicate\n\n## Team")
open(path, "w", encoding="utf-8").write(text)
PY
assert_cmd "duplicate context repo fails closed" expect_fail "$PYTHON_BIN" "$SCRIPT" collect --root "$FIXTURE" --month "$MONTH" --bundle "$TMPDIR_TEST/duplicate-context" --format json
cp "$TMPDIR_TEST/context.valid" "$FIXTURE/workspace/context.md"

printf '%s\n' '---
status: completed
repo: service
pr: https://github.com/example/service/pull/1
---' > "$FIXTURE/workspace/efforts/effort-a.md"
assert_cmd "duplicate effort slug across locations fails closed" expect_fail collect_bundle "$TMPDIR_TEST/duplicate-slug"
rm "$FIXTURE/workspace/efforts/effort-a.md"

write_effort effort-invalid '---
status: declined
repo: service
pr: https://github.com/example/service/pull/1
---'
INVALID_STATUS="$TMPDIR_TEST/invalid-status"
assert_cmd "unsupported effort status becomes explicit partial coverage" collect_bundle "$INVALID_STATUS"
assert_cmd "unsupported status is excluded from totals" "$PYTHON_BIN" - "$INVALID_STATUS/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-invalid")
assert effort["bucket"] == "excluded" and "invalid-status" in effort["classification_errors"]
assert data["coverage"]["status"] == "partial"
assert data["totals"]["delivered_efforts"] == 4
PY
rm "$FIXTURE/workspace/efforts/done/effort-invalid.md"

write_effort effort-ownerless '---
status: completed
repo: service
tracking_only: true
pr: https://github.com/example/service/pull/4
---'
OWNERLESS="$TMPDIR_TEST/ownerless"
assert_cmd "tracking-only effort without owner becomes explicit partial coverage" collect_bundle "$OWNERLESS"
assert_cmd "ownerless tracking effort is excluded" "$PYTHON_BIN" - "$OWNERLESS/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-ownerless")
assert effort["bucket"] == "excluded" and "missing-owner" in effort["classification_errors"]
assert data["totals"]["tracked_external_efforts"] == 1
PY
rm "$FIXTURE/workspace/efforts/done/effort-ownerless.md"

write_effort effort-location '---
status: in-progress
repo: service
pr: https://github.com/example/service/pull/1
---'
LOCATION_MISMATCH="$TMPDIR_TEST/location-mismatch"
assert_cmd "done effort with active status becomes explicit partial coverage" collect_bundle "$LOCATION_MISMATCH"
assert_cmd "status-location mismatch is excluded" "$PYTHON_BIN" - "$LOCATION_MISMATCH/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-location")
assert effort["bucket"] == "excluded" and "status-location-mismatch" in effort["classification_errors"]
assert data["totals"]["delivered_efforts"] == 4
PY
rm "$FIXTURE/workspace/efforts/done/effort-location.md"

write_effort effort-denied '---
status: completed
repo: service
---

## Lifecycle
- [x] PR opened - [#1](https://github.com/example/service/pull/1) - query numbers, **not** PR numbers; a bare sweep resolved `#5` to the unrelated CLOSED `example/service#5`'
DENIED="$TMPDIR_TEST/denied-pr-reference"
assert_cmd "denied bare PR numbers do not enter rollup delivery evidence" collect_bundle "$DENIED"
assert_cmd "rollup reuses lifecycle PR reference resolution" "$PYTHON_BIN" - "$DENIED/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-denied")
assert effort["delivery_prs"] == ["https://github.com/example/service/pull/1"]
assert "https://github.com/example/service/pull/5" not in effort["delivery_prs"]
assert effort["context_only_prs"] == []
PY
rm "$FIXTURE/workspace/efforts/done/effort-denied.md"

write_effort effort-bare '---
status: completed
repo: example/service
pr: "#1"
prs:
- "#2"

# another delivery
- "#3"
blocked-by:
- "#5"

# another dependency
- "#6"
---'
BARE="$TMPDIR_TEST/bare-pr-reference"
assert_cmd "owner-qualified bare PR references remain valid rollup evidence" collect_bundle "$BARE"
assert_cmd "rollup accepts canonical helper bare delivery and dependency references" "$PYTHON_BIN" - "$BARE/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-bare")
assert effort["classification_errors"] == []
assert effort["delivery_prs"] == [
    "https://github.com/example/service/pull/1",
    "https://github.com/example/service/pull/2",
    "https://github.com/example/service/pull/3",
]
assert effort["dependency_prs"] == [
    "https://github.com/example/service/pull/5",
    "https://github.com/example/service/pull/6",
]
PY
rm "$FIXTURE/workspace/efforts/done/effort-bare.md"

write_effort effort-malformed-pr '---
status: completed
repo: service
pr: definitely-not-a-pr
---'
MALFORMED_PR="$TMPDIR_TEST/malformed-pr"
assert_cmd "malformed PR reference yields partial coverage" collect_bundle "$MALFORMED_PR"
assert_cmd "malformed PR remains a classification error" "$PYTHON_BIN" - "$MALFORMED_PR/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-malformed-pr")
assert "unresolved-pr" in effort["classification_errors"]
assert data["coverage"]["status"] == "partial"
PY
rm "$FIXTURE/workspace/efforts/done/effort-malformed-pr.md"

write_effort effort-malformed-qualified-repo '---
status: completed
repo: example/service
pr: definitely-not-a-pr
---'
QUALIFIED_MALFORMED="$TMPDIR_TEST/malformed-qualified-repo"
assert_cmd "owner-qualified repo keeps malformed effort in scoped coverage" collect_bundle "$QUALIFIED_MALFORMED"
assert_cmd "owner-qualified malformed effort is explicit partial coverage" "$PYTHON_BIN" - "$QUALIFIED_MALFORMED/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-malformed-qualified-repo")
assert "unresolved-pr" in effort["classification_errors"]
assert data["coverage"]["status"] == "partial"
PY
rm "$FIXTURE/workspace/efforts/done/effort-malformed-qualified-repo.md"

write_effort effort-multiple-pr-scalar '---
status: completed
repo: service
pr: "example/service#1 example/service#2"
---'
MULTIPLE_SCALAR="$TMPDIR_TEST/multiple-pr-scalar"
assert_cmd "multiple bare references in scalar pr yield partial coverage" collect_bundle "$MULTIPLE_SCALAR"
assert_cmd "scalar pr retains its one-reference contract" "$PYTHON_BIN" - "$MULTIPLE_SCALAR/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
effort = next(item for item in data["efforts"] if item["slug"] == "effort-multiple-pr-scalar")
assert "unresolved-pr" in effort["classification_errors"]
assert data["coverage"]["status"] == "partial"
PY
rm "$FIXTURE/workspace/efforts/done/effort-multiple-pr-scalar.md"

cp "$FIXTURE/.local-paths" "$TMPDIR_TEST/local-paths.original"
printf 'ignored=%s\n' "$TMPDIR_TEST/ignored" > "$FIXTURE/.local-paths"
PARTIAL="$TMPDIR_TEST/partial"
assert_cmd "missing local mapping yields partial without removing discovery" collect_bundle "$PARTIAL"
assert_cmd "partial bundle remains internally valid" "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$PARTIAL/evidence.json" --format json
assert_cmd "partial coverage is explicit" "$PYTHON_BIN" - "$PARTIAL/run.json" "$PARTIAL/evidence.json" <<'PY'
import json
import sys
run = json.load(open(sys.argv[1], encoding="utf-8"))
evidence = json.load(open(sys.argv[2], encoding="utf-8"))
assert run["scope"]["local_availability"] == [{"alias": "service", "status": "missing"}]
assert evidence["coverage"]["status"] == "partial"
assert run["scope"]["github_sources"][0]["status"] == "complete"
PY
cp "$TMPDIR_TEST/local-paths.original" "$FIXTURE/.local-paths"

AUTH_BUNDLE="$TMPDIR_TEST/auth-fail"
GH_MODE=auth-fail assert_cmd "auth failure fails collection" expect_fail collect_bundle "$AUTH_BUNDLE"

SECRET_BUNDLE="$TMPDIR_TEST/secret-capture"
GH_MODE=secret-title assert_cmd "secret-bearing authority response fails collection" expect_fail collect_bundle "$SECRET_BUNDLE"
assert_cmd "secret-bearing authority response is not persisted" bash -c '! grep -R -Fq "ghp_" "$1"' _ "$SECRET_BUNDLE"

FAILED_SEARCH="$TMPDIR_TEST/failed-search"
GH_MODE=failed-search assert_cmd "exhausted search retry becomes partial" collect_bundle "$FAILED_SEARCH"
assert_cmd "partial failed-search bundle revalidates" "$PYTHON_BIN" "$SCRIPT" validate --root "$FIXTURE" --month "$MONTH" --manifest "$FAILED_SEARCH/evidence.json" --format json
assert_cmd "failed search records three attempts and nonzero partial coverage" "$PYTHON_BIN" - "$FAILED_SEARCH/evidence.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
search = next(item for item in data["captures"] if item["kind"] == "github-search")
assert search["attempt_count"] == 3
assert search["status"] == "failed"
assert data["coverage"]["status"] == "partial"
assert data["totals"]["merged_delivery_prs_in_month"] == 2
PY

if [[ "$failures" -eq 0 ]]; then
  printf '\neffort-rollup-evidence tests passed.\n'
  exit 0
fi

printf '\n%d effort-rollup-evidence assertion(s) failed.\n' "$failures" >&2
exit 1
