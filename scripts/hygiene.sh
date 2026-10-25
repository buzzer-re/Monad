#!/bin/sh
#
# hygiene.sh — the checks CI runs first on every change (AGENTS.md ›
# Continuous integration). Run it before you push:
#
#   scripts/hygiene.sh [BASE]
#
# Always: no package manager (Swift packages, CocoaPods, Carthage: Monad uses
# no third-party code), the JSON files parse, the shell scripts parse. With
# BASE (a commit, branch or tag), the lines added since BASE are checked too:
# no personal home paths, no conflict markers, no whitespace errors. A change
# to Monad's code without a test, or without docs/STATUS.md, gets a warning.
#
# Exits 1 if a check fails and 2 if BASE is unknown; warnings don't change the
# status. On GitHub Actions the messages are annotations on their lines.

set -u
LC_ALL=C
export LC_ALL
cd "$(git rev-parse --show-toplevel)" || exit 2

# Home folders that are placeholders, not anyone's account.
PLACEHOLDERS="dev x someone user username you me name runner Shared example"

failed=0
say() { # say error|warning MESSAGE [FILE [LINE]]
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        where=""
        [ -n "${3:-}" ] && where=" file=$3${4:+,line=$4}"
        printf '::%s%s::%s\n' "$1" "$where" "$2"
    else
        printf 'hygiene: %s: %s%s\n' "$1" "${3:+$3${4:+:$4}: }" "$2"
    fi
}
fail() { say error "$@"; failed=1; }
warn() { say warning "$@"; }

# ---------------------------------------------------------------- the whole tree
files=$(git ls-files)
while IFS= read -r f; do
    case "${f##*/}" in
        Package.swift | Package.resolved | Podfile | Podfile.lock | Cartfile | Cartfile.resolved)
            fail "a package manager file: Monad uses no third-party code" "$f" ;;
        *.pbxproj)
            if grep -Eq 'XC(Remote|Local)SwiftPackageReference' "$f"; then
                fail "the project references a Swift package: Monad uses no third-party code" "$f"
            fi ;;
        *.json)
            if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f" 2>/dev/null; then
                fail "does not parse as JSON" "$f"
            fi ;;
        *.sh)
            if ! msg=$(sh -n "$f" 2>&1); then
                fail "does not parse: $(printf '%s' "$msg" | tr '\n' ' ')" "$f"
            fi ;;
    esac
done <<EOF
$files
EOF

# ---------------------------------------------------------------- the change since BASE
base=${1:-}
case "$base" in *[!0]*) ;; *) base="" ;; esac # GitHub sends all zeros for a new branch
if [ -z "$base" ]; then
    [ "$failed" -eq 0 ] || exit 1
    echo "hygiene: ok (whole tree only: no base to compare with)"
    exit 0
fi
if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    say error "unknown base: $base"
    exit 2
fi
mb=$(git merge-base "$base" HEAD) || exit 2

# Personal home paths in added lines, with their file and line.
paths=$(git diff --unified=0 --no-color --no-ext-diff "$mb" | awk -v allow="$PLACEHOLDERS" '
    BEGIN { n = split(allow, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    /^\+\+\+ / { file = substr($0, 7); next }
    /^@@ / { s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); split(s, p, /[ ,]/); line = p[1] + 0; next }
    /^\+/ {
        rest = substr($0, 2)
        while (match(rest, /\/(Users|home)\/[A-Za-z0-9._-]+/)) {
            m = substr(rest, RSTART, RLENGTH)
            name = m; sub(/^\/(Users|home)\//, "", name)
            if (!(name in ok)) print file "\t" line "\t" m
            rest = substr(rest, RSTART + RLENGTH)
        }
        line++
    }')
while IFS='	' read -r f l m; do
    [ -n "$f" ] && fail "a personal home path, $m: use a placeholder such as /Users/dev" "$f" "$l"
done <<EOF
$paths
EOF

# Whitespace errors and conflict markers, as git sees them.
checked=$(git diff --check --no-color "$mb" | sed -n 's/^\([^+:][^:]*\):\([0-9][0-9]*\): \(.*\)$/\1	\2	\3/p')
while IFS='	' read -r f l m; do
    [ -n "$f" ] && fail "$m" "$f" "$l"
done <<EOF
$checked
EOF

# Code without a test, or without STATUS: worth a look, not a failure.
code=no tests=no status=no
changed=$(git diff --name-only "$mb")
while IFS= read -r f; do
    case "$f" in
        MonadTests/* | CTests/*) tests=yes ;;
        docs/STATUS.md) status=yes ;;
        Monad/*.swift | Monad/*.m | Monad/*.h | Monad/*.c | Monad/Guest/* | MonadHost/* | scripts/*.sh) code=yes ;;
    esac
done <<EOF
$changed
EOF
if [ "$code" = yes ] && [ "$tests" = no ]; then
    warn "the code changed without a test (AGENTS.md › Rules: tests first)"
fi
if [ "$code" = yes ] && [ "$status" = no ]; then
    warn "the code changed but docs/STATUS.md did not: check it still says where things stand"
fi

[ "$failed" -eq 0 ] || exit 1
echo "hygiene: ok"
