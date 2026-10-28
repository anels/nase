#!/usr/bin/env bash
# Unit tests for .claude/scripts/shell_scan.py, the parser shared by the external-CLI
# guard and the git guard. Each case runs the scanner's --json output through a jq
# predicate, so a failure names the construct rather than a downstream hook verdict.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCAN="$ROOT/.claude/scripts/shell_scan.py"

pass=0
fail=0

report() {
  local ok="$1" label="$2" detail="${3:-}"
  if [ "$ok" -eq 1 ]; then
    printf 'PASS  %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s%s\n' "$label" "${detail:+: $detail}" >&2
    fail=$((fail + 1))
  fi
}

# check <label> <command> <jq predicate over the scan result>
check() {
  local label="$1" command="$2" predicate="$3" out
  if ! out=$(python3 "$SCAN" --json --command "$command" 2>&1); then
    report 0 "$label" "scanner crashed: $out"
    return
  fi
  if jq -e "$predicate" <<<"$out" >/dev/null 2>&1; then
    report 1 "$label"
  else
    report 0 "$label" "predicate $predicate not met by $out"
  fi
}

# has <label> <command> <argv as JSON>: some invocation has exactly this argv
has() {
  local label="$1" command="$2" argv="$3"
  check "$label" "$command" ".invocations | any(.argv == $argv)"
}

# lacks <label> <command> <program>: no invocation runs that program
lacks() {
  local label="$1" command="$2" program="$3"
  check "$label" "$command" ".invocations | all(.argv[0] != \"$program\")"
}

MERGE='["gh","pr","merge","1"]'

# --- plain and compound commands ------------------------------------------------------
has "plain command" 'gh pr merge 1' "$MERGE"
has "quotes are resolved" "'gh' \"pr\" merge 1" "$MERGE"
has "backslash-escaped head" '\gh pr merge 1' "$MERGE"
has "separator semicolon" 'echo a; gh pr merge 1' "$MERGE"
has "separator and" 'true && gh pr merge 1' "$MERGE"
has "separator or" 'false || gh pr merge 1' "$MERGE"
has "separator pipe" 'echo a | gh pr merge 1' "$MERGE"
has "separator pipe-and" 'echo a |& gh pr merge 1' "$MERGE"
has "separator background" 'sleep 1 & gh pr merge 1' "$MERGE"
has "separator newline" $'echo a\ngh pr merge 1' "$MERGE"
has "for loop body" 'for i in 1; do gh pr merge $i; done' '["gh","pr","merge","$i"]'
has "while loop body" 'while true; do gh pr merge 1; done' "$MERGE"
has "until loop body" 'until false; do gh pr merge 1; done' "$MERGE"
has "if body" 'if true; then gh pr merge 1; fi' "$MERGE"
has "if condition" 'if gh pr merge 1; then echo ok; fi' "$MERGE"
has "elif and else body" 'if false; then :; elif false; then :; else gh pr merge 1; fi' "$MERGE"
has "brace group" '{ gh pr merge 1; }' "$MERGE"
has "subshell" '(gh pr merge 1)' "$MERGE"
has "negation" '! gh pr merge 1' "$MERGE"
has "case clause" 'case x in a) gh pr merge 1;; esac' "$MERGE"
has "case with alternation and parens" 'case x in (a|b) gh pr merge 1;; *) :;; esac' "$MERGE"
has "function definition body" 'f() { gh pr merge 1; }; f' "$MERGE"
has "function keyword body" 'function f { gh pr merge 1; }; f' "$MERGE"
has "after conditional expression" '[[ -n $x && -z $y ]] && gh pr merge 1' "$MERGE"
has "after arithmetic command" '(( i < 3 )) && gh pr merge 1' "$MERGE"
has "time keyword" 'time gh pr merge 1' "$MERGE"
has "time keyword before a subshell" 'time (gh pr merge 1)' "$MERGE"
has "line continuation" $'gh pr \\\nmerge 1' "$MERGE"
has "comment is skipped" $'# gh pr merge 2\ngh pr merge 1' "$MERGE"
check "comment text is not a command" '# gh pr merge 1' '.invocations | length == 0'

