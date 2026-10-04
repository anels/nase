#!/usr/bin/env bash
set -u

ROOT=$(git rev-parse --show-toplevel)
HELPER="$ROOT/.claude/scripts/tmp-prune.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nase-tmp-prune.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

failures=0
source "$ROOT/tests/lib/assert.sh"

# age <days-ago> <path>...: set mtime N days in the past.
age() {
  local stamp
  stamp=$(python3 -c "import time,sys; print(time.strftime('%Y%m%d%H%M', time.localtime(time.time()-float(sys.argv[1])*86400)))" "$1")
  shift
  touch -t "$stamp" "$@"
}

json_is() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)" "$1" "$2"; }

R="$TMP/root"
T="$R/workspace/tmp"
mkdir -p "$T/olddir/sub" "$T/mixeddir" "$T/keep" "$T/external-actions" "$T/.content-hashes" "$R/workspace/logs" "$R/workspace/kb" "$R/.claude"
for f in old.md referenced-kb.md referenced-log.md stale-log-ref.md recent.md olddir/sub/a.json \
  mixeddir/old.txt mixeddir/new.txt keep/helper.py external-actions/audit.json .content-hashes/h \
  tmp-prune-2099-01-01.tsv move-recovery-abc.md move-rollback-abc.md fsd-phases-b.md fsd-research-b.md \
  fsd-qa-b-state.json fsd-qa-b-r1.md fsd-secret-allowlist-b.txt; do
  printf x >"$T/$f"
done
age 10 "$T"/{.content-hashes/h,.content-hashes,tmp-prune-2099-01-01.tsv,move-recovery-abc.md,move-rollback-abc.md,fsd-phases-b.md,fsd-research-b.md,fsd-qa-b-state.json,fsd-qa-b-r1.md,fsd-secret-allowlist-b.txt} \
  "$T"/{old.md,referenced-kb.md,referenced-log.md,stale-log-ref.md,olddir/sub/a.json,olddir/sub,olddir} \
  "$T"/{mixeddir/old.txt,mixeddir,keep/helper.py,keep,external-actions/audit.json,external-actions}
age 1 "$T/recent.md" "$T/mixeddir/new.txt"
printf 'see workspace/tmp/referenced-kb.md.\n' >"$R/workspace/kb/note.md"
printf x >"$T/report (1).pdf"
age 10 "$T/report (1).pdf"
printf 'saved to workspace/tmp/report (1).pdf here\n' >"$R/workspace/kb/spaced.md"
mkdir -p "$R/workspace/skills"
printf x >"$T/referenced-ledger.md"
printf x >"$T/referenced-skill.md"
age 10 "$T/referenced-ledger.md" "$T/referenced-skill.md"
printf '{"source_path": "workspace/tmp/referenced-ledger.md"}\n' >"$R/workspace/confluence-publications.jsonl"
printf 'reads workspace/tmp/referenced-skill.md\n' >"$R/workspace/skills/s.md"
printf -- '- 10:00 | draft at workspace/tmp/stale-log-ref.md\n' >"$R/workspace/logs/2099-01-01.md"
printf -- '- 10:00 | draft at workspace/tmp/referenced-log.md\n' >"$R/workspace/logs/2099-01-02.md"
printf -- '- 10:00 | nothing\n' >"$R/workspace/logs/2099-01-03-sre-tracker.md"

python3 "$HELPER" --root "$R" --log-days 1 --json >"$TMP/dry.json"
assert_cmd "dry-run deletes nothing" test -f "$T/old.md"
assert_cmd "dry-run counts the unreferenced old entries" \
  json_is "$TMP/dry.json" "d['targets']==4 and d['removed']==0 and d['kept']=={'never':10,'referenced':5,'recent':2} and sorted(d['target_paths'])==['workspace/tmp/fsd-qa-b-r1.md','workspace/tmp/old.md','workspace/tmp/olddir','workspace/tmp/stale-log-ref.md']"

