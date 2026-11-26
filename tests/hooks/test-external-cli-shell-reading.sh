#!/usr/bin/env bash
# The CLI guard judges a command as the shell that runs it reads it: Bash or PowerShell.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/workspace/logs"

pass=0
fail=0

report() {
  local ok="$1" label="$2" detail="${3:-}"
  if [ "$ok" -eq 1 ]; then
    printf 'PASS  %-45s %s\n' "$label" "$detail"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-45s %s\n' "$label" "$detail"
    fail=$((fail + 1))
  fi
}

run_hook() {
  local script="$1" input="$2"
  set +e
  OUTPUT=$(printf '%s' "$input" | NASE_ROOT="$TMP_ROOT" bash "$script" 2>&1)
  RC=$?
  set -e
}

expect_rc() {
  local label="$1" script="$2" input="$3" want="$4" pattern="${5:-}"
  run_hook "$script" "$input"
  if [ "$RC" -ne "$want" ]; then
    report 0 "$label" "rc=$RC want=$want output=$OUTPUT"
    return
  fi
  if [ -n "$pattern" ] && [[ "$OUTPUT" != *"$pattern"* ]]; then
    report 0 "$label" "missing pattern: $pattern output=$OUTPUT"
    return
  fi
  report 1 "$label" "rc=$RC"
}

# A Windows jq ends every output line, inside a string value too, with CR.
crjq_dir="$TMP_ROOT/crjq"
mkdir -p "$crjq_dir"
real_jq=$(command -v jq)
cat > "$crjq_dir/jq" <<SH
#!/usr/bin/env bash
"$real_jq" "\$@" | awk '{ printf "%s\r\n", \$0 }'
SH
chmod +x "$crjq_dir/jq"

expect_rc_crlf_jq() {
  local label="$1" script="$2" input="$3" want="$4"
  set +e
  OUTPUT=$(printf '%s' "$input" | PATH="$crjq_dir:$PATH" NASE_ROOT="$TMP_ROOT" bash "$script" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq "$want" ]; then
    report 1 "$label" "rc=$RC"
  else
    report 0 "$label" "rc=$RC want=$want output=$OUTPUT"
  fi
}

# The shell that runs a command can read it differently from the guard's POSIX word
# reader. Each row is `tool`, wanted exit code, and the command as a JSON string body.
shell_rows() {
  local runner="$1" tool want body
  while IFS=$'\t' read -r tool want body; do
    "$runner" "shell reading [$tool] $body" .claude/hooks/external-cli-write-guard.sh \
      "{\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$body\"}}" "$want"
  done
}

# PowerShell ends a quoted argument at its closing quote.
shell_rows expect_rc <<'ROWS'
PowerShell	2	gh api repos/o/r/issues/1 -H 'a:b'-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H \"a:b\"-XDELETE
PowerShell	2	gh api graphql -f query='query{viewer{login}}' -f 'a=b'-fquery=mutation_x
PowerShell	2	gh pr view 1 --json 'title'--web
PowerShell	2	az rest --url 'https://example.invalid/x'--method delete
PowerShell	2	kubectl --context 'prod'delete get pod x
PowerShell	2	terraform '-chdir=x'apply output
PowerShell	2	& 'gh' api repos/o/r/issues/1 -H 'a:b'-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H \u2018a:b\u2019-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H \u201ca:b\u201d-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H 'a:b\u2019 -XDELETE \u2018c:d'
PowerShell	2	gh api repos/o/r/issues/1 -H a,'b'-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q.'-XDELETE'
PowerShell	2	gh api repos/o/r/issues/1 .'a'-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 {}-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 ]-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 ]]-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 >]-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 a> -XDELETE
PowerShell	2	gh api repos/o/r/issues/1 2>&1-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 2>-a:-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 *> -x:-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 --% #x -XDELETE
PowerShell	2	gh pr view 1 `-`-web
PowerShell	2	gh api repos/o/r/issues/1 {;} -XDELETE
PowerShell	2	gh api repos/o/r/issues/1 {\n} -XDELETE
PowerShell	2	gh api repos/o/r/issues/1 \"`-`XDELETE\"
PowerShell	2	gh api repos/o/r/issues/1 @'\n-XDELETE\n'@
PowerShell	2	gh api repos/o/r/issues/1 @\"\n`-XDELETE\n\"@
PowerShell	2	gh pr view 1 \"`u{2d}`u{2d}web\"
PowerShell	2	terraform apply{}
PowerShell	2	kubectl delete{} pod x
ROWS