# --- wrappers -------------------------------------------------------------------------
for wrapper in 'nohup' 'exec' 'nice' 'nice -n 5' 'timeout 5' 'timeout -s KILL 5' \
  'timeout --kill-after=1 5' 'xargs' 'xargs -n 1' 'xargs -I {}' 'stdbuf -o0' 'setsid' 'command' \
  'command -p' 'builtin' 'env' 'env -i' 'env -u FOO' 'env -u FOO -u BAR' 'env FOO=1' \
  'sudo' 'sudo -u me' 'sudo -E -u me -g grp' 'sudo -- ' 'doas -u me' 'ionice -c 2 -n 4' \
  'arch -arm64' 'caffeinate -i' 'unbuffer' 'flock /tmp/lock' 'sudo env FOO=1 timeout 5 nohup' \
  '/usr/bin/env' '/usr/bin/time -p'; do
  check "wrapper: $wrapper" "$wrapper gh pr merge 1" \
    '.invocations | any(.argv[0:4] == ["gh","pr","merge","1"] and .wrappers != [])'
done
for wrapper in 'rtk' 'rtk proxy' 'rtk bypass' 'rtk err' 'rtk test' 'rtk summary' 'direnv exec .' \
  'mise exec --' 'mise exec node@20 --' 'mise x --' 'uv run' 'uv run --with requests' 'uv run --index-strategy first-index' 'uv run -P pkg' 'pnpm exec' \
  'pnpm -C app exec' 'pnpm dlx' 'op run --' 'op run --env-file=a.env --' 'taskset 1' \
  'taskset -c 0,1' 'chrt 10' 'chrt -r 10' 'runuser -u bob --' 'chroot /srv' 'systemd-run' \
  'systemd-run --unit job -p Nice=1'; do
  check "runner wrapper: $wrapper" "$wrapper gh pr merge 1" \
    '.invocations | any(.argv[0:4] == ["gh","pr","merge","1"] and .wrappers != [])'
done
for runner in 'rtk git status' 'uv run pytest' 'mise exec -- node x.js' 'direnv allow' 'pnpm install'; do
  check "runner is not a mutation: $runner" "$runner" \
    '.invocations | all(.argv[0:4] != ["gh","pr","merge","1"])'
done
check "rtk forwards git directly" 'rtk git status' \
  '.invocations | any(.argv == ["git","status"] and .wrappers == ["rtk"])'
check "non-wrapping direnv stays the program" 'direnv allow' \
  '.invocations | any(.argv == ["direnv","allow"] and .wrappers == [])'
check "mise exec -c script is scanned" "mise exec -c 'gh pr merge 1'" \
  '.invocations | any(.argv[0:4] == ["gh","pr","merge","1"])'
check "runuser -c script is scanned" "runuser bob -c 'gh pr merge 1'" \
  '.invocations | any(.argv[0:4] == ["gh","pr","merge","1"])'
for shell in fish csh tcsh rbash; do
  check "shell -c: $shell" "$shell -c 'gh pr merge 1'" \
    '.invocations | any(.argv[0:4] == ["gh","pr","merge","1"])'
done
check "fish --command= script is scanned" "fish --command='gh pr merge 1'" \
  '.invocations | any(.argv[0:4] == ["gh","pr","merge","1"])'
check "wrapper names are reported" 'timeout 5 nohup gh pr merge 1' \
  '.invocations | any(.argv[0] == "gh" and .wrappers == ["timeout","nohup"])'
check "xargs adds a dynamic trailing word" 'xargs gh pr merge 1' \
  '.invocations | any(.argv[0] == "gh" and .argv[-1] == "<xargs-input>" and .dyn[-1] == true)'
check "command -v is a lookup, not an exec" 'command -v gh' \
  '.invocations | all(.argv[0] != "gh")'
