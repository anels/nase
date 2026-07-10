#!/usr/bin/env bash
# Regression tests for local workspace skill manifest verification.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace-skill-integrity.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/workspace/skills" \
  "$TMPDIR_TEST/.claude/commands/nase/workspace" \
  "$TMPDIR_TEST/.claude/skills/nase-workspace-alpha"

cat > "$TMPDIR_TEST/workspace/skills/alpha.md" <<'SKILL'
---
description: Alpha skill.
disable-model-invocation: true
argument-hint: "<target>"
---

Read alpha.
SKILL

cat > "$TMPDIR_TEST/.claude/commands/nase/workspace/alpha.md" <<'SKILL'
---
name: nase:workspace:alpha
description: "Alpha skill."
disable-model-invocation: true
argument-hint: "<target>"
---

Read `workspace/skills/alpha.md` and follow every step exactly as written.

$ARGUMENTS
SKILL

cat > "$TMPDIR_TEST/.claude/skills/nase-workspace-alpha/SKILL.md" <<'SKILL'
---
description: "Alpha skill."
disable-model-invocation: true
argument-hint: "<target>"
---

<!-- NASE-GENERATED-WORKSPACE-SKILL; source: workspace/skills/alpha.md -->

Read alpha.
SKILL

python3 "$SCRIPT" --root "$TMPDIR_TEST" write-manifest > "$TMPDIR_TEST/write.json"
jq -e '.sources.alpha' "$TMPDIR_TEST/write.json" >/dev/null
python3 "$SCRIPT" --root "$TMPDIR_TEST" check > "$TMPDIR_TEST/check.json"
jq -e '.ok == true and (.errors | length) == 0' "$TMPDIR_TEST/check.json" >/dev/null

printf '\nChanged source.\n' >> "$TMPDIR_TEST/workspace/skills/alpha.md"
python3 "$SCRIPT" --root "$TMPDIR_TEST" changed > "$TMPDIR_TEST/changed.json"
jq -e '.ok == true and .changed == ["alpha"]' "$TMPDIR_TEST/changed.json" >/dev/null
set +e
python3 "$SCRIPT" --root "$TMPDIR_TEST" check > "$TMPDIR_TEST/drift.json"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && jq -e 'any(.errors[]; contains("manifest hash differs"))' "$TMPDIR_TEST/drift.json" >/dev/null; then
  printf 'PASS  source hash drift fails local check\n'
else
  printf 'FAIL  source hash drift fails local check\n' >&2
  exit 1
fi

set +e
python3 "$SCRIPT" --root "$TMPDIR_TEST" write-manifest > "$TMPDIR_TEST/refresh-drift.json"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && jq -e 'any(.errors[]; contains("refusing to refresh the manifest"))' "$TMPDIR_TEST/refresh-drift.json" >/dev/null; then
  printf 'PASS  manifest refresh refuses stale generated mirrors\n'
else
  printf 'FAIL  manifest refresh refuses stale generated mirrors\n' >&2
  exit 1
fi

printf '\nChanged source.\n' >> "$TMPDIR_TEST/.claude/skills/nase-workspace-alpha/SKILL.md"
python3 "$SCRIPT" --root "$TMPDIR_TEST" write-manifest >/dev/null
printf '\nmanual drift\n' >> "$TMPDIR_TEST/.claude/skills/nase-workspace-alpha/SKILL.md"
set +e
python3 "$SCRIPT" --root "$TMPDIR_TEST" check > "$TMPDIR_TEST/native-drift.json"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && jq -e 'any(.errors[]; contains("native body differs"))' "$TMPDIR_TEST/native-drift.json" >/dev/null; then
  printf 'PASS  native mirror drift fails local check\n'
else
  printf 'FAIL  native mirror drift fails local check\n' >&2
  exit 1
fi

printf 'workspace skill integrity tests passed.\n'
