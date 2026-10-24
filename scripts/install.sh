#!/bin/sh
#
# install.sh — install Monad on this Mac (README.md › Install).
#
#   curl -fsSL https://raw.githubusercontent.com/buzzer-re/Monad/main/scripts/install.sh | sh
#
#   install.sh                  the build in this checkout's build/ folder if
#                               there is one, else the latest release
#   install.sh --release [TAG]  download a release (the latest by default),
#                               checked against its published SHA-256
#   install.sh --build          build the Release configuration from this
#                               checkout into build/ (needs Xcode), then install
#   install.sh --from PATH      install a Monad.app, or a release's Monad.zip
#   --dest DIR                  where Monad.app goes (default /Applications)
#   --no-open                   do not open Monad afterwards
#
# Monad is signed ad hoc (no Apple Developer ID), so macOS refuses to open a
# copy downloaded with a browser. The copy installed here has its quarantine
# flag removed, which makes this script the check instead: it installs only
# Monad's Release build (bundle id dev.monad.Monad) with an intact signature,
# and a download only when it matches the release's SHA-256. Monad is never
# replaced while it runs, nor while its VMs run (its MonadHost exits 30 s
# after the last one stops). Nothing here uses sudo.
#
# Everything is in functions, and the last line runs main: piped to sh and
# cut short, the script defines functions and does nothing.

say() { printf 'install: %s\n' "$*"; }
fail() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: install.sh [--release [TAG] | --build | --from PATH] [--dest DIR] [--no-open]

  (no source)      the build in this checkout's build/ folder, else the latest release
  --release [TAG]  download a release (the latest by default), checked against its SHA-256
  --build          build the Release configuration from this checkout (needs Xcode)
  --from PATH      install a Monad.app, or a release's Monad.zip
  --dest DIR       where Monad.app goes (default /Applications)
  --no-open        do not open Monad afterwards
EOF
}

set_source() {
    [ -z "$source" ] || fail "choose one of --release, --build and --from"
    source=$1
}
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --release)
                set_source release
                if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then
                    tag=$2
                    shift
                fi
                ;;
            --build) set_source build ;;
            --from)
                [ $# -gt 1 ] || fail "--from needs a path"
                set_source from
                from=$2
                shift
                ;;
            --dest)
                [ $# -gt 1 ] || fail "--dest needs a folder"
                dest_dir=$2
                shift
                ;;
            --no-open) open_after=0 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

where_it_runs() {
    [ "$(uname -s)" = Darwin ] || fail "Monad runs on macOS"
    [ "$(id -u)" != 0 ] || fail "run it as yourself, without sudo: Monad and its VMs belong to your account"
    case "$SLUG" in
        */*/* | *[!A-Za-z0-9._/-]* | /* | */) fail "MONAD_GITHUB is not owner/repository: $SLUG" ;;
        */*) ;;
        *) fail "MONAD_GITHUB is not owner/repository: $SLUG" ;;
    esac
    case "$dest_dir" in
        /*) ;;
        *) dest_dir="$(pwd)/$dest_dir" ;;
    esac
    DOMAIN="gui/$(id -u)"

    # A checkout when this script is its scripts/install.sh (not when piped).
    here=$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)
    repo=""
    if [ -n "$here" ] && [ -d "$here/../Monad.xcodeproj" ]; then repo=$(cd "$here/.." && pwd); fi
}

# On the way out: the work folder and a half-made copy go, and if the old
# Monad was moved aside and the new one is not in its place, it goes back.
cleanup() {
    if [ -n "$aside" ]; then
        if [ -e "$dest" ]; then rm -rf "$aside"; else mv "$aside" "$dest"; fi
    fi
    if [ -n "$new" ]; then rm -rf "$new"; fi
    if [ -n "$work" ]; then rm -rf "$work"; fi
}

plist_value() { # FILE KEY
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

is_tag() {
    case "$1" in
        '' | -* | .* | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

is_sha256() {
    case "$1" in
        '' | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

unpack() { # ZIP: sets app
    mkdir "$work/unpacked"
    ditto -x -k "$1" "$work/unpacked" || fail "cannot unpack $1"
    app="$work/unpacked/Monad.app"
    [ -d "$app" ] || fail "$1 holds no Monad.app"
}

download() {
    base="https://github.com/$SLUG/releases"
    if [ -z "$tag" ]; then
        landed=$(curl -fsSIL --proto '=https' -o /dev/null -w '%{url_effective}' "$base/latest") ||
            fail "cannot reach $base (no network, or no release yet: --build installs from a checkout)"
        tag=${landed##*/tag/}
        [ "$tag" != "$landed" ] || fail "no release published at $base yet: --build installs from a checkout"
    fi
    is_tag "$tag" || fail "not a release tag: $tag"
    say "downloading Monad $tag from $base"
    curl -fL --proto '=https' --progress-bar -o "$work/Monad.zip" "$base/download/$tag/Monad.zip" ||
        fail "cannot download Monad.zip of $tag"
    curl -fsSL --proto '=https' -o "$work/Monad.zip.sha256" "$base/download/$tag/Monad.zip.sha256" ||
        fail "cannot download Monad.zip.sha256 of $tag"
    want=$(awk 'NR == 1 { print tolower($1) }' "$work/Monad.zip.sha256")
    is_sha256 "$want" || fail "Monad.zip.sha256 of $tag holds no SHA-256"
    got=$(shasum -a 256 "$work/Monad.zip" | awk '{ print $1 }')
    [ "$got" = "$want" ] ||
        fail "Monad.zip does not match its SHA-256 (got $got, the release says $want): nothing installed"
    say "SHA-256 matches ($got)"
    unpack "$work/Monad.zip"
}