has "env -S string is a command line" "env -S 'gh pr merge 1'" "$MERGE"
has "sudo -s string is a command line" "sudo -s 'gh pr merge 1'" "$MERGE"
has "find -exec runs the program" 'find . -exec gh pr merge 1 \;' "$MERGE"
has "find -execdir with plus terminator" 'find . -execdir gh pr merge 1 {} +' '["gh","pr","merge","1","{}"]'
has "watch runs its arguments" 'watch -n 5 gh pr merge 1' "$MERGE"
has "trap command string" "trap 'gh pr merge 1' EXIT" "$MERGE"
has "su -c command string" "su -c 'gh pr merge 1' root" "$MERGE"

# --- function calls -------------------------------------------------------------------
check "a call to a function defined in the same command is flagged" 'g() { git "$@"; }; g status' \
  '.invocations | any(.argv == ["g","status"] and .function_call == true)'
has "a function call's arguments are also read as a command" 'r() { "$@"; }; r gh pr merge 1' "$MERGE"
check "a function call may be the program the body forwards to" 'g() { git "$@"; }; g push x' \
  '.invocations | any(.argv[0] == "g" and .function_call == true)'
check "a name that is not a defined function is not flagged" 'g status' \
  '.invocations | all(.function_call == false)'

# --- environment and variables --------------------------------------------------------
check "prefix assignment is exposed as env" 'GIT_DIR=../x git status' \
  '.invocations | any(.argv[0] == "git" and .env.GIT_DIR == "../x")'
check "env wrapper assignment is exposed as env" 'env GIT_DIR=../x git status' \
  '.invocations | any(.argv[0] == "git" and .env.GIT_DIR == "../x")'
check "exported assignment persists to later commands" 'export GIT_DIR=../x; git status' \
  '.invocations | any(.argv[0] == "git" and .env.GIT_DIR == "../x")'
check "env -C changes the working directory" 'env -C ../x git status' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["../x"])'
has "literal variable resolves as the program" 'G=gh; $G pr merge 1' "$MERGE"
has "braced variable resolves" 'G=gh; ${G} pr merge 1' "$MERGE"
has "variable holding words splits" 'G="gh pr"; $G merge 1' "$MERGE"
has "empty variable vanishes" 'E=""; $E gh pr merge 1' "$MERGE"
has "variable inside double quotes resolves" 'N=1; gh pr merge "$N"' "$MERGE"
check "unknown variable is dynamic" 'gh pr merge $N' \
  '.invocations | any(.argv == ["gh","pr","merge","$N"] and .dyn == [false,false,false,true])'
check "dynamic program is reported" '$X pr merge 1' \
  '.invocations | any(.head_dynamic == true)'
check "assignment from a substitution is unknown" 'X=$(echo gh); $X pr merge 1' \
  '.invocations | any(.argv[0] == "$X" and .head_dynamic == true)'
check "read marks the variable unknown" 'G=gh; read G; $G pr merge 1' \
  '.invocations | any(.argv[0] == "$G" and .head_dynamic == true)'
check "for loop variable is unknown" 'for c in gh; do $c pr merge 1; done' \
  '.invocations | any(.argv[0] == "$c" and .head_dynamic == true)'
check "brace expansion is dynamic" 'echo {a,b}' \
  '.invocations | any(.argv == ["echo","{a,b}"] and .dyn == [false,true])'
check "brace range is dynamic" 'echo {1..3}' '.invocations | any(.dyn == [false,true])'
check "a lone brace is not a brace expansion" 'echo {}' '.invocations | any(.dyn == [false,false])'
check "quoted braces are literal" "echo '{a,b}'" '.invocations | any(.dyn == [false,false])'
check "glob words are flagged" 'echo *.md' '.invocations | any(.glob == [false,true])'
check "quoted glob is not flagged" "echo '*.md'" '.invocations | any(.glob == [false,false])'
check "a lone bracket is not a glob" '[ -f x ] && true' \
  '.invocations | any(.argv[0] == "[" and .glob[0] == false)'