# PowerShell also splits at spaces and control characters that a POSIX reader keeps.
shell_rows expect_rc <<'ROWS'
PowerShell	2	gh api repos/o/r/issues/1 -H a:b\u00a0-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H a:b\u2028-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H a:b\u0085-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H a:b\f-XDELETE
PowerShell	2	az group show -n x\u00a0--debug\u3000; az group delete -n x
Bash	2	v='a\u000b-XGET'; gh api repos/o/r/issues -f title=x $v
Bash	2	v='a\u00a0-XGET'; gh api repos/o/r/issues -f title=x $v
ROWS

# NUL never reaches the shell as written, and a lone CR ends a PowerShell line.
shell_rows expect_rc <<'ROWS'
Bash	2	gh api repos/o/r/issues/1\u0000-XDELETE
PowerShell	2	gh api repos/o/r/issues/1\u0000-XDELETE
Bash	2	terraform output\u0000-json
PowerShell	2	kubectl get pod\u0000x
PowerShell	2	gh api repos/o/r/issues -f title=x\r-XGET
ROWS

# PowerShell joins a tab or line break after a comma into that argument.
shell_rows expect_rc <<'ROWS'
PowerShell	2	gh api repos/o/r/issues -f x=,\t-XGET
PowerShell	2	gh api repos/o/r/issues -f x=, \t-XGET
PowerShell	2	gh api repos/o/r/issues -f x=GET\t,y
PowerShell	2	gh api repos/o/r/issues -f x=,`\n-XGET `\n -q .n
PowerShell	2	gh api repos/o/r/issues/1 a, #c\nfoo -XDELETE
PowerShell	2	gh api repos/o/r/issues/1 a ,<#c#>\n-b -XDELETE
PowerShell	2	gh api repos/o/r/issues/1 a,\n-b -XDELETE
ROWS

# Text that POSIX reads as data or a comment runs in PowerShell.
shell_rows expect_rc <<'ROWS'
PowerShell	2	echo $((gh pr merge 1))
PowerShell	2	((az group delete -n x))
PowerShell	2	>& gh pr merge 1
PowerShell	2	$^=gh pr merge 1
PowerShell	2	$::a=az group delete -n x
PowerShell	2	Write-Output a<<E\ngh pr merge 1\nE
PowerShell	2	Write-Output x <# ' #> ; terraform apply # '
PowerShell	2	Write-Output \u2018 ' \u2019 ; kubectl delete pod x ; Write-Output \u2018 ' \u2019
PowerShell	2	Write-Output @'\nit's\n'@\ngh pr merge 1\nWrite-Output @'\nit's\n'@
PowerShell	2	Write-Output x\u00a0#'\ngh pr merge 1 #'
ROWS

# PowerShell ends an argument that opens with `$x.y` or `$x[0]` where the expression
# ends, and ends `$x` before `=` or `..`.
shell_rows expect_rc <<'ROWS'
PowerShell	2	gh api repos/o/r/issues/1 $x.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 $x[0]-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 ${x}.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 $x::y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H $env:x.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q:$x.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 a,$x.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 >$x.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 $${x}-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 @${x}-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H >$x..a -XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H >$x. -XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -H >$::..a -XDELETE
PowerShell	2	az group list >$x.y--debug
PowerShell	2	kubectl get pods $x.y--raw
PowerShell	2	terraform output $x[0]-json
PowerShell	0	gh pr view $pr.number --json title
PowerShell	0	gh pr list --author $me[0] --limit 5
PowerShell	0	gh pr list --json number | ForEach-Object { gh pr view $_.number --json title }
PowerShell	0	gh pr diff 1 > $env:TEMP\\d.txt
PowerShell	0	gh pr view 1 -R $repo --json title
PowerShell	0	Write-Output $x.y; gh pr status
ROWS

