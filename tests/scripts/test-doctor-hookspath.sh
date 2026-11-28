#!/usr/bin/env bash
# Runs the `/nase:doctor` core.hooksPath step, and the tracked pre-push hook it points at,
# in throwaway repos. A stub stands in for gitleaks; the cases that need the real binary
# run only when it is on PATH.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0
source "$ROOT/tests/lib/assert.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/doctor-hookspath.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

enable_command='git config core.hooksPath .githooks'

# --- the doctor step ---

step="$TMPROOT/doctor-step.sh"
awk '
  /^[[:space:]]*```bash/ { inside = 1; block = ""; next }
  inside && /^[[:space:]]*```/ { if (block ~ /core\.hooksPath/) printf "%s", block; inside = 0; next }
  inside { block = block $0 "\n" }
' .claude/commands/nase/doctor.md > "$step"
assert_cmd "doctor.md carries a core.hooksPath bash step" test -s "$step"

repo="$TMPROOT/repo"
git init -q "$repo"
run_step() { (cd "$repo" && bash "$step") > "$TMPROOT/step.out" 2>&1; }

assert_cmd "step exits 0 when core.hooksPath is unset" run_step
assert_contains "unset hooksPath is a warning" "$TMPROOT/step.out" 'warning:'
assert_contains "unset hooksPath prints the command" "$TMPROOT/step.out" "$enable_command"
assert_cmd "step leaves core.hooksPath unset" \
  bash -c '! git -C "$1" config --get core.hooksPath' _ "$repo"

git -C "$repo" config core.hooksPath other-hooks
assert_cmd "step exits 0 when core.hooksPath points elsewhere" run_step
assert_contains "other hooksPath is named" "$TMPROOT/step.out" "'other-hooks'"
assert_contains "other hooksPath prints the command" "$TMPROOT/step.out" "$enable_command"

git -C "$repo" config core.hooksPath .githooks
assert_cmd "step exits 0 when core.hooksPath is .githooks" run_step
assert_contains "configured hooksPath passes" "$TMPROOT/step.out" 'pass:'
assert_cmd "configured hooksPath prints no command" \
  bash -c '! grep -qF -- "$1" "$2"' _ "$enable_command" "$TMPROOT/step.out"

# The step names the blocked `git config` write, so prove the guard still lets it run.
assert_cmd "block-dangerous-git allows the doctor step" bash -c '
  jq -cn --rawfile cmd "$1" "{tool_name:\"Bash\",tool_input:{command:\$cmd}}" \
    | bash .claude/hooks/block-dangerous-git.sh
' _ "$step"

# --- the pre-push hook ---

hook=".githooks/pre-push"
assert_cmd "pre-push hook is tracked as executable" \
  bash -c 'git ls-files -s -- "$1" | grep -q "^100755 "' _ "$hook"

mkdir "$TMPROOT/empty-path" "$TMPROOT/stub"
assert_cmd "missing gitleaks does not block the push" \
  bash -c 'PATH="$1" "$2" "$3" > "$4" 2>&1' _ "$TMPROOT/empty-path" "$BASH" "$hook" "$TMPROOT/hook.out"
assert_contains "missing gitleaks prints a warning" "$TMPROOT/hook.out" \
  'warning: gitleaks is not installed'

cat > "$TMPROOT/stub/gitleaks" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGS"
exit "$STUB_RC"
SH
chmod +x "$TMPROOT/stub/gitleaks"
export STUB_ARGS="$TMPROOT/stub.args"

# A real push through git, so the file mode and the hooksPath wiring are covered too.
git init -q --bare "$TMPROOT/remote.git"
mkdir "$repo/.githooks"
cp -p "$hook" "$repo/.githooks/pre-push"
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
push() { PATH="$TMPROOT/stub:$PATH" STUB_RC="$1" git -C "$repo" push -q "$TMPROOT/remote.git" "HEAD:refs/heads/$2" > "$TMPROOT/push.out" 2>&1; }

assert_cmd "a clean scan lets the push through" push 0 clean
assert_contains "hook scans the tree with the tracked config, redacted" "$STUB_ARGS" \
  'detect --no-git --redact --no-banner --config .gitleaks.toml'
stub_blocked() { ! push 1 leak; }
assert_cmd "a finding blocks the push" stub_blocked
assert_contains "the hook is what blocked it" "$TMPROOT/push.out" '[pre-push] push blocked'
assert_cmd "a blocked push creates no remote branch" \
  bash -c '! git -C "$1" rev-parse -q --verify refs/heads/leak' _ "$TMPROOT/remote.git"

# --- the same push with a real gitleaks, when one is on PATH ---

if command -v gitleaks >/dev/null 2>&1; then
  cp .gitleaks.toml "$repo/"
  # Assembled at run time, so no token-shaped literal is tracked.
  token_body=$(printf 'doctor-hookspath' | git hash-object --stdin | cut -c1-36)
  printf 'value = "%s%s"\n' 'gh''p_' "$token_body" > "$repo/leak.txt"
  real_push() { git -C "$repo" push -q "$TMPROOT/remote.git" "HEAD:refs/heads/$1" > "$TMPROOT/push.out" 2>&1; }
  real_blocked() { ! real_push real-leak; }
  verbose_scan_finds() {
    ! (cd "$repo" && gitleaks detect --no-git --redact --verbose --config .gitleaks.toml) \
      > "$TMPROOT/verbose.out" 2>&1
  }
  assert_cmd "real gitleaks blocks a push with a token in the tree" real_blocked
  assert_contains "real gitleaks reports the finding" "$TMPROOT/push.out" 'leaks found: 1'
  assert_cmd "the hinted verbose scan finds it too" verbose_scan_finds
  assert_contains "verbose scan names the file" "$TMPROOT/verbose.out" 'leak.txt'
  assert_cmd "neither output contains the token" \
    bash -c '! grep -qF -- "$1" "$2" "$3"' _ "$token_body" "$TMPROOT/push.out" "$TMPROOT/verbose.out"
  rm "$repo/leak.txt"
  assert_cmd "real gitleaks passes the tree once the token is gone" real_push real-clean
else
  printf 'SKIP: gitleaks is not on PATH, so the real-binary push cases did not run.\n'
  # The Linux CI job installs gitleaks. A skip there is a broken install, not a missing
  # tool. The Windows job has no gitleaks, so it may skip.
  [ "${RUNNER_OS:-}" != "Linux" ] || fail "real gitleaks push cases run on the Linux CI runner"
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\ndoctor-hookspath tests passed.\n'
  exit 0
fi

printf '\n%d doctor-hookspath assertion(s) failed.\n' "$failures" >&2
exit 1