has "ANSI-C quoting decodes hex" "git push origin \$'ma\\x69n'" '["git","push","origin","main"]'
has "ANSI-C quoting decodes escapes" "echo \$'a\\tb\\n'" $'["echo","a\\tb\\n"]'
has "locale quoting is plain quoting" 'echo $"hi"' '["echo","hi"]'
has "adjacent quoted fragments join" "g''h pr merge 1" "$MERGE"
# shellcheck disable=SC2088 # The tilde is deliberately passed to the scanner unexpanded.
check "tilde program path keeps its name" '~/bin/gh pr merge 1' \
  '.invocations | any(.argv == ["~/bin/gh","pr","merge","1"] and .head_dynamic == false)'

# --- working directory tracking -------------------------------------------------------
check "plain command inherits the hook directory" 'git push' \
  '.invocations | any(.cwds == [""])'
check "cd with && replaces the directory" 'cd ../x && git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["../x"])'
check "cd with ; keeps the original too (the cd may fail)" 'cd ../x; git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["","../x"])'
check "cd chain joins relative paths" 'cd a && cd b && git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["a/b"])'
check "cd to an absolute path replaces" 'cd a && cd /tmp/y && git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["/tmp/y"])'
check "pushd is tracked like cd" 'pushd ../x >/dev/null && git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["../x"])'
check "cd to a variable is unknown" 'cd "$D" && git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["?"])'
check "bare cd is unknown" 'cd && git push' '.invocations | any(.argv[0] == "git" and .cwds == ["?"])'
check "cd - is unknown" 'cd - && git push' '.invocations | any(.argv[0] == "git" and .cwds == ["?"])'
check "cd to home is unknown" 'cd ~/x && git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["?"])'
check "popd is unknown" 'popd && git push' '.invocations | any(.argv[0] == "git" and .cwds == ["?"])'
check "a subshell cd does not leak out" '(cd ../x && git status); git push' \
  '.invocations | [.[] | select(.argv[0] == "git")] | .[0].cwds == ["../x"] and .[1].cwds == [""]'
check "a cd in a pipeline does not leak out" 'cd ../x | cat; git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == [""])'
check "a backgrounded cd does not leak out" 'cd ../x & git push' \
  '.invocations | any(.argv[0] == "git" and .cwds == [""])'
check "a substitution sees the current directory" 'cd ../x && echo $(git status)' \
  '.invocations | any(.argv[0] == "git" and .cwds == ["../x"])'

# --- heredocs and here-strings --------------------------------------------------------
check "arithmetic shift is not a heredoc" $'echo $((1<<N))\ngh pr merge 1' \
  ".invocations | any(.argv == $MERGE)"
check "arithmetic shift with a literal" 'echo $((1<<2))' \
  '.invocations | length == 1 and .[0].argv[0] == "echo"'
check "heredoc operator inside double quotes is text" $'echo "use <<EOF here"\ngh pr merge 1' \
  ".invocations | any(.argv == $MERGE)"
check "heredoc operator inside single quotes is text" $'echo \'use <<EOF here\'\ngh pr merge 1' \
  ".invocations | any(.argv == $MERGE)"
check "arithmetic command shift is not a heredoc" $'(( x = 1<<2 ))\ngh pr merge 1' \
  ".invocations | any(.argv == $MERGE)"
