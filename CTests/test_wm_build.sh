#!/bin/sh
# Tests for Monad/Guest/monad-wm-build.sh: the VM's window manager is built
# from the sources beside it with the VM's own compiler, only when the
# sources are not the ones it was built from; a compiler that fails leaves
# the program that was there. Stand-ins for cc and sha256sum, a folder of
# its own.
# Usage: test_wm_build.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../Monad/Guest/monad-wm-build.sh"
SH=${WM_BUILD_SHELL:-sh}
SH_PATH=$(command -v "$SH")   # the PATH below has no shell in it
WORK=${1:-$(mktemp -d)}
rm -rf "$WORK"
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
checks=0
failures=0

check() { # check NAME EXPECTED ACTUAL
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        failures=$((failures + 1))
        printf '%s: FAIL\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3" >&2
    fi
}

# The tools the script may use, and nothing else: the machine's own cc must never be found.
SYS="$WORK/sys"
mkdir -p "$SYS"
for tool in cat chmod cut ls mv rm; do
    real=$(command -v "$tool") || { echo "test_wm_build.sh: no $tool" >&2; exit 1; }
    ln -s "$real" "$SYS/$tool"
done
# sha256sum, where the machine running the tests has only shasum (a Mac).
if command -v sha256sum >/dev/null 2>&1; then
    ln -s "$(command -v sha256sum)" "$SYS/sha256sum"
else
    SHASUM=$(command -v shasum) PERL_DIR=$(dirname "$(command -v perl)")
    printf '#!%s\nPATH=%s:$PATH exec %s -a 256 "$@"\n' "$SH_PATH" "$PERL_DIR" "$SHASUM" > "$SYS/sha256sum"
    chmod 755 "$SYS/sha256sum"
fi

BIN="$WORK/bin"
LIB="$WORK/lib"
mkdir -p "$BIN"
# cc: notes how it was called, and writes a program that says which build it is;
# CC_FAILS makes it fail, CC_EMPTY makes it write nothing.
cat > "$BIN/cc" <<EOF
#!$SH_PATH
echo "\$*" >> "$WORK/cc.calls"
[ -n "\${CC_FAILS:-}" ] && { echo "error: expected ';'" >&2; exit 1; }
out=
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
[ -n "\${CC_EMPTY:-}" ] && { : > "\$out"; exit 0; }
n=\$(cat "$WORK/builds" 2>/dev/null || echo 0)
n=\$((n + 1))
echo \$n > "$WORK/builds"
echo "build \$n" > "\$out"
EOF
chmod 755 "$BIN/cc"

run() { # run [VAR=value ...]: the script on $LIB; its output and status are kept
    env -i PATH="$BIN:$SYS" "$@" "$SH_PATH" "$SCRIPT" "$LIB" > "$WORK/out" 2> "$WORK/err"
    status=$?
}
calls() { [ -f "$WORK/cc.calls" ] && wc -l < "$WORK/cc.calls" | tr -d ' ' || echo 0; }

# No sources: nothing to build from.
mkdir -p "$LIB"
run
check "no sources: status" 69 "$status"
check "no sources: says so" "monad-wm-build: Monad has put no sources in $LIB/wm (it does for a VM whose Display is on)" "$(cat "$WORK/err")"
check "no sources: the compiler was not run" 0 "$(calls)"

mkdir -p "$LIB/wm"
echo 'int main(void) { return 0; }' > "$LIB/wm/mwm_main.c"
echo 'int other(void) { return 1; }' > "$LIB/wm/mwm_other.c"
echo '#define ONE 1' > "$LIB/wm/mwm.h"

# No compiler.
env -i PATH="$SYS" "$SH_PATH" "$SCRIPT" "$LIB" > "$WORK/out" 2> "$WORK/err"
check "no compiler: status" 69 "$?"
check "no compiler: says so" "monad-wm-build: this VM has no C compiler (cc); the Windows profile installs one" "$(cat "$WORK/err")"
check "no compiler: no program" "" "$(ls "$LIB" | grep -v '^wm$')"

# The first build.
run
check "first: status" 0 "$status"
check "first: says it built" built "$(cat "$WORK/out")"
check "first: the compiler's arguments" "-std=gnu11 -O2 -o $LIB/monad-wm.new $LIB/wm/mwm_main.c $LIB/wm/mwm_other.c" "$(cat "$WORK/cc.calls")"
check "first: the program" "build 1" "$(cat "$LIB/monad-wm")"
check "first: it can be run" yes "$([ -x "$LIB/monad-wm" ] && echo yes)"
check "first: nothing left over" "monad-wm monad-wm.built wm " "$(ls "$LIB" | tr '\n' ' ')"

# Nothing changed: nothing is built, and nothing is said.
run
check "same: status" 0 "$status"
check "same: silent" "" "$(cat "$WORK/out")$(cat "$WORK/err")"
check "same: the compiler was not run again" 1 "$(calls)"

# A source, a header, a new file, a file gone: each is a new build.
echo 'int main(void) { return 2; }' > "$LIB/wm/mwm_main.c"
run
check "source changed: built" "built 2" "$(cat "$WORK/out") $(calls)"
echo '#define ONE 2' > "$LIB/wm/mwm.h"
run
check "header changed: built" "built 3" "$(cat "$WORK/out") $(calls)"
echo 'int more(void) { return 3; }' > "$LIB/wm/mwm_more.c"
run
check "file added: built" "built 4" "$(cat "$WORK/out") $(calls)"
rm "$LIB/wm/mwm_other.c"
run
check "file gone: built" "built 5" "$(cat "$WORK/out") $(calls)"
check "file gone: the program" "build 5" "$(cat "$LIB/monad-wm")"
run
check "then nothing more" " 5" "$(cat "$WORK/out") $(calls)"

# The program is gone (somebody removed it): built again from the same sources.
rm "$LIB/monad-wm"
run
check "program gone: built" "built 6" "$(cat "$WORK/out") $(calls)"

# A compiler that fails: its status, and the program that was there stays, to be tried again next time.
echo 'int main(void) { return 3 }' > "$LIB/wm/mwm_main.c"
run CC_FAILS=1
check "compiler fails: its status" 1 "$status"
check "compiler fails: not said built" "" "$(cat "$WORK/out")"
check "compiler fails: says so" "error: expected ';'
monad-wm-build: the compiler failed (status 1)" "$(cat "$WORK/err")"
check "compiler fails: the old program stays" "build 6" "$(cat "$LIB/monad-wm")"
check "compiler fails: nothing half done is left" "" "$(ls "$LIB" | grep new)"
run CC_EMPTY=1
check "compiler writes nothing: a failure" 70 "$status"
check "compiler writes nothing: the old program stays" "build 6" "$(cat "$LIB/monad-wm")"
run
check "tried again: built" "built" "$(cat "$WORK/out")"
check "tried again: the program" "build 7" "$(cat "$LIB/monad-wm")"

echo "test_wm_build.sh ($SH): $checks checks, $failures failures"
[ "$failures" -eq 0 ]
