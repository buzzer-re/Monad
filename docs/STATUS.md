# Monad: where things stand

Last updated: 2026-10-25, before the first public release. This is the state of the project, not its
history: what Monad does, how it is built, how it is tested, and what is open. Update it with every
change that moves any of these.

## Goal

A macOS terminal where every tab is a shell inside a VM (Virtualization.framework, Apple silicon),
built for isolation first: a hostile guest is the primary threat (`docs/SECURITY.md`).

## Decisions

| Topic | Decision |
|---|---|
| Dependencies | None. Only Apple frameworks, libSystem, zlib and the system's `ssh`/`nc`; everything else is Monad's own code |
| Method | Test-driven: a failing test first, then the code; commit only when the whole suite is green |
| Distros | One data file per distribution (`Monad/Distros/*.distro.json`, `docs/DISTROS.md`); no code keyed on a distro's name |
| Networking | Monad's own stack (`monad-netd`, sandboxed C): switch, DHCP, DNS, NAT, firewall per VM |
| Shared folders | Opt-in per VM (the device exists only when on); `~/.monad` never shared; the home folder reaches a VM as its visible folders only |
| Signing | The first release is signed ad hoc and installed by `scripts/install.sh` (or by hand from the zip, with Open Anyway); Developer ID only if the release is well received |
| Security choices | Recorded in `docs/SECURITY.md` › Decisions (clipboard writes, VMs kept apart per network, DNS under the firewall, forwards into the Mac confirmed one by one, forwards open to other computers only when asked for, imported settings untrusted, images off per VM) |

## Architecture

```
Monad.app (UI, terminal emulator, themes) ── XPC ──▶ MonadHost (launchd agent: VMs, forwards,
                                                      agents, MCP, config)
                                                      └─ monad-netd (sandboxed network stack)
Linux guest: cloud-init + monad-sshd/agent on vsock (host-dialed only)
macOS guest: monad-guestd (vsock → sshd -i, agent), set up by one admin-prompted root step
```

VMs run in MonadHost, so quitting the app leaves them running. Details: `docs/SECURITY.md`
(processes and boundaries), `docs/MACOS.md`, `docs/AGENTS.md`, `docs/CANVAS.md`, `docs/CONFIG.md`,
`docs/GROUPS.md`, `docs/DISTROS.md`, `docs/BUILDING.md`.

## What Monad does

- **VMs:** a new Debian 13 VM boots the first time (its sshd.service is an alias of ssh.service,
  which one systemctl call masking every unit could not mask, so sshd kept TCP 22); Ubuntu, Debian, Fedora, openSUSE, AlmaLinux and user-added distributions (signed images
  verified with pinned keys); macOS guests (install from Apple or an IPSW, no Setup Assistant, SIP
  switchable through recovery, copies); Lima VMs booted in place or copied in; ephemeral Linux VMs.
- **At runtime:** the Mac's time zone, CPUs, memory (balloon), shared folders, port and socket forwards both ways (a
  VM port on any Mac address the user picks, the loopback by default),
  auto-forward of guest ports, stdio bridges, host commands, profiles (Agentic, Server, custom),
  start at login, groups with firewall tags, a log per VM that says why each stop happened (and, at
  the next start, that MonadHost ended while the VM ran); a Linux boot that fails says what the VM's
  disk shows (partition table, superblocks and their backups), and Repair Disk runs the distribution's own
  filesystem tools on it in a temporary VM (macOS 15 and later); its kernel console reaches `serial.log`,
  errors only unless Settings › Virtual Machines › Full boot messages is on, and the boot before is
  kept as `serial.log.1`; a Linux VM writes its health (memory, swap and its pressure, CPU and the
  processes using it, disks, the biggest processes, the kernel's OOM kills, crashes, hangs and I/O
  errors, as they happen) to its own port every 15 s, not over ssh, kept in `health.log` across boots;
  MonadHost tells from it that the guest's kernel crashed, it ran out of memory or its disk is full,
  in the VM's log, `get_vm`, a failed boot's message, the VM's window and list, and its tabs once
  their session ended. The app's and MonadHost's step-by-step log (Settings › Logs) is on unless the
  user turns it off.
- **Network:** NAT, host-only and internal networks; a firewall per VM (rules by name or address,
  allowlist, monitor mode with live questions), a connection log, VM-to-VM traffic.