build_here() {
    [ -n "$repo" ] || fail "--build needs a checkout of Monad: git clone https://github.com/$SLUG"
    command -v xcodebuild >/dev/null || fail "--build needs Xcode (xcodebuild)"
    mkdir -p "$repo/build"
    say "building the Release configuration into $repo/build (log: $repo/build/build.log)"
    if ! xcodebuild -project "$repo/Monad.xcodeproj" -scheme Monad -configuration Release \
        -derivedDataPath "$repo/build" CODE_SIGN_IDENTITY=- build >"$repo/build/build.log" 2>&1; then
        grep -E 'error:' "$repo/build/build.log" | sort -u | head -20 >&2 || true
        fail "the build failed (log: $repo/build/build.log)"
    fi
    app="$repo/build/Build/Products/Release/Monad.app"
}

built_app() { # the app in the checkout's build/ folder, if any
    [ -n "$repo" ] || return 1
    for a in "$repo/build/Build/Products/Release/Monad.app" "$repo/build/Monad.app"; do
        if [ -d "$a" ]; then
            echo "$a"
            return 0
        fi
    done
    return 1
}

get_app() { # sets app
    if [ -z "$source" ]; then
        if app=$(built_app); then source=built; else source=release; fi
    fi
    case "$source" in
        release) download ;;
        build) build_here ;;
        built)
            made=$(date -r "$app" '+%Y-%m-%d %H:%M' 2>/dev/null ||
                stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$app" 2>/dev/null || echo "?")
            say "installing the build in $app (made $made)"
            say "(--build makes a new one, --release downloads the latest release)"
            ;;
        from)
            if [ -d "$from" ]; then
                app=$from
            elif [ -f "$from" ]; then
                unpack "$from"
            else
                fail "no such app or zip: $from"
            fi
            ;;
    esac
}

# Only Monad's Release build, with a signature that still holds.
check_app() { # sets version
    [ -f "$app/Contents/Info.plist" ] || fail "$app is not an app"
    id=$(plist_value "$app/Contents/Info.plist" CFBundleIdentifier)
    [ "$id" = "$APP_ID" ] || fail "$app is not Monad's Release build (bundle id '${id:-none}', not $APP_ID)"
    [ -x "$app/Contents/MacOS/MonadHost" ] || fail "$app has no MonadHost"
    codesign --verify --deep --strict "$app" 2>/dev/null ||
        fail "$app's signature does not hold (it changed after it was signed): not installed"
    version=$(plist_value "$app/Contents/Info.plist" CFBundleShortVersionString)
}

# Only over a Monad, in a folder this account can write.
check_dest() { # sets dest
    dest="$dest_dir/Monad.app"
    mkdir -p "$dest_dir" 2>/dev/null || true
    [ -d "$dest_dir" ] && [ -w "$dest_dir" ] ||
        fail "cannot write to $dest_dir (an admin account can): or install with --dest ~/Applications"
    if [ -e "$dest" ]; then
        old=$(plist_value "$dest/Contents/Info.plist" CFBundleIdentifier)
        [ "$old" = "$APP_ID" ] || fail "$dest is not Monad (bundle id '${old:-none}'): left as it is"
    fi
}

app_running() {
    [ "$(osascript -e "application id \"$APP_ID\" is running" 2>/dev/null || echo false)" = true ]
}
host_running() {
    launchctl print "$DOMAIN/$HOST_LABEL" 2>/dev/null | grep -Eq '^[[:space:]]+pid = [0-9]+'
}
wait_until_quiet() {
    told=0
    while app_running; do
        if [ "$told" = 0 ]; then say "waiting for Monad to quit (⌘Q)"; fi
        told=1
        sleep 2
    done
    told=0
    while host_running; do
        if [ "$told" = 0 ]; then
            say "waiting for Monad's VMs to stop (VM › Stop All VMs): MonadHost exits 30 s after the last one"
        fi
        told=1
        sleep 5
    done
}

# The new copy is made beside the old one, then two moves swap them. Any
# exit between the two (a failure, ^C) puts the old one back (cleanup), so
# there is always a Monad in $dest.
swap() {
    say "installing Monad ${version:-?} into $dest"
    new="$dest.new"
    rm -rf "$new" "$dest.old"
    ditto "$app" "$new"
    xattr -dr com.apple.quarantine "$new" 2>/dev/null || true
    ! xattr -p com.apple.quarantine "$new" >/dev/null 2>&1 || fail "cannot remove the quarantine flag from $new"
    if [ -d "$dest" ]; then
        aside="$dest.old"
        mv "$dest" "$aside"
    fi
    mv "$new" "$dest"
    new=""
    if [ -n "$aside" ]; then
        aside=""
        rm -rf "$dest.old"
    fi
}

# The new Monad loads its own MonadHost. launchd takes an old job down in
# the background, and a load before it is gone fails.
unload_host() {
    launchctl bootout "$DOMAIN/$HOST_LABEL" 2>/dev/null || true
    i=0
    while launchctl print "$DOMAIN/$HOST_LABEL" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
}

main() {
    set -eu
    SLUG=${MONAD_GITHUB:-buzzer-re/Monad}
    APP_ID="dev.monad.Monad"
    HOST_LABEL="dev.monad.host"
    source="" tag="" from="" dest_dir="/Applications" open_after=1
    parse_args "$@"
    where_it_runs

    work="" new="" aside="" dest=""
    work=$(mktemp -d "${TMPDIR:-/tmp}/monad-install.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM

    get_app
    check_app
    check_dest
    wait_until_quiet
    swap
    unload_host

    say "installed Monad ${version:-?} in $dest"
    if [ "$open_after" = 1 ]; then
        open "$dest"
        say "opened it: the first VM downloads its distribution's image, checked against the distribution's signature or checksum"
    fi
}

main "$@"
