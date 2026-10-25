#!/bin/sh
#
# release.sh — build Monad's Release configuration and swap it into
# /Applications (docs/BUILDING.md).
#
#   release.sh            build, then install
#   release.sh build      build into ~/Library/Developer/Monad-Release
#                         (safe while Monad and its VMs run)
#   release.sh install    wait until Monad is quit and its VMs are stopped
#                         (its MonadHost goes idle), then put the build in
#                         /Applications, open it and check its MonadHost.
#                         In a terminal, Enter skips the wait for MonadHost
#                         once Monad has quit: the app is new at once (app
#                         fixes apply), MonadHost keeps the build it runs
#                         until it is next idle.
#   release.sh package    build from a clean checkout, then make the files
#                         of a GitHub release: Monad.zip and its SHA-256,
#                         which scripts/install.sh downloads and checks
#   release.sh vm         for a Monad bridge ("Release this" from a VM):
#                         build, then leave the install to launchd, since
#                         the bridge ends with the VM. Quitting Monad once
#                         its VMs are stopped is the go.
#
# Monad itself is never replaced while it runs, and MonadHost not while it
# serves: by default the swap waits for the Release MonadHost
# (dev.monad.host) to exit, 30 s after its last VM stops and Monad quits.
# The Debug build (dev.monad.debug.host, ~/.monad-debug) is never touched.

set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
DERIVED="$HOME/Library/Developer/Monad-Release"
BUILT="$DERIVED/Build/Products/Release/Monad.app"
DEST="/Applications/Monad.app"
APP_ID="dev.monad.Monad"
HOST_LABEL="dev.monad.host"
SWAP_LABEL="dev.monad.release-swap"
DOMAIN="gui/$(id -u)"

say() { printf 'release: %s\n' "$*"; }

host_running() {
    launchctl print "$DOMAIN/$HOST_LABEL" 2>/dev/null | grep -Eq '^[[:space:]]+pid = [0-9]+'
}

app_running() {
    [ "$(osascript -e "application id \"$APP_ID\" is running" 2>/dev/null || echo false)" = true ]
}

build() {
    mkdir -p "$DERIVED"
    head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "?")
    dirty=$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null | head -1)
    say "building $head${dirty:+ with uncommitted changes} (log: $DERIVED/build.log)"
    if ! xcodebuild -project "$REPO/Monad.xcodeproj" -scheme Monad -configuration Release \
        -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- build >"$DERIVED/build.log" 2>&1; then
        grep -E 'error:|warning:' "$DERIVED/build.log" | sort -u | head -40 || true
        say "the build failed"
        exit 1
    fi
    # The Release names, never the Debug build's (Flavor).
    id=$(plutil -extract CFBundleIdentifier raw -o - "$BUILT/Contents/Info.plist")
    host=$(codesign -dv "$BUILT/Contents/MacOS/MonadHost" 2>&1 | sed -n 's/^Identifier=//p')
    if [ "$id" != "$APP_ID" ] || [ "$host" != "dev.monad.MonadHost" ]; then
        say "built with the wrong identity ($id, $host): not a Release build"
        exit 1
    fi
    say "built $BUILT"
}

