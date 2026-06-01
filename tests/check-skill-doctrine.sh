#!/usr/bin/env bash
# Enforce skill-authoring doctrine across .claude/commands/nase/ + workspace/skills/.
#
# FAILS on:
#   D1. curl-with-PAT for ADO endpoints (must use az CLI per feedback_ado-az-cli-only.md)
#   D2. mkdir line in init.md missing any workspace/kb/* subdir whose stub-write step follows
#   D3. files claiming "at HEAD" in a verifier role but greping the working tree without
#       `git show HEAD:` (regression guard for doc-pr-head-ground-scan.md)
#   D4. skill files missing a language preflight / language-config reference
#   D5. Codex MCP caller files missing the canonical prerequisite / clean-skip gate
#   D6. restore archive flow missing path traversal / symlink hardening
#   D7. kb-merge external import flow missing canonical path / symlink hardening
#   D8. kb-merge generated skill wrappers missing frontmatter sanitization
#
# WARNS (does not fail) on:
#   W1. mutation-keyword skills (Slack/Jira/Confluence/ADO/GitHub PR writes) missing reference
#       to .claude/docs/external-mutation-policy.md
#
# Exit codes: 0 = no failures (warnings OK), N = N failure types tripped.
#
# Run from repo root:  bash tests/check-skill-doctrine.sh

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 1

# Skills under review
SKILL_DIRS=(.claude/commands/nase workspace/skills)

failed=0
warnings=0