lacks "quoted string is not an invocation" 'echo "gh pr merge 1"' gh
lacks "single-quoted string is not an invocation" "echo 'gh pr merge 1'" gh
lacks "quoted heredoc body is literal" $'cat <<\'EOF\'\ngh pr merge 1\nEOF\n' gh
lacks "double-quoted heredoc delimiter is literal" $'cat <<"EOF"\ngh pr merge 1\nEOF\n' gh
lacks "backslash heredoc delimiter is literal" $'cat <<\\EOF\ngh pr merge 1\nEOF\n' gh
lacks "unquoted heredoc body is data, not commands" $'cat <<EOF\ngh pr merge 1\nEOF\n' gh
has "unquoted heredoc body runs its substitutions" $'cat <<EOF\n$(gh pr merge 1)\nEOF\n' "$MERGE"
has "unquoted heredoc body runs its backticks" $'cat <<EOF\n`gh pr merge 1`\nEOF\n' "$MERGE"
lacks "quoted heredoc body keeps substitutions literal" $'cat <<\'EOF\'\n$(gh pr merge 1)\nEOF\n' gh
has "heredoc into bash is a script" $'bash <<EOF\ngh pr merge 1\nEOF\n' "$MERGE"
has "heredoc into bash with no space" $'bash<<EOF\ngh pr merge 1\nEOF\n' "$MERGE"
has "quoted heredoc into bash is still a script" $'bash <<\'EOF\'\ngh pr merge 1\nEOF\n' "$MERGE"
has "heredoc into sudo bash" $'sudo bash <<EOF\ngh pr merge 1\nEOF\n' "$MERGE"
has "heredoc into bash after a continuation" $'bash \\\n  <<\'EOF\'\ngh pr merge 1\nEOF\n' "$MERGE"
lacks "heredoc into python is data" $'python3 - <<\'PY\'\ngh pr merge 1\nPY\nbash -n f.sh\n' gh
has "command after the heredoc still runs" $'cat <<EOF\nbody\nEOF\ngh pr merge 1' "$MERGE"
has "tab-indented heredoc terminator" $'cat <<-EOF\n\tbody\n\tEOF\ngh pr merge 1' "$MERGE"
has "two heredocs on one line" $'cat <<A <<B\nx\nA\ny\nB\ngh pr merge 1' "$MERGE"
has "here-string into bash is a script" "bash <<<'gh pr merge 1'" "$MERGE"
has "here-string with a space" "bash <<< 'gh pr merge 1'" "$MERGE"
lacks "here-string into cat is data" "cat <<< 'gh pr merge 1'" gh
check "heredoc inside a substitution parses with apostrophes in its body" \
  $'git commit -m "$(cat <<\'EOF\'\nit\'s a message\nEOF\n)"' \
  '.unparseable == false and (.invocations | any(.argv[0] == "git"))'
check "heredoc cut from a substitution does not hide later commands" \
  $'echo "$(cat <<\'EOF\'\nx\nEOF\n)"; gh pr merge 1' ".invocations | any(.argv == $MERGE)"

# --- pipes into a shell ---------------------------------------------------------------
has "pipe into bash" "echo 'gh pr merge 1' | bash" "$MERGE"
has "pipe into a path-qualified shell" "echo 'gh pr merge 1' | /bin/bash" "$MERGE"
has "pipe into sudo bash" "echo 'gh pr merge 1' | sudo bash" "$MERGE"
has "pipe into env bash" "echo 'gh pr merge 1' | env bash" "$MERGE"
has "pipe into sh -s" "echo 'gh pr merge 1' | sh -s" "$MERGE"
has "pipe into bash with no space" "echo 'gh pr merge 1' |bash" "$MERGE"
has "pipe through another stage into bash" "echo 'gh pr merge 1' | cat | bash" "$MERGE"
has "unquoted words on the left side" 'echo gh pr merge 1 | bash' "$MERGE"
has "group on the left side" "{ echo 'gh pr merge 1'; } | bash" "$MERGE"
has "heredoc on the left side" $'cat <<\'EOF\' | bash\ngh pr merge 1\nEOF\n' "$MERGE"
check "pipe into a shell is reported as pipe stdin" "echo x | bash" \
  '.invocations | any(.argv[0] == "bash" and .stdin == "pipe" and .script_stdin == true)'
check "pipe into a shell script file is not a script on stdin" "echo x | bash script.sh" \
  '.invocations | any(.argv[0] == "bash" and .stdin == "pipe" and .script_stdin == false)'
