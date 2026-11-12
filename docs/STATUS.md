# Monad: where things stand

Last updated: 2026-11-12. This is the state of the project, not its
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
`docs/GROUPS.md`, `docs/TABS.md`, `docs/DISTROS.md`, `docs/BUILDING.md`.

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
  processes using it, disks (full as df counts it), the biggest processes, the kernel's OOM kills, crashes, hangs and I/O
  errors, as they happen) to its own port every 15 s, not over ssh, kept in `health.log` across boots;
  MonadHost tells from it that the guest's kernel crashed, it ran out of memory or its disk is full,
  in the VM's log, `get_vm`, a failed boot's message, the VM's window and list, and its tabs once
  their session ended. Before that, like VMware, a VM low on memory (90% in use for two snapshots)
  or disk space (90% of `/`) is warned about, and the app posts a notification for each warning,
  each health problem and the Mac's own disk below 10 GB free, once until it clears (Settings ›
  Virtual Machines › Warn when a VM runs low; checked on the Mac through the Debug MCP). The app's
  and MonadHost's step-by-step log (Settings › Logs) is on unless the user turns it off.
- **Snapshots:** a VM's window (Snapshots page) and `take_snapshot`/`restore_snapshot`/
  `delete_snapshot` keep the VM's disks and settings as APFS clones, and a running VM's memory
  (Virtualization's saved state, while it is paused a moment), as a tree; restoring one taken
  running brings the VM back running where it was, its clock set to the Mac's. Checked on the Mac:
  a file in `/dev/shm` and a running process came back after a restore. A new VM is made from a
  snapshot (its Snapshots page, the New VM sheet's "Start from: a snapshot", `clone_vm`), and a
  stopped Linux VM is copied too: its disks cloned, with a new seed (host name, host keys), key
  and machine-id. Checked on the Mac: the copy got its own host name, machine-id and address.
- **Disks:** a VM takes up to 8 more disks (Resources › Disks, `add_disk`/`remove_disk`), sparse
  files in its folder attached by name at the next start; in a Linux VM Monad formats a blank one
  (ext4) and mounts it at `/mnt/<name>` (Guest/monad-disks.sh, never over a filesystem), and its
  health warns when one is 90% full. Removing a disk deletes it, only while the VM is shut down.
- **Pause:** a ready VM pauses and resumes (Virtualization's pause; its row, window, the canvas,
  `pause_vm`/`resume_vm`); its tabs' ssh and its ssh master are stopped with it, so their keepalive
  does not end the sessions, and its clock is set to the Mac's on resume (every ready VM's too
  when the Mac wakes: guest clocks stand still while it sleeps). Stop resumes it first.
  Checked on the Mac: paused 150 s and 60 s, sessions and the clock right after.
- **Network:** NAT, host-only and internal networks; a firewall per VM (rules by name or address,
  allowlist, monitor mode with live questions), a connection log, VM-to-VM traffic.
- **Terminal:** Nerd Font icons come from the bundled Symbols Nerd Font Mono (an icon before a
  blank cell spreads over both, Powerline separators fill their cell); a session that ends turns off the modes its program left on (mouse reports,
  bracketed paste, keypad, alternate screen); a picture pasted (⌘V) into a host shell is saved to
  a private folder on the Mac and its path typed; Monad's own emulator, tabs per VM, split panes (a split starts in the directory the shell in front reported, OSC 7) with contexts (⇧⌘←/→ cycle them and the VMs that are on), themes (Terminal.app
  built-ins, imports, transparency, blur, images), inline images (off per VM; `img` in every VM, Linux or
  macOS), OSC 52 within limits.
- **Tabs:** Monad's own tab strip (the system's has no place for groups) with tab groups as
  Firefox has them: a named, coloured label, a line under its tabs, a click to collapse it, tabs
  and groups moved by drag and drop, to a window of their own, or merged into one window. The
  windows, tabs and groups of last time open again when Monad starts, each shell in the directory
  it was in (`~/.monad/session.json`; a tab starts when first shown; ephemeral VMs are not kept);
  bash and zsh in a VM report their directory through `/etc/profile.d/monad.sh` (`docs/TABS.md`).