red()    { printf '\033[31m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
green()  { printf '\033[32m%s\033[0m' "$1"; }

section() { printf '\n--- %s ---\n' "$1"; }

skill_scan_text() {
  awk '
    /^```/ { in_code = !in_code; next }
    in_code { next }
    /^### Recommended profiles$/ { in_example_section = 1; next }
    /^### / && in_example_section { in_example_section = 0 }
    in_example_section { next }
    { print }
  ' "$1"
}

# ---------- D1: curl-with-PAT regression -----------------------------------
section "D1: no curl with ADO PAT"
# Pattern: curl ... -u ":$SOMETHING_PAT" OR curl ... -u ":$ADO_PAT" / $AZURE_DEVOPS_PAT etc.
# Join shell-continuation lines first so the common:
#   curl ... \
#     -u ":$ADO_PAT"
# form is caught too.
d1_hits=$(find "${SKILL_DIRS[@]}" -maxdepth 2 -name '*.md' -type f 2>/dev/null \
  | grep -v 'check-skill-doctrine.sh' \
  | while IFS= read -r f; do
      awk '
        {
          if (logical == "") start = FNR
          line = $0
          continued = (line ~ /\\[[:space:]]*$/)
          sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
          logical = logical " " line
          if (!continued) {
            if (logical ~ /curl.*-u[[:space:]]*["\047]?:\$[A-Z_]*PAT/) {
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", logical)
              printf "%s:%d:%s\n", FILENAME, start, logical
            }
            logical = ""
          }
        }
      ' "$f"
    done || true)
if [[ -n "$d1_hits" ]]; then
  red "FAIL"; printf ': curl-with-PAT found — use az CLI / az rest instead\n'
  printf '%s\n' "$d1_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': no curl-with-PAT\n'
fi

# ---------- D2: init.md mkdir covers every kb subdir we later write to -----
section "D2: init.md mkdir covers all kb stub-write targets"
INIT_MD=".claude/commands/nase/init.md"
if [[ ! -f "$INIT_MD" ]]; then
  red "FAIL"; printf ': %s missing — bootstrap skill vanished\n' "$INIT_MD"
  failed=$((failed+1))
else
  # Find every `workspace/kb/<subdir>[/<sub>]/<file>.md` that init.md attempts to create as a stub
  stub_subdirs=$(grep -oE 'workspace/kb/[a-z-]+(/[a-z-]+)?/[A-Za-z0-9._-]+\.md' "$INIT_MD" \
    | sed -E 's|/[A-Za-z0-9._-]+\.md$||' | sort -u)
  mkdir_line=$(grep -E '^[[:space:]]*mkdir -p' "$INIT_MD" | head -1 || true)
  d2_missing=""
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    case " $mkdir_line " in
      *" $d "*) ;;
      *)        d2_missing+="$d"$'\n' ;;
    esac
  done <<< "$stub_subdirs"
  if [[ -n "$d2_missing" ]]; then
    red "FAIL"; printf ': init.md mkdir missing these kb subdirs (stub-write would fail on first run):\n'
    printf '%s' "$d2_missing"
    failed=$((failed+1))
  else
    green "PASS"; printf ': all kb stub subdirs covered\n'
  fi
fi

# ---------- D3: "at HEAD" claims but greps working tree --------------------
section "D3: HEAD-claim skills actually grep HEAD"
d3_hits=""
# Skip auto-generated wrappers under .claude/commands/nase/workspace/ — they only
# reference the source file under workspace/skills/, which is what we actually check.
for f in $(grep -rlE 'at HEAD|verify.*HEAD|grep.*HEAD' "${SKILL_DIRS[@]}" 2>/dev/null \
  | grep -v 'check-skill-doctrine.sh' \
  | grep -v '\.claude/commands/nase/workspace/' || true); do
  # Only files that make a HEAD verification claim
  grep -qE 'at HEAD|verify.*HEAD' "$f" 2>/dev/null || continue
  # Files using `git show HEAD:` / `git grep ... HEAD` are compliant
  grep -qE 'git show HEAD:|git -C [^ ]* grep [^|]* HEAD|git grep [^|]* HEAD' "$f" 2>/dev/null && continue
  # Opt-out: skill declares a clean-tree precondition
  grep -qE 'PR branch must be checked out|working tree.*clean|assume.*checked out clean' "$f" 2>/dev/null && continue
  d3_hits+="  $f"$'\n'
done
if [[ -n "$d3_hits" ]]; then
  red "FAIL"; printf ': files claim "at HEAD" but neither use git show HEAD: nor declare a clean-tree precondition:\n'
  printf '%s' "$d3_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': HEAD-claim skills consistent\n'
fi

# ---------- W1: mutation skills reference policy doc -----------------------
section "W1: mutation skills reference external-mutation-policy.md"
# Keywords that indicate the skill performs an external mutation
MUTATION_RE='(updateConfluencePage|createConfluencePage|transitionJiraIssue|createJiraIssue|editJiraIssue|slack_send_message($|[^_])|gh pr create|gh pr edit|gh pr ready|--add-reviewer|pulls/\{pr_number\}/comments|resolveReviewThread|az pipelines run [^a-z]|az pipelines runs cancel|az pipelines runs update|az rest --method (post|put|patch|delete))'
w1_hits=""
while IFS= read -r f; do
  case "$f" in
    *check-skill-doctrine.sh|*external-mutation-policy.md|*workspace/skills/docs/*) continue ;;
  esac
  skill_scan_text "$f" | grep -qE "$MUTATION_RE" || continue
  if ! grep -q 'external-mutation-policy.md' "$f" 2>/dev/null; then
    w1_hits+="  $f"$'\n'
  fi
done < <(find "${SKILL_DIRS[@]}" -maxdepth 2 -name '*.md' -type f 2>/dev/null)
if [[ -n "$w1_hits" ]]; then
  yellow "WARN"; printf ': mutation-capable skills missing reference to external-mutation-policy.md:\n'
  printf '%s' "$w1_hits"
  warnings=$((warnings+1))
else
  green "PASS"; printf ': all mutation skills reference policy doc\n'
fi

# ---------- D4: all skills have language preflight ------------------------
section "D4: all skills declare language preflight"
d4_hits=""
while IFS= read -r f; do
  case "$f" in
    *workspace/skills/docs/*) continue ;;             # shared docs under skills/docs/ are not skills
    *.claude/commands/nase/workspace/*) continue ;;   # auto-generated wrappers; source lives under workspace/skills/
  esac
  if ! grep -qE 'language-config\.md|Language preflight|## Language|Read.*workspace/config\.md.*Language|conversation:' "$f" 2>/dev/null; then
    d4_hits+="  $f"$'\n'
  fi
done < <(find "${SKILL_DIRS[@]}" -maxdepth 2 -name '*.md' -type f 2>/dev/null)
if [[ -n "$d4_hits" ]]; then
  red "FAIL"; printf ': skill files without language preflight or language-config.md reference:\n'
  printf '%s' "$d4_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': all skills declare language handling\n'
fi

# ---------- D5: Codex MCP stays optional ----------------------------------
section "D5: Codex MCP callers have clean-skip gate"
d5_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if ! grep -qF '.claude/docs/codex-review.md → Prerequisite' "$f" 2>/dev/null \
    || ! grep -qi 'skip cleanly' "$f" 2>/dev/null; then
    d5_hits+="  $f"$'\n'
  fi
done < <(
  grep -rlE 'Codex MCP|mcp__codex__|codex-reply|codex-review\.md' \
    .claude/commands/nase .claude/docs workspace/skills 2>/dev/null \
    | grep -v 'check-skill-doctrine.sh' \
    | grep -v '^\.claude/docs/reference\.md$' \
    | grep -v '^\.claude/docs/codex-review\.md$' || true
)
if [[ -n "$d5_hits" ]]; then
  red "FAIL"; printf ': Codex MCP callers missing prerequisite reference or clean-skip wording:\n'
  printf '%s' "$d5_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': Codex MCP callers degrade cleanly when unavailable\n'
fi

# ---------- D6: restore archive extraction is hardened ---------------------
section "D6: restore archive extraction is path-safe"
RESTORE_MD=".claude/commands/nase/restore.md"
d6_hits=""
for needle in \
  "selected backup is outside backup-target" \
  "parent-traversal paths" \
  "backup payload contains symlinks"; do
  if ! grep -qF "$needle" "$RESTORE_MD" 2>/dev/null; then
    d6_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d6_hits" ]]; then
  red "FAIL"; printf ': restore.md lacks archive path hardening:\n'
  printf '%s' "$d6_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': restore archive member checks present\n'
fi

# ---------- D7: external KB import cannot write outside workspace ----------
section "D7: kb-merge import paths are bounded"
KB_MERGE_MD=".claude/commands/nase/kb-merge.md"
d7_hits=""
for needle in \
  "Import Path Hardening" \
  "canonical path is inside" \
  "Skip symlinks entirely" \
  "Never use an imported path string directly as a write target" \
  "Skipped (unsafe path)"; do
  if ! grep -qF "$needle" "$KB_MERGE_MD" 2>/dev/null; then
    d7_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d7_hits" ]]; then
  red "FAIL"; printf ': kb-merge.md lacks external import path hardening:\n'
  printf '%s' "$d7_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': kb-merge import path hardening present\n'
fi

# ---------- D8: imported skill wrappers cannot inject frontmatter -----------
section "D8: kb-merge wrapper frontmatter is sanitized"
d8_hits=""
for needle in \
  "YAML double-quoted strings" \
  "Strip control characters" \
  "Never copy imported frontmatter blocks wholesale"; do
  if ! grep -qF "$needle" "$KB_MERGE_MD" 2>/dev/null; then
    d8_hits+="  missing: $needle"$'\n'
  fi
done
if [[ -n "$d8_hits" ]]; then
  red "FAIL"; printf ': kb-merge.md lacks generated-wrapper frontmatter sanitization:\n'
  printf '%s' "$d8_hits"
  failed=$((failed+1))
else
  green "PASS"; printf ': kb-merge wrapper frontmatter sanitization present\n'
fi

# ---------- Result ---------------------------------------------------------
printf '\n'
if [[ $failed -eq 0 ]]; then
  if [[ $warnings -eq 0 ]]; then
    green "All doctrine gates passed."; printf '\n'
  else
    yellow "Doctrine: 0 failures, $warnings warning category/-ies — review above."; printf '\n'
  fi
  exit 0
fi

red "$failed doctrine gate(s) failed."; printf '\n'
exit "$failed"