check "file redirect into a shell" "bash < script.sh" \
  '.invocations | any(.argv[0] == "bash" and .stdin == "file" and .script_stdin == true)'
lacks "pipe into a non-shell does not scan the left side" "echo 'gh pr merge 1' | tr a b" gh
has "pipe into bash -euo pipefail" "echo 'gh pr merge 1' | bash -euo pipefail" "$MERGE"
has "pipe into bash -" "echo 'gh pr merge 1' | bash -" "$MERGE"
has "pipe into a subshell running bash" "echo 'gh pr merge 1' | (bash)" "$MERGE"
has "heredoc into bash -" $'bash - <<\'EOF\'\ngh pr merge 1\nEOF\n' "$MERGE"
has "legacy arithmetic shift is not a heredoc" $'echo $[1<<2]\ngh pr merge 1' "$MERGE"
check "unclosed [[ with a semicolon is unparseable and terminates" '[[ ; git push origin main' '.unparseable == true'
has "bash script from process substitution" "bash <(echo 'gh pr merge 1')" "$MERGE"
has "bash stdin from process substitution" "bash < <(echo 'gh pr merge 1')" "$MERGE"
check "self-doubling variable stays bounded" "$(python3 -c "print('A=aaaaaaaa;' + 'A=\$A\$A;' * 40 + 'echo done')")" '.invocations | any(.argv[0] == "echo")'
has "git rebase --exec body" "git rebase --exec 'gh pr merge 1' HEAD~1" "$MERGE"
has "git rebase -x body" "git rebase -x 'gh pr merge 1' HEAD~1" "$MERGE"
has "git submodule foreach unquoted" "git submodule foreach gh pr merge 1" "$MERGE"
has "git bisect run argv" "git bisect run gh pr merge 1" "$MERGE"
has "git -c alias bang body" "git -c alias.x='!gh pr merge 1' x" "$MERGE"
lacks "grep for a shell name is not a pipe into a shell" "grep -n 'a|sh' file.py" gh

# --- nested scripts and substitutions -------------------------------------------------
has "bash -c" "bash -c 'gh pr merge 1'" "$MERGE"
has "bash -lc cluster" "bash -lc 'gh pr merge 1'" "$MERGE"
has "bash -c with an option after it" "bash -c -x 'gh pr merge 1'" "$MERGE"
has "sh -c through a path" "/bin/sh -c 'gh pr merge 1'" "$MERGE"
has "nested bash -c" "bash -c \"sh -c 'gh pr merge 1'\"" "$MERGE"
has "bash -c through sudo" "sudo -u me bash -c 'gh pr merge 1'" "$MERGE"
has "bash -c through xargs" "xargs sh -c 'gh pr merge 1'" "$MERGE"
has "eval of a string" "eval 'gh pr merge 1'" "$MERGE"
has "eval of words" 'eval gh pr merge 1' "$MERGE"
has "command substitution" 'echo $(gh pr merge 1)' "$MERGE"
has "command substitution in double quotes" 'echo "$(gh pr merge 1)"' "$MERGE"
has "backtick substitution" 'echo `gh pr merge 1`' "$MERGE"
has "nested substitution" 'echo $(echo $(gh pr merge 1))' "$MERGE"
has "process substitution" 'diff <(gh pr merge 1) x' "$MERGE"
has "process substitution after a redirect" 'while read x; do :; done < <(gh pr merge 1)' "$MERGE"
has "substitution in an assignment" 'x=$(gh pr merge 1)' "$MERGE"
has "substitution in a parameter default" 'echo ${x:-$(gh pr merge 1)}' "$MERGE"
has "substitution in arithmetic" 'echo $(( $(gh pr merge 1) + 1 ))' "$MERGE"
lacks "single-quoted substitution is literal" "echo '\$(gh pr merge 1)'" gh
lacks "escaped substitution is literal" 'echo "\$(gh pr merge 1)"' gh
check "bash script operand is not parsed as a script" 'bash deploy.sh' \
  '.invocations | length == 1'