# PowerShell passes each later item of a `-name:value` list with the `-name:` prefix,
# so a flag written there never arrives and a subcommand can move.
shell_rows expect_rc <<'ROWS'
PowerShell	2	gh api repos/o/r/issues -f title=x -t:y, -XGET
PowerShell	2	gh api repos/o/r/issues -f title=x -t:'y', -XGET
PowerShell	2	gh api repos/o/r/issues -f title=x -t:$y, -XGET
PowerShell	2	gh api repos/o/r/issues -f title=x -t:y,z, -XGET
PowerShell	2	gh api repos/o/r/issues -f title=x -t:y, z, --method=GET
PowerShell	2	gh api repos/o/r/issues -f title=x –t:y, -XGET
PowerShell	2	gh pr -t:x, view merge 1
PowerShell	2	az group -o:x, list delete -n y
PowerShell	2	kubectl -n:x, get delete pod y
PowerShell	2	gh api repos/o/r/issues/1 a,-t:-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:-u:-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t: -u:-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:-t:--method=DELETE
PowerShell	2	kubectl get pods -t:-u:--raw=/x
PowerShell	2	gh api repos/o/r/issues/1 -q${x}-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q$(1)-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q.$x.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q.${x}.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q.$x::y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q.(1)-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -q.@(1)-XDELETE
PowerShell	2	az group list -q.$x[0]--debug
PowerShell	2	gh api repos/o/r/issues/1 -t:.'y'-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t: .'y'-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:-u.'y'-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:.$x.y-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:-u${x}-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:[-u$${x}-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:${x}${x}-XDELETE
PowerShell	2	gh api repos/o/r/issues/1 -t:<#y#> -XDELETE
PowerShell	2	az group list -t:.'y'--debug
PowerShell	0	gh pr view 1 -R:$repo --json title
PowerShell	0	gh pr view 1 -R:${repo} --json title
PowerShell	0	gh pr view 1 -R:'o/r' --json title
PowerShell	0	gh pr view 1 -R:o/r.name --json title
PowerShell	0	kubectl get pods -n:$ns -o name
PowerShell	0	gh api repos/o/r -q.name
PowerShell	0	gh api repos/o/r/pulls -q.[0].title
PowerShell	0	gh pr view 1 -R$repo --json title
PowerShell	0	gh pr view 1 -t:-1
PowerShell	0	gh pr view 1 -R: o/r --json title
PowerShell	0	gh pr view 1 -R:o/r --json title,state
PowerShell	0	gh pr list -L:5 --json number, title
PowerShell	0	gh pr list -L:5 | Select-Object number, title
PowerShell	0	kubectl get pods -n:x -o name
ROWS

# A Windows jq ends each line of a multi-line command with CRLF, which breaks a Bash
# `\` continuation apart unless the guard also reads the exact text.
shell_rows expect_rc_crlf_jq <<'ROWS'
Bash	2	gh api repos/o/r/issues/1 \\\n-XDELETE
Bash	2	gh api repos/o/r/issues/1\\\n -XDELETE
Bash	2	gh api repos/o/r/issues/1 --meth\\\nod DELETE
Bash	0	gh pr view 1 \\\n  --json title
Bash	0	az account show \\\n  --query name -o tsv
ROWS

# A CLI name can be quoted, or cut short by a NUL, with its first argument written
# against it.
shell_rows expect_rc <<'ROWS'
PowerShell	2	& 'gh'api repos/o/r/issues/1 -XDELETE
PowerShell	2	& 'az'group delete -n x
PowerShell	2	& \"kubectl\"delete pod x
PowerShell	2	& 'terraform'apply
PowerShell	2	gh\u0000pr merge 1
Bash	2	gh\u0000pr merge 1
PowerShell	0	Write-Output 'gh'.Length\ngh pr status
ROWS

# A `${name}` may hold quotes and separators, which a POSIX reader would act on.
shell_rows expect_rc <<'ROWS'
PowerShell	2	Write-Output ${a'}; gh pr merge 1; Write-Output ${b'}
PowerShell	2	Write-Output \"${a'}\"; gh pr merge 1; Write-Output \"'}\"
PowerShell	2	Write-Output @\"\n${a'}\n\"@; gh pr merge 1; Write-Output @\"\n${b'}\n\"@
PowerShell	2	Write-Output \"$${a\"; gh pr merge 1; Write-Output \"}\"
PowerShell	2	Write-Output x$${ <# ' #> }; gh pr merge 1; Write-Output y$${ <# ' #> }
PowerShell	0	Write-Output ${env:ProgramFiles(x86)}; gh pr status
PowerShell	0	Write-Output \"${env:ProgramFiles(x86)} $$ ${a b}\"; gh pr status
PowerShell	0	Write-Output @\"\n${repo} $$\n\"@; gh pr status
ROWS

# A here-string header takes any space before its line break. An opener inside a word
# is placed only after a plain assignment or a hashtable key.
shell_rows expect_rc <<'ROWS'
PowerShell	2	Write-Output @'\f\na'b\n'@\ngh pr merge 1 #'
PowerShell	2	Write-Output @' \na'b\n'@\ngh pr merge 1 #'
PowerShell	2	(Get-Variable x).Value =@'\na'b\n'@\ngh pr merge 1 #'
PowerShell	2	Write-Output a=@'\nx'; gh pr status
PowerShell	2	Write-Output $a=@'\nx'; gh pr status
PowerShell	2	& { Write-Output a=@'\nx'; gh pr status }
PowerShell	0	gh pr status | % { $x +=@\"\nit's\n\"@ }
PowerShell	0	gh pr list | ForEach-Object { $env:x=@'\nhello\n'@ }
PowerShell	0	@{x=@'\nhello\n'@}\ngh pr status
PowerShell	0	Write-Output @{a=1; b=@'\nhello\n'@}; gh pr status
PowerShell	0	gh pr list --json number | Select-Object @{ n =@'\nname\n'@;e={$_.number}}
ROWS

# `((` and `=(` stay arithmetic or an array unless the group names a guarded CLI.
shell_rows expect_rc <<'ROWS'
PowerShell	0	gh pr list --json number | ConvertFrom-Json | Select-Object @{n='x';e=($_.number)}
PowerShell	0	gh api \"repos/o/r/pulls?page=$(($page+1))\"
PowerShell	2	Write-Output @{ a=(gh pr merge 1) }
PowerShell	2	$x=((az group delete -n x))
PowerShell	2	Write-Output \"$((gh pr merge 1))\"
ROWS

# Ordinary quoting stays allowed in both shells.
shell_rows expect_rc <<'ROWS'
Bash	0	gh pr view 1 --json title --jq '.title'
PowerShell	0	gh pr view 1 --json title --jq '.title'
Bash	0	gh api repos/o/r -H 'Accept: application/vnd.github+json'
PowerShell	0	gh api repos/o/r -H 'Accept: application/vnd.github+json'
Bash	0	gh api repos/o/r/issues/1 -H 'a:b'-XDELETE
Bash	0	gh pr list --search \"a\u00a0b \u2014 \u201cc\u201d it\u2019s\"
PowerShell	0	gh pr list --search \"a\u00a0b \u2014 c\" --limit 5
PowerShell	0	gh pr list --search 'a\u00a0b \u2014 c'
PowerShell	0	gh pr list --json title -q .[].title
PowerShell	0	gh api repos/o/r -q.name
PowerShell	0	az vm list --query \"[?powerState=='VM running'].{Name:name}\" -o table
PowerShell	0	kubectl get pods -o jsonpath=\"{.items[0].metadata.name}\"
PowerShell	0	terraform show -no-color | Select-String 'x'
PowerShell	0	gh pr view 1 `\n  --json title `\n  -q .title
PowerShell	0	gh pr diff 1 >'my diff.txt'
PowerShell	0	if ((gh pr view 1 --json state -q .state) -eq 'OPEN'){ 'yes' }else{ 'no' }
PowerShell	0	gh pr view 1 2>&1 | Select-String x
PowerShell	0	gh pr list --json number | ForEach-Object { $_.number; 'x' }
PowerShell	0	try { gh pr view 1 } catch { 'no'; 'pr' }
PowerShell	0	gh pr list --search \"a\u2019s b\"
PowerShell	0	(gh pr view 1 --json title | ConvertFrom-Json).title
PowerShell	0	gh pr view 1 | Where-Object { $_ -match 'a(b)c' }
PowerShell	0	# it's a note\ngh pr status
PowerShell	0	<#\n a note\n#>\nGet-Date; gh pr status
PowerShell	0	@'\nuse `gh pr view` here\n'@ | Set-Content b.md
PowerShell	0	Write-Host 'a'.Length\ngh pr status
PowerShell	0	Write-Output 'x'-y; Get-Date
PowerShell	0	gh pr list --json number,title,state
PowerShell	0	Write-Output 'a',\n  'b'\ngh pr status
ROWS

# A hook that outlives its time limit does not block, so a long command with many
# escapes must still be read quickly.
long_command=$(python3 -c 'print("gh pr status; echo " + "a\u0060a" * 20000)')
started=$SECONDS
expect_rc "shell reading [PowerShell] long command stays quick" \
  .claude/hooks/external-cli-write-guard.sh \
  "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"$long_command\"}}" 0
took=$((SECONDS - started))
report "$((took < 15 ? 1 : 0))" "shell reading long command time" "${took}s, limit 15s"

printf '
--- %d pass, %d fail ---
' "$pass" "$fail"
[ "$fail" -eq 0 ]