python3 "$HELPER" --root "$R" --log-days 1 --apply --manifest "$TMP/manifest.tsv" --json >"$TMP/apply.json"
assert_cmd "old file removed" test ! -e "$T/old.md"
assert_cmd "old directory removed" test ! -e "$T/olddir"
assert_cmd "kb reference protects entry" test -f "$T/referenced-kb.md"
assert_cmd "reference to a name with spaces protects entry" test -f "$T/report (1).pdf"
assert_cmd "recent log reference protects entry" test -f "$T/referenced-log.md"
assert_cmd "reference outside the log window does not protect" test ! -e "$T/stale-log-ref.md"
assert_cmd "recent file kept" test -f "$T/recent.md"
assert_cmd "directory with a recent child kept" test -f "$T/mixeddir/old.txt"
assert_cmd "keep/ never deleted" test -f "$T/keep/helper.py"
assert_cmd "external-actions/ never deleted" test -f "$T/external-actions/audit.json"
assert_cmd ".content-hashes never deleted" test -f "$T/.content-hashes/h"
assert_cmd "earlier prune manifest never deleted" test -f "$T/tmp-prune-2099-01-01.tsv"
assert_cmd "move-recovery file never deleted" test -f "$T/move-recovery-abc.md"
assert_cmd "move-rollback file never deleted" test -f "$T/move-rollback-abc.md"
assert_cmd "fsd phase/research/QA state never deleted" test -f "$T/fsd-phases-b.md" -a -f "$T/fsd-research-b.md" -a -f "$T/fsd-qa-b-state.json" -a -f "$T/fsd-secret-allowlist-b.txt"
assert_cmd "fsd QA round output is prunable" test ! -e "$T/fsd-qa-b-r1.md"
assert_cmd "publication ledger reference protects entry" test -f "$T/referenced-ledger.md"
assert_cmd "workspace skill reference protects entry" test -f "$T/referenced-skill.md"
assert_cmd "apply reports every target removed" json_is "$TMP/apply.json" "d['removed']==4 and not d['failed']"
assert_cmd "manifest lists exactly the deleted entries" \
  bash -c "[[ \$(cut -f1 '$TMP/manifest.tsv' | sort | tr '\n' ' ') == 'workspace/tmp/fsd-qa-b-r1.md workspace/tmp/old.md workspace/tmp/olddir workspace/tmp/stale-log-ref.md ' ]]"

printf x >"$T/second.md"
age 10 "$T/second.md"
python3 "$HELPER" --root "$R" --apply --manifest "$TMP/manifest.tsv" >/dev/null
assert_cmd "second run appends to the manifest" \
  bash -c "[[ \$(wc -l <'$TMP/manifest.tsv') -eq 5 ]] && grep -q 'workspace/tmp/old.md' '$TMP/manifest.tsv' && tail -1 '$TMP/manifest.tsv' | grep -q second.md"

printf x >"$T/old2.md"
age 10 "$T/old2.md"
printf 'x\n' >"$R/workspace/kb/unreadable.md"
chmod 000 "$R/workspace/kb/unreadable.md"
python3 "$HELPER" --root "$R" --apply >/dev/null 2>&1
rc=$?
chmod 644 "$R/workspace/kb/unreadable.md"
if [[ $(id -u) -ne 0 ]]; then
  assert_cmd "unreadable reference source exits 2" test "$rc" -eq 2
  assert_cmd "unreadable reference source deletes nothing" test -f "$T/old2.md"
fi

mkdir -p "$T/stuck"
printf x >"$T/stuck/f"
age 10 "$T/stuck/f" "$T/stuck"
chmod 555 "$T/stuck"
python3 "$HELPER" --root "$R" --apply --manifest "$TMP/fail.tsv" --json >"$TMP/fail.json"
rc=$?
chmod 755 "$T/stuck"
if [[ $(id -u) -ne 0 ]]; then
  assert_cmd "partial delete failure still exits 0" test "$rc" -eq 0
  assert_cmd "failed entry reported and excluded from bytes" json_is "$TMP/fail.json" "len(d['failed'])==1 and d['failed'][0].startswith('stuck:') and d['targets']==2 and d['removed']==1 and d['bytes']==1"
  assert_cmd "failed entry still in manifest" grep -q 'workspace/tmp/stuck' "$TMP/fail.tsv"
fi

printf x >"$T/old3.md"
age 10 "$T/old3.md"
python3 "$HELPER" --root "$R" --apply --manifest "$TMP/no-such-dir/m.tsv" >/dev/null 2>&1
rc=$?
assert_cmd "unwritable manifest exits 2" test "$rc" -eq 2
assert_cmd "unwritable manifest deletes nothing" test -f "$T/old3.md"
(cd "$TMP" && python3 "$HELPER" --root "$R" --manifest rel.tsv >/dev/null)
assert_cmd "relative manifest resolves against --root" test -f "$R/rel.tsv" -a ! -e "$TMP/rel.tsv"

python3 "$HELPER" --root "$TMP/missing" >/dev/null 2>&1
assert_cmd "missing workspace/tmp exits 2" test $? -eq 2
python3 "$HELPER" --root "$R" --days 0 >/dev/null 2>&1
assert_cmd "non-positive --days exits 2" test $? -eq 2
python3 "$HELPER" --root "$R" --days nan >/dev/null 2>&1
assert_cmd "nan --days exits 2" test $? -eq 2

printf '\n%d failed\n' "$failures"
[[ $failures -eq 0 ]]
