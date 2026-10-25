#!/bin/sh
# Tests for scripts/hygiene.sh, the checks CI runs on every change: a scratch
# repository shaped like Monad's, one change at a time from the same base.
# Usage: test_hygiene.sh [workdir]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HYGIENE="$HERE/../scripts/hygiene.sh"
SH=${HYGIENE_SHELL:-sh}
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

# A git of our own: no user or system config, a fixed identity.
mkdir -p "$WORK/home"
HOME="$WORK/home"
GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export HOME GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

REPO="$WORK/repo"
g() { git -C "$REPO" "$@"; }
put() { mkdir -p "$(dirname "$REPO/$1")"; cat >"$REPO/$1"; } # put PATH < content

mkdir -p "$REPO"
g init -q
put Monad/Distros/ubuntu.distro.json <<'EOF'
{ "schema": 1, "id": "ubuntu" }
EOF
put Monad/Profiles/agentic.profile.json <<'EOF'
{ "id": "agentic" }
EOF
put Monad/Themes/basic.theme.json <<'EOF'
{ "name": "Basic" }
EOF
put Monad/VM/Thing.swift <<'EOF'
let thing = 1
EOF
put MonadTests/ThingTests.swift <<'EOF'
let tested = 1
EOF
put Monad/Guest/agent.sh <<'EOF'
#!/bin/sh
echo hello
EOF
put Monad.xcodeproj/project.pbxproj <<'EOF'
// !$*UTF8*$!
{ objects = { }; }
EOF
put docs/STATUS.md <<'EOF'
# Where things stand
EOF
g add -A
g commit -q -m base
g tag base

change() { g checkout -q -f -B change base; } # a new change from the base
commit() { g add -A; g commit -q -m change; }
run() { out=$(cd "$REPO" && GITHUB_ACTIONS='' "$SH" "$HYGIENE" "$@" 2>&1); st=$?; }
has() { case "$out" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# A clean change, with its test and STATUS: nothing to say.
change
echo 'let thing = 2' >"$REPO/Monad/VM/Thing.swift"
echo 'let tested = 2' >"$REPO/MonadTests/ThingTests.swift"
echo '- Thing is 2.' >>"$REPO/docs/STATUS.md"
commit
run base
check "clean: status" 0 "$st"
check "clean: no warning" no "$(has warning)"

# Code without a test, or without STATUS: warnings, not failures.
change
echo 'let thing = 3' >"$REPO/Monad/VM/Thing.swift"
commit
run base
check "untested: status" 0 "$st"
check "untested: warns about tests" yes "$(has 'without a test')"
check "untested: warns about STATUS" yes "$(has 'docs/STATUS.md')"

# A personal home path in an added line fails, and says where.
change
printf 'let thing = 4\nlet home = "/Users/alice/src"\n' >"$REPO/Monad/VM/Thing.swift"
echo 'let tested = 4' >"$REPO/MonadTests/ThingTests.swift"
commit
run base
check "home path: status" 1 "$st"
check "home path: where" yes "$(has 'Monad/VM/Thing.swift:2')"
check "home path: which" yes "$(has '/Users/alice')"

change
echo 'cd /home/alice.guest/work' >>"$REPO/Monad/Guest/agent.sh"
commit
run base
check "linux home path: status" 1 "$st"

# Placeholders are fine.
change
printf 'let a = "/Users/dev/app"\nlet b = "/home/dev/app"\nlet c = "/Users/Shared/x"\n' >"$REPO/MonadTests/ThingTests.swift"
commit
run base
check "placeholders: status" 0 "$st"

# A package manager is refused, in any form.
change
echo '// swift-tools-version:5.9' >"$REPO/Package.swift"
commit
run base
check "Package.swift: status" 1 "$st"
check "Package.swift: says so" yes "$(has 'Package.swift')"

change
printf '// !$*UTF8*$!\n{ objects = { A = { isa = XCRemoteSwiftPackageReference; }; }; }\n' >"$REPO/Monad.xcodeproj/project.pbxproj"
commit
run base
check "Swift package in the project: status" 1 "$st"

# Data files and scripts must parse.
change
echo '{ "id": "ubuntu", }' >"$REPO/Monad/Distros/ubuntu.distro.json"
commit
run base
check "bad JSON: status" 1 "$st"
check "bad JSON: which file" yes "$(has 'ubuntu.distro.json')"

change
printf '#!/bin/sh\nif true; then\n' >"$REPO/Monad/Guest/agent.sh"
commit
run base
check "bad shell: status" 1 "$st"
check "bad shell: which file" yes "$(has 'agent.sh')"

# Whitespace errors and conflict markers in added lines.
change
printf 'let thing = 5   \n' >"$REPO/Monad/VM/Thing.swift"
echo 'let tested = 5' >"$REPO/MonadTests/ThingTests.swift"
commit
run base
check "trailing whitespace: status" 1 "$st"

change
printf '<<<<<<< ours\nlet thing = 6\n=======\nlet thing = 7\n>>>>>>> theirs\n' >"$REPO/Monad/VM/Thing.swift"
echo 'let tested = 6' >"$REPO/MonadTests/ThingTests.swift"
commit
run base
check "conflict markers: status" 1 "$st"

# Without a base only the whole-tree checks run; an unknown base is a usage error.
change
run
check "no base: status" 0 "$st"
run no-such-ref
check "unknown base: status" 2 "$st"

# On GitHub, errors become annotations on the line.
change
printf 'let home = "/Users/alice"\n' >"$REPO/Monad/VM/Thing.swift"
echo 'let tested = 7' >"$REPO/MonadTests/ThingTests.swift"
commit
out=$(cd "$REPO" && GITHUB_ACTIONS=true "$SH" "$HYGIENE" base 2>&1); st=$?
check "annotation: status" 1 "$st"
check "annotation: format" yes "$(has '::error file=Monad/VM/Thing.swift,line=1::')"

printf 'hygiene tests (%s): %d checks, %d failures\n' "$SH" "$checks" "$failures" >&2
[ "$failures" -eq 0 ]
