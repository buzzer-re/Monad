# Working on Monad

This is the guide for coding agents (and people) changing Monad: how the code is laid out, how the pieces talk to each other, how to build and test, and the rules the project keeps. It assumes you know nothing about Monad yet.

[docs/AGENTS.md](docs/AGENTS.md) is something else: it documents Monad's own MCP server, the feature that lets agents drive Monad. When this file says "agent" it means you, the one changing the code; when it says "MCP" or "an agent in a VM" it means that feature.

## Start here

Monad is a macOS terminal where every tab is a shell inside a virtual machine, on Apple's Virtualization framework. The VMs are Linux or macOS guests, and the guest is treated as hostile.

Read these, in this order, before your first change:

1. [README.md](README.md): what Monad does, from a user's side.
2. This file: how the code is put together.
3. [docs/STATUS.md](docs/STATUS.md): where things stand, what is open, which tests fail on purpose.
4. [docs/SECURITY.md](docs/SECURITY.md): the threat model and every boundary, with the file that enforces it and the test that checks it. Read it before touching anything between a VM and the Mac.
5. The doc for the area you are changing (see [Docs](#docs)).

Then find the code with the [code map](#code-map), and the tests next to it in `MonadTests/<Thing>Tests.swift` or `CTests/test_<thing>.*`. Most source files start with a comment that says what the file is for and why; read it first.

## Words used here

| Word | Meaning |
|---|---|
| VM, instance | One virtual machine: a folder under `~/.monad/instances/<name>/` with its settings (`instance.json`), disk and keys |
| Monad.app, the app | The windows: terminal tabs, the Virtual Machines list, settings, the canvas. It never runs a VM itself |
| MonadHost, the host | The launchd agent inside the app bundle that runs the VMs. The app talks to it over XPC |
| monad-netd, netd | The network process: a sandboxed child of MonadHost that switches every VM's Ethernet frames |
| monad-guestd | Inside a macOS guest only: serves sshd and the agent on vsock, since macOS's launchd cannot listen there |
| The agent, monad-agent | A POSIX sh script in the guest that reports which ports the VM listens on (and, on macOS, password prompts) |
| Flavor | Debug or Release: two copies of Monad that share nothing (names, MonadHost, data folder) |
| Distro | A distribution described by one JSON file (`Monad/Distros/<id>.distro.json`) |
| Profile | Software set up in a VM on first boot, also a JSON file (`Monad/Profiles/<id>.profile.json`) |
| Forward | A port or unix socket carried by the VM's ssh connection: guest to Mac (often automatic), or Mac to guest (asked for) |
| Share | A Mac folder given to the VM over virtio-fs, read-only unless the user says otherwise |
| Bridge | A Mac command run for each connection to a port or socket in the VM (for example `xcrun mcpbridge` for Xcode's MCP) |
| Host command | A Mac program a VM's agents may run as a tool, with a pattern for every value the VM may pass |
| Role | What an MCP server inside a VM may do: `hostCommands`, or `orchestrator` (create and run VMs of its own) |
| Approval, grant | A risky MCP call waits for the user's answer (an approval); "always allow" is kept as a grant |
| Group, firewall tag | A group in the VM list also works as a firewall tag: a rule list every VM in it carries |
| Context, pane | A pane in a terminal window holds several contexts (VM sessions); one is visible at a time |

## Architecture

### Processes and the lines between them

```
 Monad.app ──XPC (HostProtocol JSON)──▶ MonadHost (launchd agent, starts on demand, exits when idle)
   │  terminal tabs:                     ├─ one VZVirtualMachine per running VM (MNDVirtualMachine.m)
   │  /usr/bin/ssh in a pty,             ├─ vsock: the host dials the guest (22 sshd, 1024 agent), never listens
   │  ProxyCommand nc -U ssh.sock ───────┤  ssh.sock is a unix socket bridged to the guest's vsock 22
   │                                     ├─ an ssh ControlMaster per VM (ctl.sock): forwards, bridges, uploads
   │                                     ├─ monad-netd (MonadHost --netd), sandboxed, network only
   │                                     │     every VM NIC is a datagram socket; NAT, DHCP, DNS, firewall
   │                                     └─ MCP: the stdio relay (MonadHost --mcp) and an HTTP endpoint per VM
   └─ an agent on the Mac runs `MonadHost --mcp`, which relays JSON-RPC to the running MonadHost
```

- The app and MonadHost are separate processes so that VMs keep running when the app quits. MonadHost is started by launchd on the first XPC connection and exits after a grace period with nothing to do (`HostLifetime.swift`).
- Every message between them is JSON defined in one place, `Monad/Host/HostProtocol.swift`: a `HostRequest` with an `op` (`create`, `start`, `update`, `attach`, `mcp`, …), a `HostResponse`, and `HostEvent`s the host pushes (a VM changed, approvals, canvas notes). `HostProtocol.version` is bumped on incompatible changes. XPC carries the bytes and pins the peer's code signature (`HostXPC.swift`).
- MonadHost's side is `HostService.swift`, which owns the `VMManager`. The app's side is `HostClient.swift`, which mirrors every VM as a `RemoteVM` and reconnects if the host goes away.
- The same MonadHost binary has four jobs, chosen by its first argument (`MonadHost/main.swift`): the VM service (no argument), `--netd`, `--guestd` (copied into macOS guests) and `--mcp`.

### What happens when a tab opens

1. The app picks the VM (`TabRouting.swift`) and asks the host to `attach`. With no VM yet, `ensureDefault` makes `default` from the Ubuntu cloud image.
2. `VMManager` and `VMInstance` (MonadHost) start it. The first time, `ImagePipeline` downloads the image, checks it against the distro's signed checksums (`ChecksumFile`, `OpenPGP`), converts it to a raw disk (qcow2, xz, tar decoders in `Monad/Backend`) and caches it; the VM's `disk.raw` is an APFS clone of that base. `CloudInit` writes the `cidata.iso` seed (the user, the VM's ssh key, Monad's units and scripts).
3. `VZMachine` (Swift) and `MNDVirtualMachine` (Objective-C) build the Virtualization configuration and boot. The VM's NIC goes to netd through `NetdSupervisor`.
4. `VMInstance` moves `stopped → starting → booting → ready`. It is `ready` only once sshd answers over vsock and the isolation check passes (nothing listens on TCP 22). Any error, timeout or failed check ends in `failed`, powered off.
5. Once ready, the host pushes the guest components again (`CloudInit.guestInstallScript`, so the agent always matches this Monad), connects to the agent on vsock 1024 (`AgentClient`, `AgentProtocol`) and starts the ssh ControlMaster. `ForwardManager` keeps the forwards in line with the config and with the ports the agent reports.
6. The tab (`TerminalSessionViewController`) runs `/usr/bin/ssh -F <instance>/ssh.config` on a pty (`PTYSession`). Bytes go into `TerminalModel`, which owns the C emulator (`mnd_vt`), and `MonadTerminalView` draws the screen.

### Where things live on disk

Under `~/.monad` (Release) or `~/.monad-debug` (Debug), see `Monad/Support/Paths.swift`:

| Path | What |
|---|---|
| `_cache/images/` | Downloaded cloud images and the converted bases VMs are cloned from |
| `instances/<name>/` | One VM: `instance.json`, `disk.raw`, `cidata.iso`, `id_ed25519`, `ssh.config`, `ssh.sock`, `ctl.sock`, `serial.log`, `vm.log`, `running` (while its machine runs; one left behind means MonadHost ended without seeing it stop), and for macOS guests the platform files (`aux.img`, `hardware-model.bin`, …) |
| `instances/order.json` | The VMs' order; the default VM is chosen there |
| `networks/`, `firewall-tags/` | Monad networks and firewall tags, one JSON file each |
| `distros/`, `profiles/`, `themes/` | What the user added, next to the ones in the app bundle |
| `logs/` | Settings › Logs, when debug logging is on |

`instance.json` is `InstanceConfig` (versioned; old versions are migrated on load). Never write it from the app: the app sends an `update` and MonadHost validates and saves it.

### Threading

App and host state lives on the main actor (`VMInstance`, `VMManager`, `HostService` and the UI are `@MainActor`). Slow work (ssh, image downloads, process runs through `ProcessRunner`) runs off it and hops back. The C emulator is guarded by its own lock (`mnd_vt_internal.h`); a tab's pty I/O runs on a private serial queue (`PTYSession`). netd is single-threaded on its event loop (`mnd_loop.c`, kqueue on macOS, epoll on Linux).

## Code map

| Path | What is there | Start with |
|---|---|---|
| `Monad/App` | AppKit and SwiftUI windows: the Virtual Machines list, a VM's window, Settings, the canvas, agent approvals, the New VM sheet | `AppDelegate.swift`, `VMManagerView.swift`, `VMDetailView.swift` |
| `Monad/Terminal` | Tabs, panes and contexts, the terminal view, fonts, inline images, the pty | `TerminalSessionViewController.swift`, `TerminalModel.swift`, `PaneTree.swift` |
| `Monad/Theme`, `Monad/Themes` | Theme model, import from Terminal.app and iTerm2, built-in themes as JSON | `Theme.swift` |
| `Monad/Host` | The app ↔ MonadHost protocol, transport and both ends | `HostProtocol.swift`, `HostService.swift`, `HostClient.swift` |
| `Monad/VM` | One VM's life: config, state machine, provisioning, ssh, forwards, shares, bridges, the agent client, macOS install, setup and recovery | `VMInstance.swift`, `VMManager.swift`, `InstanceConfig.swift`, `CloudInit.swift` |
| `Monad/Distro`, `Monad/Distros` | Distros as data, the image pipeline, checksum files, the OpenPGP verifier; the JSON files and their keys | `DistroConfig.swift`, `ImagePipeline.swift` |
| `Monad/Profile`, `Monad/Profiles` | Profiles as data, turned into an idempotent sh script run over ssh | `ProfileConfig.swift`, `ProfileScript.swift` |
| `Monad/Network` | Firewall rules and tags, Monad networks, the connection log, MonadHost's side of netd | `Firewall.swift`, `NetdSupervisor.swift` |
| `Monad/Agents` | The MCP server: protocol, stdio and HTTP transports, tools, who may call what, host commands | `MonadTools.swift`, `MCPAccess.swift`, `HostCommand.swift` |
| `Monad/Canvas` | The canvas model (networks, VMs, edges) and what is written on it | `CanvasModel.swift`, `CanvasNotes.swift` |
| `Monad/Lima` | Finding Lima VMs to boot in place | `LimaInstances.swift` |
| `Monad/Support` | Paths, flavors, logging, process running, and the seams tests replace | `Seams.swift`, `Paths.swift`, `Flavor.swift` |
| `Monad/Transfer` | Copying files into a VM over its ssh master (paste and drop) | `FileUploader.swift` |
| `Monad/Backend` | C and Objective-C, portable where it can be: the VM wrapper, unix socket bridge, ISO writer, pty, disk helpers, decoders | `MNDVirtualMachine.h`, `Monad-Bridging-Header.h` |
| `Monad/Backend/vt` | The terminal emulator: parser, screen and scrollback, input encoding, selection, inline images | `mnd_vt.h` |
| `Monad/Backend/net` | The network stack and netd: frames, switch, gateway (ARP, DHCP, ICMP), DNS forwarder, NAT and TCP, firewall, connection log, control channel, event loop | `mnd_net.h`, `mnd_netd.h` |
| `Monad/Guest` | Scripts that run inside VMs: the Linux and macOS agents, the guest's setup report, SELinux loading, macOS first boot and setup | `monad-agent.sh` |
| `MonadHost` | MonadHost's entry point (it compiles most of `Monad/` too) | `main.swift` |
| `MonadTests` | About 1,100 Swift tests, one file per area, with fakes | `Support/Fakes.swift` |
| `CTests` | C tests, fuzzers and shell script tests; fixtures are generated by Python scripts at build time | `Makefile` |
| `scripts` | `install.sh` (what users run), `release.sh` (Release builds and packages), `hygiene.sh` (CI's first checks) | |
| `Tools`, `Design` | Generators: the Unicode width table, the app icon | |

The Xcode project uses folder-synchronized groups: a file added under `Monad/` is in both the app and MonadHost automatically. App-only files (UI) are listed as exceptions for MonadHost in the project; add a new UI file there if MonadHost can't compile it. Resources (JSON, scripts) are bundled by their file name, flat, into `Contents/Resources`.

C and Objective-C reach Swift through `Monad/Backend/Monad-Bridging-Header.h`.

## Tests

### How the Swift tests avoid real VMs

Code that touches the outside world goes through protocols in `Monad/Support/Seams.swift`, gathered in `VMEnvironment`:

| Seam | Live | Fake (`MonadTests/Support/Fakes.swift`) |
|---|---|---|
| `CommandRunning` (ssh, launchctl, lsof…) | `SystemCommandRunner` | `FakeCommandRunner`: scripted answers, records every call |
| `VirtualMachineFactory`, `VirtualMachineControlling` | `VZMachineFactory`, `VZMachine` | `FakeMachineFactory`, `FakeVM`, `FakeRecoveryVM` |
| `MonadClock` | `SystemClock` | `TestClock`: time moves only when the test says |
| `BaseImageProviding` | `ImagePipeline` | `FakeImageProvider` |
| `NetworkAttaching` | `NetdSupervisor` | `FakeNetworkAttacher` |
| `MacInstalling`, `MacSetupAuthorizing` | `VZMacInstaller`; `HostService`, which asks the app | `FakeMacInstaller`, `FakeMacSetup` |

`TempDir` gives a test its own folder, and `ManagerFixture` wires a `VMManager` to fakes. New code that would reach the outside world needs a seam like these, not a real call in the test.

Conventions:

- One test file per area, named after the type: `VMInstance` → `VMLifecycleTests`, `HostProtocol` → `HostProtocolTests` and so on. Look for the existing file before adding one.
- Test names say the behavior in words: `testTheHostNeverListensOnVsock`, `testAGoneAgentCostsNoCPUWhileTheAppIsBusy`.
- Messages between processes are golden-tested (`HostProtocolTests`); a change to `HostProtocol` updates the goldens on purpose.
- Security boundaries have their own tests, listed in `docs/SECURITY.md`; `InvariantTests` holds the ones that must never change.
- Guest input is tested hostile: oversized, malformed, binary, too many lines (`AgentProtocolTests`, `GuestReportTests`, `ParserFuzzTests`).

### The C and shell tests

`CTests/Makefile` builds every `test_*.c` and fuzzer under ASan and UBSan with `-Werror` and runs them, then runs each shell script's tests under `sh` and `bash`. The network stack's tests drive `mnd_net` through a fake host (`net_test_host.h`, `net_test_gw.h`), so they run on Linux too. Fixtures (tar, xz, qcow2) come from `gen_*_fixtures.py` at build time. The fuzzers (`fuzz_net`, `fuzz_vt`, `fuzz_decoders`) check invariants on random input; a short run is part of `make`, longer ones are `make fuzz`.

## Build and test

Everything runs on an Apple silicon Mac with Xcode 27. The C and shell tests also run on Linux (gcc, zlib headers, python3).

```sh
make -C CTests                      # C core under ASan/UBSan, short fuzz runs, shell script tests
make -C CTests fuzz FUZZ_ITERS=200000 [FUZZ_SEED=n]   # longer fuzzing
scripts/hygiene.sh origin/main      # CI's first checks on your change

xcodebuild -project Monad.xcodeproj -scheme Monad -destination 'platform=macOS' test
xcodebuild -project Monad.xcodeproj -scheme Monad -destination 'platform=macOS' -configuration Release build
```

`make` stops at the first failure. Check its exit status, and never pipe it into `grep` or `tail` without `set -o pipefail`, or a red run looks green. In Xcode, open `Monad.xcodeproj`, pick the Monad scheme and run the `MonadTests` target. Never run `MonadUITests`: they take over the screen of whoever runs them, and the scheme skips them.

A few tests depend on the machine they run on, and CI skips them (see `.github/workflows/ci.yml`): two ICMP tests that need an echo reply from the network, and `TerminalSessionTests.testFollowingAVMThroughItsLifeStaysIdle`, which measures the test process's CPU and only passes on a quiet Mac. Run them locally when you touch netd or the terminal session.

### Two builds on one Mac

The Debug build (what Xcode builds) is named Monad Debug, uses MonadHost `dev.monad.debug.host` and keeps its VMs in `~/.monad-debug`; the Release build lives in `/Applications` and uses `~/.monad`. They share nothing, so building and testing Debug is always safe, even while you work inside a Release VM. Never build the Release configuration over `/Applications/Monad.app` by hand while it runs VMs: use `scripts/release.sh`, which waits until Monad and its VMs have stopped ([docs/BUILDING.md](docs/BUILDING.md)).

## Recipes

These are the usual paths through the code. Each starts with a failing test.

### A new setting on a VM

1. `Monad/VM/InstanceConfig.swift`: the field, its default, decoding of files that don't have it, and its validation. Tests: `ConfigV2Tests`, `ConfigChangeTests`.
2. Decide when it takes effect. Live changes are applied by `VMInstance` when MonadHost gets the `update`; others wait for a restart, and `VMSettingsDraft` shows that to the user. Tests: `VMSettingsDraftTests`, `HostServiceTests`.
3. The VM's window: the page in `VMDetailView.swift`, editing through `VMSettingsDraft`.
4. `VMConfigFile.swift` if it belongs in the exported settings (`VMConfigFileTests`), and the MCP tools if agents should see or change it.
5. `docs/CONFIG.md` describes the file.

### A new MCP tool

1. `Monad/Agents/MonadTools.swift`: an `MCPTool` with its name, description, input schema and `risk` (`normal`, or `risky` when it reaches into the Mac or can't be undone). It must go through the same `HostService` path the window uses, so every check applies.
2. `Monad/Agents/MCPAccess.swift`: who may call it (an agent on the Mac, a VM with a role) and whether it asks first.
3. Tests: `MonadToolsTests`, `MCPAccessTests`. Then the tool list in `docs/AGENTS.md`.

### A new message between the app and MonadHost

1. `HostProtocol.swift`: a new `HostRequest.Op` (and fields) or `HostEvent`. Keep old builds working: new fields are optional, and an incompatible change bumps `HostProtocol.version`.
2. `HostService.swift` answers it; `HostClient.swift` sends it and updates the mirror.
3. Tests: `HostProtocolTests` (goldens), `HostServiceTests`, `HostClientTests`.

### A new distribution

1. `Monad/Distros/<id>.distro.json`, and its signing key in `Monad/Distros/keys/` when the distro signs its checksums. `docs/DISTROS.md` describes every field.
2. No Swift change should be needed. If one seems needed, add a generic field to `DistroConfig` that the file sets, never an `if distro == …`.
3. Tests: `DistroTests` loads and validates every bundled file.

### A change to a guest script

1. `Monad/Guest/<name>.sh` is POSIX `sh` (plus `awk` and `sed`) and must run unchanged on every supported distro, under dash and bash. The macOS scripts get BSD tools.
2. Its tests are `CTests/test_<name>.sh`, run under `sh` and `bash` from `CTests/Makefile`, with stand-ins for system tools.
3. New scripts are bundled by file name; if VMs need it, `CloudInit` (first boot) and `CloudInit.guestInstallScript` (every boot) install it. Mind the resource naming trap below.

### C code (a decoder, the emulator, the network stack)

1. `Monad/Backend/mnd_<thing>.c` and `.h`, plain C11 with no platform calls where it can be, so it is tested on Linux too.
2. Expose it to Swift in `Monad-Bridging-Header.h`.
3. `CTests/test_<thing>.c`, a rule in `CTests/Makefile` and the name in its `TESTS` list. Anything that parses guest or downloaded input also gets fuzz coverage.

### A change to netd

The core (`Monad/Backend/net/mnd_net*.c`) never touches the OS: time and frames go through a host interface, so it is tested in `CTests` with a fake host. Real sockets are `mnd_netd.c`; MonadHost configures it over the control channel (`mnd_netd_ctl.c`, one command per line) from `NetdSupervisor.swift`. A change usually touches all three, with tests in `CTests/test_net_*.c`, `test_netd_*.c` and `NetdSupervisorTests`.

## Rules

1. Tests first. Write the test that shows the bug or the missing behavior, watch it fail, then make it pass. A fix without a test that failed before it is not done.
2. No third-party code. No Swift packages, CocoaPods, vendored libraries or copied code. Monad uses Apple's frameworks, libSystem, zlib and the system `ssh`, and writes everything else itself. CI fails a change that adds a package.
3. Before each commit: the whole `MonadTests` target passes, `make -C CTests` exits 0, the build has zero warnings (C warnings are already errors; CI also treats Swift warnings as errors), and `docs/STATUS.md` still describes where things stand. STATUS is a short summary of the current state, not a log of changes.
4. Distributions and profiles are data. Never key behavior on a distribution's name; what differs between guests comes from the distro file or from `GuestOS` (Linux or macOS).
5. The guest is hostile. Anything a VM sends (frames, vsock traffic, agent messages, terminal escapes, file contents in shared folders, console output) is untrusted input: bound it, validate it, and test the hostile case. The Mac dials the guest over vsock and never listens; sshd in the guest never listens on a network; netd stays sandboxed; anything that reaches into the Mac asks the user. A change that moves one of these lines needs tests and an update to `docs/SECURITY.md`.
6. No personal data in the repository. No real names, account names, home paths (`/Users/<name>`), emails or hostnames in code, fixtures, tests or docs; use placeholders like `/Users/dev`. CI checks the lines a change adds.
7. Match the code around you: its naming, its comment density and its idioms. Swift is in Swift 5 mode; C is `gnu11` with `-Wall -Wextra -Wshadow -Werror`. Comments say why, not what, and a new file starts with a comment saying what it is for.
8. Write docs and interface text in plain, concrete sentences, in sentence case, saying what the thing does. No marketing words.

## Traps already found

- Don't name a bundled resource `<name>-macos.<ext>` (or `~ipad`, `~iphone`, `-iphoneos`) when `<name>.<ext>` exists: on macOS, `Bundle` returns the variant in its place. That once shipped the macOS guest agent to every Linux VM. `CloudInitTests.testNoBundledResourceStandsInForAnother` guards it.
- Guest scripts must work under dash and bash. macOS guests have BSD tools (`netstat -anv`, `stat -f`), Linux guests GNU ones; each agent has its own script and tests.
- The app must not write `instance.json` or anything else under `instances/`: MonadHost owns them. The app asks through `HostClient`.
- Xcode's snippet and preview tools start copies of Monad.app. Check for leftover Monad processes after using them.
- Each build's app only talks to its own MonadHost, pinned by signing identifier (`dev.monad.MonadHost` or `dev.monad.MonadHost.debug`). `FlavorTests` must pass after any change to names, bundle ids or signing.

## Committing

- One change per commit, with a short summary line in plain words and a body that says why when it isn't obvious. Look at `git log` for the style.
- Agents: end the message with a `Co-Authored-By:` trailer naming the model, and nothing else (no session links).
- The maintainer's commits use UTC dates (`GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` with `+0000`), so no timezone is recorded.
- Don't push, tag or open pull requests unless you were asked to.

## Continuous integration

Every pull request and every push to `main` runs `.github/workflows/ci.yml`:

- Hygiene (`scripts/hygiene.sh`): no packages, the JSON files parse, the shell scripts parse, and the added lines carry no personal paths, conflict markers or whitespace errors. It warns, without failing, when code changes come without tests or without a STATUS update.
- C and shell tests on Linux (gcc) and on macOS (Apple clang).
- `MonadTests` in Debug and a Release build, on Xcode 27, with warnings as errors.

`.github/workflows/fuzz.yml` runs the three fuzzers every night for about ten minutes each with a random seed, which it prints so a failure can be replayed with `FUZZ_SEED`.

`.github/workflows/release.yml` publishes a release when the maintainer pushes a `v<version>` tag: CI again on that commit, then `scripts/release.sh package` and a GitHub release with `Monad.zip` and its SHA-256 ([docs/BUILDING.md](docs/BUILDING.md) › Publish a release).

## Docs

| Doc | About |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | Where things stand, the test suites, what is open |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, boundaries, what is enforced where and tested how, what Monad does not promise |
| [docs/BUILDING.md](docs/BUILDING.md) | Debug and Release side by side, `release.sh`, publishing a release |
| [docs/MACOS.md](docs/MACOS.md) | macOS guests: install, setup with no setup screens, shares, SIP through recovery |
| [docs/AGENTS.md](docs/AGENTS.md) | Monad's MCP server: tools, roles, host commands, the audit log |
| [docs/DISTROS.md](docs/DISTROS.md) | The distro file, adding a distribution, debugging a boot |
| [docs/CONFIG.md](docs/CONFIG.md) | A VM's settings file |
| [docs/CANVAS.md](docs/CANVAS.md) | The canvas: model, persistence, interactions, notes |
| [docs/GROUPS.md](docs/GROUPS.md) | Groups and firewall tags |
