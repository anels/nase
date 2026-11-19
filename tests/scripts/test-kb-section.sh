#!/usr/bin/env bash
# Regression tests for .claude/scripts/kb-section.py.

set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$ROOT/.claude/scripts/kb-section.py"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

pass=0
fail=0

check() {
  local desc="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n  %s\n' "$desc" "$detail" >&2
  fi
}

KB="$FIXTURE/kb.md"
cat > "$KB" <<'EOF'
# Title

## Alpha
alpha body
```
## not a heading inside fence
```

### Alpha child
child body

## Beta
beta body

## Gamma Beta
gamma body
EOF

out=$(python3 "$SCRIPT" outline "$KB")
case "$out" in *"## Alpha"*"### Alpha child"*"## Beta"*) check "outline lists headings" 1 ;; *) check "outline lists headings" 0 "$out" ;; esac
case "$out" in *"not a heading"*) check "outline skips fenced headings" 0 "$out" ;; *) check "outline skips fenced headings" 1 ;; esac

out=$(python3 "$SCRIPT" outline "$KB" --depth 2)
case "$out" in *"Alpha child"*) check "outline --depth 2 drops level 3" 0 "$out" ;; *) check "outline --depth 2 drops level 3" 1 ;; esac

out=$(python3 "$SCRIPT" get "$KB" "Alpha")
case "$out" in *"alpha body"*"child body"*) check "get includes nested children" 1 ;; *) check "get includes nested children" 0 "$out" ;; esac
case "$out" in *"beta body"*) check "get stops at the next peer heading" 0 "$out" ;; *) check "get stops at the next peer heading" 1 ;; esac

out=$(python3 "$SCRIPT" get "$KB" "Beta" 2>&1)
rc=$?
check "exact title wins over a substring match" "$([ "$rc" = 0 ] && grep -q 'beta body' <<< "$out" && ! grep -q 'gamma body' <<< "$out" && echo 1 || echo 0)" "$out"

python3 "$SCRIPT" get "$KB" "Missing" >/dev/null 2>&1
check "missing heading exits 2" "$([ $? = 2 ] && echo 1 || echo 0)"

python3 "$SCRIPT" get "$KB" "eta" >/dev/null 2>&1
check "ambiguous substring exits 3" "$([ $? = 3 ] && echo 1 || echo 0)"

printf '## Beta\nnew beta body\n' > "$FIXTURE/new.md"
python3 "$SCRIPT" replace "$KB" "Beta" --content-file "$FIXTURE/new.md" --out "$FIXTURE/out.md"
check "replace writes the proposed file" "$(grep -q 'new beta body' "$FIXTURE/out.md" && ! grep -q '^beta body' "$FIXTURE/out.md" && grep -q 'gamma body' "$FIXTURE/out.md" && echo 1 || echo 0)"
check "replace leaves the source untouched" "$(grep -q '^beta body' "$KB" && echo 1 || echo 0)"

printf 'appended line\n' > "$FIXTURE/add.md"
python3 "$SCRIPT" append-under "$KB" "Alpha" --content-file "$FIXTURE/add.md" --out "$FIXTURE/out2.md"
check "append-under lands after the section end" "$(awk '/child body/{c=NR} /appended line/{a=NR} /^## Beta/{b=NR} END{print (c<a && a<b)?1:0}' "$FIXTURE/out2.md")"

total=$((pass + fail))
printf '\n%d/%d assertions passed\n' "$pass" "$total"
[ "$fail" -eq 0 ]
