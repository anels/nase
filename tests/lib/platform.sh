#!/usr/bin/env bash
# Platform probes shared by tests that cannot assume a POSIX filesystem.
#
# Source this file. Every probe tests the behavior the assertion needs rather than the OS
# name, so a Windows runner that does enforce it (or a POSIX one that does not) is judged
# on what it actually does. Route skips through `plat_count_skip` and end with
# `plat_skip_summary` so a skipped check is counted on screen, not silent.
#
#   plat_export_weak_lock    export NASE_WEAK_LOCK=1 when Python has no fcntl
#   plat_modes_stored        0 when stat reads back the mode chmod set
#   plat_perms_enforced      0 when chmod 000 really blocks a read
#   plat_native_path PATH    PATH as `C:/...` where cygpath exists, else unchanged. MSYS
#                            converts a `/tmp/...` argument or variable for Windows
#                            Python, but not one written into a file, nor an argument
#                            that runs through a regular file; Python then reads it
#                            against the current drive
#   plat_sha256              SHA-256 hex digest of stdin. Git Bash keeps `shasum` in a
#                            directory that only a login shell adds to PATH
#   shasum -a 256            defined only where no shasum is on PATH; runs sha256sum
#   plat_colon_filenames     0 when a file name may contain a colon (Windows forbids it)
#   plat_symlinks_real       0 when `ln -s` makes a real symlink (not a copy)
#   make_symlink TARGET LINK ln -s, or count a skip and return 1 when links are copies;
#                            a failing ln where links work ends the test
#   plat_path_tool NAME DIR  expose command NAME in a narrow-PATH directory DIR through an
#                            exec wrapper, because a copied or linked Windows .exe misses
#                            its DLLs and exits 127. A builtin is left alone

PLAT_SKIPPED=0

plat_export_weak_lock() {
  python3 -c 'import fcntl' 2>/dev/null || export NASE_WEAK_LOCK=1
}

plat_count_skip() {
  PLAT_SKIPPED=$((PLAT_SKIPPED + 1))
}

plat_skip_summary() {
  if (( PLAT_SKIPPED > 0 )); then
    printf '[warn] %s check(s) skipped: this platform lacks something they need (file modes, symlinks, colon file names, or zip).\n' \
      "$PLAT_SKIPPED" >&2
  fi
}

# 0 when chmod 600 is what stat reads back, so a mode assertion means something.
plat_modes_stored() {
  local probe mode
  probe=$(mktemp) || return 1
  chmod 600 "$probe" 2>/dev/null
  mode=$(stat -c '%a' "$probe" 2>/dev/null || stat -f '%Lp' "$probe" 2>/dev/null)
  rm -f "$probe"
  [ "$mode" = "600" ]
}

# 0 when chmod 000 really blocks a read. False on NTFS under Git Bash, and for root.
plat_perms_enforced() {
  local probe rc=0
  probe=$(mktemp) || return 1
  chmod 000 "$probe" 2>/dev/null
  cat "$probe" >/dev/null 2>&1 && rc=1
  chmod 600 "$probe" 2>/dev/null
  rm -f "$probe"
  return "$rc"
}

plat_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

plat_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi | cut -d' ' -f1
}

# For a test that calls `shasum -a 256` by name: where none is on PATH, run sha256sum.
if ! command -v shasum >/dev/null 2>&1; then
  shasum() {
    if [ "$*" != "-a 256" ]; then
      printf 'shasum stand-in: only "-a 256" on stdin is supported, got: %s\n' "$*" >&2
      return 2
    fi
    sha256sum
  }
fi

plat_colon_filenames() {
  local dir rc=1
  dir=$(mktemp -d) || return 1
  python3 -c 'import sys; open(sys.argv[1] + "/a:b", "w").close()' "$dir" 2>/dev/null \
    && [ -n "$(find "$dir" -name 'a:b' 2>/dev/null)" ] && rc=0
  rm -rf "$dir"
  return "$rc"
}

plat_symlinks_real() {
  local dir rc=1
  dir=$(mktemp -d) || return 1
  : > "$dir/t"
  if ln -s t "$dir/l" 2>/dev/null && [ -L "$dir/l" ]; then
    rc=0
  fi
  rm -rf "$dir"
  return "$rc"
}

plat_path_tool() {
  local name="$1" dir="$2" real
  real=$(command -v "$name") || return 0
  [[ "$real" == /* ]] || return 0
  printf '#!%s\nexec %q "$@"\n' "$BASH" "$real" > "$dir/$name" && chmod +x "$dir/$name"
}

make_symlink() {
  if ! plat_symlinks_real; then
    plat_count_skip
    printf 'SKIP  symlink not available on this platform: %s\n' "$2" >&2
    return 1
  fi
  ln -s "$1" "$2" && return 0
  printf 'FAIL  could not create symlink: %s\n' "$2" >&2
  exit 1
}