- **Terminal:** a session that ends turns off the modes its program left on (mouse reports,
  bracketed paste, keypad, alternate screen); a picture pasted (⌘V) into a host shell is saved to
  a private folder on the Mac and its path typed; Monad's own emulator, tabs per VM, split panes (a split starts in the directory the shell in front reported, OSC 7) with contexts (⇧⌘←/→ cycle them and the VMs that are on), themes (Terminal.app
  built-ins, imports, transparency, blur, images), inline images (off per VM; `img` in every VM, Linux or
  macOS), OSC 52 within limits.
- **Windows:** a VM's Log page follows a log written every second at little cost (only what was
  added is read and laid out); a VM's settings, Settings, Themes, the VM list and prompts open on the Space in front,
  a full-screen terminal's too.
- **Canvas:** VMs and networks drawn live, notes, labels, zones and arrows, docked terminals.
- **Agents:** an MCP server for agents on the Mac (`MonadHost --mcp`) and in VMs with a role
  (host commands, or orchestrator of child VMs), with approvals for anything that reaches the Mac
  and an audit log; a VM's console and health logs are read through it without ssh, and when the
  VM service cannot be reached every call says why (with launchd's view of it).
- **The VM service:** one copy of Monad per flavor (a newer copy asks older ones to quit); a copy
  that cannot reach MonadHost replaces launchd's job only while no VM runs, never ending a host
  that runs VMs (two Debug copies used to take turns, each turn powering every VM off).
  An outdated MonadHost kept for its running VMs is replaced once the last of them stops.

## Tests

| Suite | Where | What |
|---|---|---|
| `make -C CTests` | Linux or the Mac | The C backend (emulator, decoders, network stack, netd, guestd, the root step, install.sh), fuzzers (`fuzz_net`, `fuzz_vt`, `fuzz_decoders`), the guest scripts' shell tests |
| `MonadTests` | The Mac, Xcode, no VMs, no windows | About 1,115 Swift tests |
| `MonadUITests` | The Mac, opens windows | 4; skipped in the scheme (they drive the screen) |
| `scripts/hygiene.sh [base]` | Linux or the Mac | No packages, JSON and shell scripts parse, no personal paths or whitespace errors in a change |

CI (`.github/workflows/ci.yml`) runs all of these but the UI tests on every pull request and push
to `main`: hygiene, `CTests` on Linux and macOS, then `MonadTests` and a Release build on Xcode 27
with warnings as errors. `fuzz.yml` runs each fuzzer for about ten minutes every night. `release.yml`
publishes a release (`Monad.zip` and its SHA-256) when a `v<version>` tag is pushed, after CI passes
on that commit.

Known environmental failures on the development Mac: two ICMP tests (no echo reply).
`TerminalSessionTests.testFollowingAVMThroughItsLifeStaysIdle` measures the whole test process's
CPU: it passes in the full suite now that tests stop the VMs they leave running (their agents
retried in a tight loop on the test clock), and says what is busy when it fails; CI still skips it
(hosted runners are not quiet).

Before each commit: the whole `MonadTests` target and `make -C CTests` (its exit status), zero
warnings, this file updated, and no private names or paths in what is committed.

## Open

- **Before the release tag:** one macOS VM made end to end on the Mac with the current build (the
  root step now runs the script's text through the admin prompt; no unit test can run that). The
  repository must be public for the install script's address and `releases/latest` to work.
- **At the first release:** `release.yml` has not run yet, and the zip installed by hand (Open
  Anyway) is untried on a clean Mac, MonadHost starting from it included.
- **To check by hand on the Mac** (`docs/SECURITY.md` › Checked on the Mac): an ad hoc tool signed
  with Monad's identifier is refused by MonadHost; macOS's App Management stops other apps changing
  `/Applications/Monad.app`; recovery's reader window never takes focus.
- **Limits:** a VM's disk cannot grow after it is made; distributions without systemd (Alpine)
  are not supported; Arch Linux has no official arm64 image; the App Sandbox is off (the app runs
  `ssh`); netd has no IPv6 (IPv6 rules cannot be saved).
- **Not yet tried on the Mac:** dragging a pane by its header, the pane menu's contexts and ⇧⌘←/→; the
  first boot of Fedora, openSUSE and AlmaLinux (Ubuntu 26.04 and Debian 13 were made and checked
  through the Debug MCP, health port included); the kernel console on hvc0 (`serial.log` from a
  VM's second boot), quiet and full, on each of them; Repair Disk end to end (a disk attached to a running VM over USB is
  tested against fakes only).
- **Later:** Developer ID signing and notarization; growing disks; a Homebrew profile for macOS
  guests.