install_app() {
    [ -d "$BUILT" ] || { say "nothing built yet: run release.sh build"; exit 1; }
    told_app=0 told_host=0 keep_host=0
    while app_running; do
        if [ "$told_app" = 0 ]; then
            say "waiting for Monad to quit (⌘Q)"
            told_app=1
        fi
        sleep 2
    done
    while host_running; do
        if [ "$told_host" = 0 ]; then
            say "waiting for MonadHost (it runs the VMs, and exits 30 s after the last one stops)"
            if [ -t 0 ]; then
                say "or press Enter to install now: MonadHost keeps its build until it is next idle"
            fi
            told_host=1
        fi
        if [ -t 0 ]; then
            read -t 5 line 2>/dev/null && rc=0 || rc=$?
            if [ "$rc" = 0 ]; then keep_host=1; break; fi
            [ "$rc" -gt 128 ] || sleep 5 # no read -t here: just wait
        else
            sleep 5
        fi
    done
    say "installing into $DEST"
    rm -rf "$DEST.new" "$DEST.old"
    ditto "$BUILT" "$DEST.new"
    if [ -d "$DEST" ]; then mv "$DEST" "$DEST.old"; fi
    mv "$DEST.new" "$DEST"
    rm -rf "$DEST.old"
    if [ "$keep_host" = 1 ]; then
        open "$DEST"
        say "done: Monad is the new build. MonadHost keeps the build it runs (Monad says it is older)"
        say "until its VMs stop, or Restart VM Service in Monad; the new one starts after that"
        return 0
    fi
    # The new Monad loads its own MonadHost (HostAgent); none is running now.
    # launchd takes the old job down in the background, and a load before it
    # is gone fails (which left Monad without MonadHost until reopened).
    launchctl bootout "$DOMAIN/$HOST_LABEL" 2>/dev/null || true
    i=0
    while launchctl print "$DOMAIN/$HOST_LABEL" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    open "$DEST"
    want="$DEST/Contents/MacOS/MonadHost"
    plist="$HOME/.monad/launchd/$HOST_LABEL.plist"
    i=0
    while [ "$i" -lt 30 ]; do
        program=$(launchctl print "$DOMAIN/$HOST_LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*program = //p' | head -1)
        if [ "$program" = "$want" ]; then
            say "done: Monad is the new build, MonadHost is $program"
            return 0
        fi
        # Halfway with no job at all: load the one Monad wrote.
        if [ "$i" = 15 ] && [ -z "$program" ] && [ -f "$plist" ]; then
            say "launchd has no MonadHost yet: loading $plist"
            launchctl bootstrap "$DOMAIN" "$plist" 2>&1 | sed 's/^/release: /' || true
        fi
        sleep 2
        i=$((i + 1))
    done
    say "Monad is installed, but launchd's MonadHost is '${program:-not loaded}', not $want: see docs/BUILDING.md"
    exit 1
}

# The files of a GitHub release, from a clean checkout only (a release is
# what its tag says): the app zipped as Monad.app, and its SHA-256 in the
# form shasum writes, both downloaded by scripts/install.sh.
package() {
    dist="$DERIVED/dist"
    version=$(plutil -extract CFBundleShortVersionString raw -o - "$BUILT/Contents/Info.plist")
    rm -rf "$dist"
    mkdir -p "$dist"
    ditto -c -k --keepParent "$BUILT" "$dist/Monad.zip"
    (cd "$dist" && shasum -a 256 Monad.zip >Monad.zip.sha256)
    say "packaged Monad $version: $dist/Monad.zip and Monad.zip.sha256"
    say "pushing the tag v$version publishes them by itself (.github/workflows/release.yml); by hand:"
    say "  gh release create v$version \"$dist/Monad.zip\" \"$dist/Monad.zip.sha256\" --title \"Monad $version\" --notes-file NOTES.md"
}

clean_checkout() {
    if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        say "commit first: a release is built from a clean checkout"
        exit 1
    fi
}

# The install as a one-shot launchd job: it outlives the VM and the bridge
# that asked for it.
schedule_install() {
    plist="$DERIVED/$SWAP_LABEL.plist"
    launchctl bootout "$DOMAIN/$SWAP_LABEL" 2>/dev/null || true
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$SWAP_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>$REPO/scripts/release.sh</string><string>install</string></array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$DERIVED/swap.log</string>
    <key>StandardErrorPath</key><string>$DERIVED/swap.log</string>
</dict>
</plist>
EOF
    : >"$DERIVED/swap.log"
    launchctl bootstrap "$DOMAIN" "$plist"
}

case "${1:-all}" in
    build) build ;;
    install) install_app ;;
    all) build; install_app ;;
    package) clean_checkout; build; package ;;
    vm)
        exec 2>&1
        build
        schedule_install
        say "ready: shut down Monad's VMs and quit Monad; the new build then installs and opens by itself"
        say "(log on the Mac: $DERIVED/swap.log)"
        ;;
    *) say "usage: release.sh [build | install | package | vm]"; exit 2 ;;
esac
