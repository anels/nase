#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

failures=0
source "$ROOT/tests/lib/assert.sh"

workflow=".github/workflows/validate.yml"

unpinned_remote_uses=$(awk '
  /uses:[[:space:]]*/ {
    line = $0
    sub(/#.*/, "", line)
    sub(/.*uses:[[:space:]]*/, "", line)
    gsub(/["'\''"]/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line ~ /^\.\/|^docker:\/\//) {
      next
    }
    if (line !~ /@[0-9a-f]{40}$/) {
      print line
    }
  }
' "$workflow")

if [ -z "$unpinned_remote_uses" ]; then
  pass "remote GitHub Actions are pinned to full SHAs"
else
  fail "remote GitHub Actions are pinned to full SHAs"
  printf '%s\n' "$unpinned_remote_uses" >&2
fi

assert_cmd "CI installs actionlint" grep -q 'rhysd/actionlint/releases/download' "$workflow"
assert_cmd "CI verifies the actionlint checksum" grep -q 'actionlint_${ACTIONLINT_VERSION}_checksums.txt' "$workflow"
assert_cmd "local gate runs actionlint" grep -q 'GitHub Actions lint' tests/check-all.sh

assert_cmd "CI scans the tree with gitleaks" \
  grep -qF 'detect --no-git --redact --no-banner --config .gitleaks.toml' "$workflow"
assert_cmd "CI pins the gitleaks checksum" grep -qE 'GITLEAKS_SHA256: [0-9a-f]{64}$' "$workflow"

# Prints every workflow step that downloads more files with curl or wget than it verifies
# with `sha256sum -c`. A command that fetches a checksum list is not counted as a download.
unverified_downloads() {
  awk '
    function flush() {
      if (downloads > checks) {
        printf "%s: %s: %d download(s), %d sha256sum -c\n", file, step, downloads, checks
      }
      downloads = 0
      checks = 0
      pending = ""
    }
    FNR == 1 { flush(); file = FILENAME }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]+(name|uses|run|id|if|env|shell|with|working-directory):/ {
      flush()
      step = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", step)
    }
    { line = pending $0; pending = "" }
    /\\$/ { sub(/\\$/, "", line); pending = line; next }
    line ~ /(^|[^[:alnum:]_-])(curl|wget)[[:space:]].*(:\/\/|\$)/ &&
      line !~ /(checksums\.txt|\.sha256)["\047]?[[:space:]]*$/ { downloads++ }
    line ~ /sha256sum[[:space:]]+(-c|--check)([[:space:]]|$)/ { checks++ }
    END { flush() }
  ' "$@"
}

shopt -s nullglob
workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

unverified=$(unverified_downloads "${workflow_files[@]}")
if [ -z "$unverified" ]; then
  pass "every downloaded binary is verified with sha256sum -c"
else
  fail "every downloaded binary is verified with sha256sum -c"
  printf '%s\n' "$unverified" >&2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/actions-hardening.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# flags <name> <workflow file> <expected report line, without the file prefix>...
# Compares the whole report, so a case cannot pass by flagging the wrong step or count.
flags() {
  local name="$1" file="$2" found expected
  shift 2
  found=$(unverified_downloads "$file")
  found=${found//"$file: "/}
  expected=$(printf '%s\n' "$@")
  assert_cmd "$name" test "$found" = "$expected"
  [[ "$found" == "$expected" ]] || printf 'report was:\n%s\n' "$found" >&2
}

grep -v 'sha256sum -c' "$workflow" > "$tmp/no-verify.yml"
flags "a downloaded binary without a sha256sum -c fails" "$tmp/no-verify.yml" \
  'name: Credential scan: 1 download(s), 0 sha256sum -c' \
  'name: Install tools: 1 download(s), 0 sha256sum -c'

# A verification in another step must not cover the gitleaks download.
grep -v 'GITLEAKS_SHA256}.*sha256sum -c' "$workflow" > "$tmp/no-gitleaks-verify.yml"
flags "each step verifies its own download" "$tmp/no-gitleaks-verify.yml" \
  'name: Credential scan: 1 download(s), 0 sha256sum -c'

cat > "$tmp/second-download.yml" <<'YAML'
    steps:
      - name: Two binaries, one check
        run: |
          curl -fsSL -o a.tar.gz https://example.invalid/a.tar.gz
          echo "$A_SHA256  a.tar.gz" | sha256sum -c -
          wget -O b.tar.gz \
            "https://example.invalid/b.tar.gz"
YAML
flags "a second download needs its own sha256sum -c" "$tmp/second-download.yml" \
  'name: Two binaries, one check: 2 download(s), 1 sha256sum -c'

cat > "$tmp/piped.yml" <<'YAML'
    steps:
      - run: curl -fsSL "$URL" | tar -xz
      - name: A commented-out check does not count
        run: |
          curl -fsSL -o c https://example.invalid/c
          # sha256sum -c c.sha256
YAML
flags "a piped download or a commented-out check fails" "$tmp/piped.yml" \
  'run: curl -fsSL "$URL" | tar -xz: 1 download(s), 0 sha256sum -c' \
  'name: A commented-out check does not count: 1 download(s), 0 sha256sum -c'

if [[ "$failures" -eq 0 ]]; then
  printf '\ngithub-actions-hardening tests passed.\n'
  exit 0
fi

printf '\n%d github-actions-hardening assertion(s) failed.\n' "$failures" >&2
exit 1
