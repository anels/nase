#!/usr/bin/env bash
# Regression tests for local workspace skill manifest verification.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/workspace-skill-integrity.py"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/workspace/skills" \
  "$TMPDIR_TEST/.claude/commands/nase/workspace"

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

python3 "$SCRIPT" --root "$TMPDIR_TEST" write-manifest > "$TMPDIR_TEST/write.json"
jq -e '.sources.alpha' "$TMPDIR_TEST/write.json" >/dev/null
python3 "$SCRIPT" --root "$TMPDIR_TEST" check > "$TMPDIR_TEST/check.json"
jq -e '.ok == true and (.errors | length) == 0' "$TMPDIR_TEST/check.json" >/dev/null

printf 'victim\n' > "$TMPDIR_TEST/victim.txt"
ln -s "$TMPDIR_TEST/victim.txt" "$TMPDIR_TEST/workspace/skills/.nase-manifest.tmp"
python3 "$SCRIPT" --root "$TMPDIR_TEST" write-manifest > /dev/null
if [[ "$(cat "$TMPDIR_TEST/victim.txt")" == "victim" ]] \
  && [[ "$(stat -c '%a' "$TMPDIR_TEST/workspace/skills/.nase-manifest.json" 2>/dev/null || stat -f '%Lp' "$TMPDIR_TEST/workspace/skills/.nase-manifest.json")" == "600" ]] \
  && [[ -z "$(find "$TMPDIR_TEST/workspace/skills" -name '.nase-manifest.json.*')" ]]; then
  printf 'PASS  manifest write ignores a planted temp symlink and stays 0600\n'
else
  printf 'FAIL  manifest write ignores a planted temp symlink and stays 0600\n' >&2
  exit 1
fi
rm -f "$TMPDIR_TEST/workspace/skills/.nase-manifest.tmp"

printf '\nChanged source.\n' >>"$TMPDIR_TEST/workspace/skills/alpha.md"
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

python3 "$SCRIPT" --root "$TMPDIR_TEST" write-manifest > "$TMPDIR_TEST/refresh-body-only.json"
if jq -e '.sources.alpha' "$TMPDIR_TEST/refresh-body-only.json" >/dev/null; then
  printf 'PASS  manifest refresh accepts source body changes\n'
else
  printf 'FAIL  manifest refresh accepts source body changes\n' >&2
  exit 1
fi

sed -i.bak '5i\
model: sonnet
' "$TMPDIR_TEST/workspace/skills/alpha.md"
rm -f "$TMPDIR_TEST/workspace/skills/alpha.md.bak"
set +e
python3 "$SCRIPT" --root "$TMPDIR_TEST" write-manifest > "$TMPDIR_TEST/metadata-drift.json"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && jq -e 'any(.errors[]; contains("wrapper model metadata differs"))' "$TMPDIR_TEST/metadata-drift.json" >/dev/null; then
  printf 'PASS  manifest refresh refuses wrapper metadata drift\n'
else
  printf 'FAIL  manifest refresh refuses wrapper metadata drift\n' >&2
  exit 1
fi

sed -i.bak '/^model: sonnet$/d' "$TMPDIR_TEST/workspace/skills/alpha.md"
rm -f "$TMPDIR_TEST/workspace/skills/alpha.md.bak"
mkdir -p "$TMPDIR_TEST/.claude/skills/nase-workspace-alpha"
cat > "$TMPDIR_TEST/.claude/skills/nase-workspace-alpha/SKILL.md" <<'SKILL'
<!-- NASE-GENERATED-WORKSPACE-SKILL; source: workspace/skills/alpha.md -->
SKILL
set +e
python3 "$SCRIPT" --root "$TMPDIR_TEST" check > "$TMPDIR_TEST/legacy-native.json"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && jq -e 'any(.errors[]; contains("obsolete generated native mirror remains"))' "$TMPDIR_TEST/legacy-native.json" >/dev/null; then
  printf 'PASS  legacy native mirror fails local check\n'
else
  printf 'FAIL  legacy native mirror fails local check\n' >&2
  exit 1
fi

rm -rf "$TMPDIR_TEST/.claude/skills/nase-workspace-alpha"
python3 "$SCRIPT" --root "$TMPDIR_TEST" check > "$TMPDIR_TEST/final-check.json"
jq -e '.ok == true and (.errors | length) == 0' "$TMPDIR_TEST/final-check.json" >/dev/null

# An imported skill never gets allowed-tools, context or agent in its wrapper, and
# a sync followed by check stays clean.
IMPORT_ROOT=$(mktemp -d)
mkdir -p "$IMPORT_ROOT/workspace/skills" "$IMPORT_ROOT/.claude/commands/nase/workspace"
cat > "$IMPORT_ROOT/workspace/skills/imported.md" <<'SKILL'
---
description: Imported skill.
imported-from: team-share
model: sonnet
allowed-tools: Bash(*)
context: fork
agent: general-purpose
---

Do the thing.
SKILL
cat > "$IMPORT_ROOT/workspace/skills/own.md" <<'SKILL'
---
description: Own skill.
allowed-tools: Read
---

Do the other thing.
SKILL
python3 "$ROOT/.claude/scripts/sync-workspace-skills.py" --root "$IMPORT_ROOT" >/dev/null || [[ $? -eq 10 ]]
imported_wrapper="$IMPORT_ROOT/.claude/commands/nase/workspace/imported.md"
own_wrapper="$IMPORT_ROOT/.claude/commands/nase/workspace/own.md"
if grep -q '^model: sonnet' "$imported_wrapper" \
  && ! grep -Eq '^(allowed-tools|context|agent):' "$imported_wrapper" \
  && grep -q '^allowed-tools: Read' "$own_wrapper"; then
  printf 'PASS  imported skill wrapper drops privileged keys, own skill keeps them\n'
else
  printf 'FAIL  imported skill wrapper drops privileged keys, own skill keeps them\n' >&2
  exit 1
fi
python3 "$SCRIPT" --root "$IMPORT_ROOT" write-manifest > /dev/null
python3 "$SCRIPT" --root "$IMPORT_ROOT" check > "$IMPORT_ROOT/check.json"
jq -e '.ok == true and (.errors | length) == 0' "$IMPORT_ROOT/check.json" >/dev/null
printf 'allowed-tools: Bash(*)\n' > "$IMPORT_ROOT/inject.txt"
sed -i.bak '/^model:/r '"$IMPORT_ROOT/inject.txt" "$imported_wrapper"
set +e
python3 "$SCRIPT" --root "$IMPORT_ROOT" check > "$IMPORT_ROOT/inject.json"
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && jq -e 'any(.errors[]; contains("forwards allowed-tools from an imported skill"))' "$IMPORT_ROOT/inject.json" >/dev/null; then
  printf 'PASS  integrity check flags a privileged key forwarded from an imported skill\n'
else
  printf 'FAIL  integrity check flags a privileged key forwarded from an imported skill\n' >&2
  exit 1
fi
rm -rf "$IMPORT_ROOT"

printf 'workspace skill integrity tests passed.\n'
