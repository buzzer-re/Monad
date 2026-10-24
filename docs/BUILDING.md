# Building Monad: Release for use, Debug for work

Two builds live side by side on one Mac. The Release build is the Monad you use (your VMs,
including the one you develop Monad in); the Debug build is the one Xcode builds, runs and tests.
They share nothing (`Monad/Support/Flavor.swift`, checked by `FlavorTests`):

| | Release (`/Applications/Monad.app`) | Debug (Xcode) |
|---|---|---|
| App name, bundle id | Monad, `dev.monad.Monad` | Monad Debug, `dev.monad.Monad.debug` |
| MonadHost (launchd label, Mach service) | `dev.monad.host` | `dev.monad.debug.host` |
| MonadHost signing identifier | `dev.monad.MonadHost` | `dev.monad.MonadHost.debug` |
| VMs, networks, keys, logs | `~/.monad` | `~/.monad-debug` |
| Unified log subsystem | `dev.monad` | `dev.monad.debug` |

Each app only talks to its own MonadHost (each pins the other's signing identifier), and neither
build lets a VM share either data folder. Both may list the same Lima VMs: whichever boots or
copies a Lima disk first holds `monad.lock` in that Lima VM's folder, and the other refuses until
it lets go. Debug builds always load MonadHost with launchctl.

## Make or update the Release build: scripts/release.sh

```sh
scripts/release.sh            # build, then install
scripts/release.sh build      # build only (safe while Monad and its VMs run)
scripts/release.sh install    # swap in the last build
```

The build goes to `~/Library/Developer/Monad-Release` (its own folder: Xcode's Debug build and
anything running are not touched) and is checked to carry the Release names. The install waits
until Monad is quit and its VMs are stopped (the Release MonadHost exits 30 s after that), then
replaces `/Applications/Monad.app`, opens it and checks that launchd's MonadHost is the new one.
Nothing is replaced while a Release VM runs. If the Dock shows an old icon, `killall Dock`.

Once Monad has quit, Enter (in a terminal) skips the wait for MonadHost: the app is replaced at
once, so changes in the app apply, and the VMs keep running. MonadHost keeps the build it runs
(Monad says the VM service is older) until it is next idle or Restart VM Service, then the new
one starts. Wait instead when the change is in MonadHost (VMs, networks, forwards, bridges).

### "Release this" from a VM

A VM can start it through a bridge (VM window › Bridges): name `release`, command
`/bin/sh <repository>/scripts/release.sh vm`, guest port 9001. In the VM:

```sh
nc 127.0.0.1 9001 </dev/null
```

prints the build; when it succeeds the install is left to a one-shot launchd job
(`dev.monad.release-swap`, log `~/Library/Developer/Monad-Release/swap.log`), since the bridge ends
with the VM. Shut down Monad's VMs and quit Monad: the new build installs and opens by itself.
The bridge lets the VM build the repository's code and stage it, so quitting Monad is the human
step that lets it in.

## Publish a release

```sh
scripts/release.sh package
```

From a clean checkout only (a release is what its tag says): it builds the Release configuration
as above, then writes `Monad.zip` (the app, zipped with `ditto --keepParent`) and
`Monad.zip.sha256` (as `shasum -a 256` writes it) to `~/Library/Developer/Monad-Release/dist`,
and prints the `gh release create` command. Tag the commit `v<version>` (the app's
`MARKETING_VERSION`) and push the tag first.

`scripts/install.sh` is what users run (README › Install). It finds the latest release by where
`github.com/<repository>/releases/latest` leads, downloads both files by that tag, and installs
only when the SHA-256 matches, the app is `dev.monad.Monad` and `codesign --verify --deep
--strict` holds; then it removes the quarantine flag. It also installs the build in a checkout's
`build/` folder (`--build` makes it there) or a file (`--from`). Its tests run with the C suites
(`CTests/test_install.sh`, with stand-ins for curl, ditto, codesign and launchctl, under dash and
bash). Unlike `release.sh install` it has no "Release this" job and no Enter to skip the wait for
MonadHost: it waits until Monad has quit and its VMs have stopped.

## Check which MonadHost the Release build uses

```sh
launchctl print gui/$(id -u)/dev.monad.host | grep -E 'program =|state =|pid ='
pgrep -lf MonadHost
```

`program` must be `/Applications/Monad.app/Contents/MacOS/MonadHost`, and the running MonadHost
processes must come from `/Applications` (Release) or Xcode's build folder (Debug, label
`dev.monad.debug.host`), never the other way round.

"Could not find service" means launchd has no MonadHost job, and Monad says the VM service is not
reachable. Monad loads it again by itself (at start, and while it cannot connect); to load it by
hand:

```sh
launchctl bootstrap gui/$(id -u) ~/.monad/launchd/dev.monad.host.plist
```

## The cycle

1. Work in a VM of the Release build; build and test the Debug build from Xcode (it has its own
   VMs in `~/.monad-debug`).
2. When Debug is good: commit, then `scripts/release.sh` (or "Release this" from the VM).