check "substitution at top level is reported" 'echo $(date)' '.top_opaque == ["substitution"]'
check "substitution inside bash -c is reported as nested" "bash -c 'echo \$(date)'" \
  '.nested_opaque == ["substitution"]'
check "heredoc body substitution is not a top-level construct" $'cat <<EOF\n$(date)\nEOF\n' \
  '.top_opaque == [] and .nested_opaque == []'
check "eval is reported" 'eval ls' '.top_opaque | index("eval") != null'
check "source is reported" 'source ./x.sh' '.top_opaque | index("source") != null'
check "dot is reported" '. ./x.sh' '.top_opaque | index("source") != null'
check "alias is reported" 'alias ll=ls' '.top_opaque | index("alias") != null'

# --- unparseable input ----------------------------------------------------------------
check "unterminated single quote" "printf 'unterminated" '.unparseable == true'
check "unterminated double quote" 'printf "unterminated' '.unparseable == true'
check "unterminated substitution" 'echo $(date' '.unparseable == true'
check "unterminated backtick" 'echo `date' '.unparseable == true'
check "stray close paren" 'echo a)' '.unparseable == true'
check "commands before a syntax error are still returned" $'gh pr merge 1\necho "x' \
  ".unparseable == true and (.invocations | any(.argv == $MERGE))"
check "well-formed input is parseable" $'gh pr merge 1\necho "x"' '.unparseable == false'
check "empty input is parseable and empty" '' '.unparseable == false and (.invocations | length == 0)'
deep=$(python3 -c "print('echo \$(' * 20 + 'x' + ')' * 20)")
check "nesting beyond the depth limit is unparseable" "$deep" '.unparseable == true'

# --- argv0 filter and the record format -----------------------------------------------
only_git=$(python3 "$SCAN" --json --argv0 git --command 'timeout 5 git status; echo hi')
if jq -e '.invocations | length == 1 and .[0].argv[0] == "git" and .[0].wrappers == ["timeout"]' <<<"$only_git" >/dev/null; then
  report 1 "argv0 filter keeps a wrapped matching program only"
else
  report 0 "argv0 filter keeps a wrapped matching program only" "$only_git"
fi
filtered=$(python3 "$SCAN" --json --argv0 git --command 'echo hi; /usr/bin/git status; $X push; $ROOT/bin/deploy push; g?t push')
if jq -e '[.invocations[].argv[0]] == ["/usr/bin/git","$X","g?t"]' <<<"$filtered" >/dev/null; then
  report 1 "argv0 filter keeps git, an unresolved head, and a glob that can expand to git"
else
  report 0 "argv0 filter keeps git, an unresolved head, and a glob that can expand to git" "$filtered"
fi

fields=()
while IFS= read -r -d '' field; do
  fields+=("$field")
done < <(printf '%s' 'cd ../x && GIT_DIR=a git push origin "$B"' | python3 "$SCAN" --argv0 git)
expected=(unparseable=0 INV "" "" 0 1 ../x 1 0 GIT_DIR=a 4 0 git 0 push 0 origin 1 '$B' END)
if [ "${#fields[@]}" -eq "${#expected[@]}" ] && [ "${fields[*]}" = "${expected[*]}" ]; then
  report 1 "record stream layout"
else
  report 0 "record stream layout" "got: $(printf '[%s]' "${fields[@]}")"
fi

empty_fields=()
while IFS= read -r -d '' field; do
  empty_fields+=("$field")
done < <(printf '%s' 'echo hi' | python3 "$SCAN" --argv0 git)
if [ "${empty_fields[*]}" = "unparseable=0 END" ]; then
  report 1 "record stream with no match is just the flag and END"
else
  report 0 "record stream with no match is just the flag and END" "got: ${empty_fields[*]}"
fi

printf '\n--- %d pass, %d fail ---\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