- **Windows:** a window is one size whatever its tabs (cell steps only apply to a window with one
  tab and one terminal); a VM's Log page follows a log written every second at little cost (only what was
  added is read and laid out); a VM's settings, Settings, Themes, the VM list and prompts open on the Space in front,
  a full-screen terminal's too.
- **Canvas:** VMs and networks drawn live, notes, labels, zones and arrows, docked terminals.
- **Agents:** an MCP server for agents on the Mac (`MonadHost --mcp`) and in VMs with a role
  (host commands, or orchestrator of child VMs), with approvals for anything that reaches the Mac
  and an audit log; a VM's console and health logs are read through it without ssh, and when the
  VM service cannot be reached every call says why (with launchd's view of it).
- **The VM service:** one copy of Monad per flavor (a newer copy asks older ones to quit, and MonadHost opens its own app
  by path to ask the user, never another copy); a copy
  that cannot reach MonadHost replaces launchd's job only while no VM runs, never ending a host
  that runs VMs (two Debug copies used to take turns, each turn powering every VM off).
  An outdated MonadHost kept for its running VMs is replaced once the last of them stops.
- **Updates:** the Release build checks GitHub's latest release once a day (Settings › Updates ›
  Check for updates, on by default) and on Monad › Check for Updates, and asks before it installs a
  newer one with install.sh's checks (SHA-256, bundle id, version, signature); `monad-update.sh`
  swaps it in once Monad has quit and opens it, while the VMs keep running. The Debug build never
  updates itself.

## Tests

| Suite | Where | What |
|---|---|---|
| `make -C CTests` | Linux or the Mac | The C backend (emulator, decoders, network stack, netd, guestd, the root step, install.sh, monad-update.sh), fuzzers (`fuzz_net`, `fuzz_vt`, `fuzz_decoders`), the guest scripts' shell tests |
| `MonadTests` | The Mac, Xcode, no VMs, no windows | About 1,200 Swift tests |
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
- **At the next release (1.1, the first that updates itself):** an update installed by Monad
  itself has not run on the Mac: 1.1 goes in with install.sh, and the release after it is the first
  one offered; its parts are tested (`AppUpdateTests`, `test_update.sh`). v1.0 was published by
  hand, so `release.yml` has not run yet.
- **To check by hand on the Mac** (`docs/SECURITY.md` › Checked on the Mac): an ad hoc tool signed
  with Monad's identifier is refused by MonadHost; macOS's App Management stops other apps changing
  `/Applications/Monad.app`; recovery's reader window never takes focus.
- **Limits:** a VM's disk cannot grow after it is made; distributions without systemd (Alpine)
  are not supported; Arch Linux has no official arm64 image; the App Sandbox is off (the app runs
  `ssh`); netd has no IPv6 (IPv6 rules cannot be saved).
- **Tab groups:** checked in the running Debug app with events sent through the debugger (a click
  selects, a tab dragged onto a grouped tab joins its group, a label collapses and drags its group,
  a name typed under the label, the layout under a see-through theme and in full screen, a session
  of grouped tabs opened again after a relaunch, bash in a Debian VM reporting its directory).
  The strip over a see-through theme was looked at in a capture of the real window. Still to try:
  a drag with a real mouse (the events sent took the same path).
- **Not yet tried on the Mac:** dragging a pane by its header, the pane menu's contexts and ⇧⌘←/→; the
  first boot of Fedora, openSUSE and AlmaLinux (Ubuntu 26.04 and Debian 13 were made and checked
  through the Debug MCP, health port included); the kernel console on hvc0 (`serial.log` from a
  VM's second boot), quiet and full, on each of them; Repair Disk end to end (a disk attached to a running VM over USB is
  tested against fakes only).
- **Later:** Developer ID signing and notarization; growing disks; a Homebrew profile for macOS
  guests.
