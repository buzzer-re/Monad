# Monad security model

What Monad protects, from whom, where each guarantee is enforced and tested, and what it does not
promise. Two internal security reviews are behind it: the first one's findings (F-01 to F-19,
named in the code and below) and the second's, before the first public release, are all fixed or
stated here as decisions.

## Who the attacker is

- **A hostile guest** (primary): anything running as root inside a VM, including its kernel. It
  controls every byte the VM sends out: network frames, vsock traffic, ssh server answers, console
  output, terminal escape sequences, agent messages, and the files it writes to writable shared
  folders. Its goals: run code or read data on the Mac, reach the Mac's loopback or local network,
  reach another VM, or reach anything the user did not choose to share.
- **The network** while images and profiles are downloaded.
- **Other processes of the same macOS user**, only where Monad holds something they do not have
  (see "Same-user processes" below).

Out of scope: root on the Mac, physical access, and the user's own deliberate choices (a writable
share of a folder, a remote forward, "Reach this Mac and its local network").

## Processes and boundaries

```
 Monad.app (UI)  ──XPC, peer code requirement──▶  MonadHost (launchd agent)
                                                    ├─ Virtualization.framework, one VM per VM
                                                    ├─ vsock: the host dials, it never listens
                                                    ├─ /usr/bin/ssh over vsock (options on the
                                                    │  command line, never ssh.config)
                                                    └─ monad-netd (sandboxed, network only)
                                                         every VM's Ethernet frames
```

| Boundary | Enforced by | Tested by |
|---|---|---|
| Only Monad's own processes drive MonadHost | XPC code requirement on each client (`HostXPCSecurity.clientRequirement`, read at each connection): the team and identifiers for team-signed builds; for ad hoc ones, each identifier with the code hash of the Monad.app installed beside MonadHost (or MonadHost itself, for `--mcp`). The app checks MonadHost by identifier only (see Same-user processes) | `XPCTransportTests` (`testAdHocClientsArePinnedToTheInstalledBinaries`: right identifier, other hash refused; foreign identifier and ad hoc peer against a team requirement refused) |
| A guest cannot connect to the host over vsock | No `VZVirtioSocketListener` exists; the host dials ports 22 and 1024 | `InvariantTests.testTheHostNeverListensOnVsock` |
| The guest's network sshd is off; ssh reaches the guest only over vsock | Cloud-init masks the distro's ssh units, the isolation check fails the boot closed if TCP 22 listens or the listening ports cannot be read (it needs no sudo). A Lima VM's masks hold for one boot (`--runtime`, set again at every Monad boot), so Lima keeps its sshd | `CloudInitTests`, `VMLifecycleTests` |
| A compromised netd cannot touch files, start processes, listen, or use unix sockets | `sandbox_init` profile in `mnd_netd_main.c` | `NetdProcessTests` (`--netd-sandbox-check`, with a control for the unix socket) |
| A VM reaches neither the Mac nor its LAN unless allowed | netd's firewall: private and carrier-grade ranges and the Mac's own networks (up to 16, /32 included) are "LAN"; a rule by name never opens them, an address range the user typed may | `test_net_fw.c`, `NetdSupervisorTests` |
| VMs do not reach each other unless their network says so | netd's switch drops VM-to-VM frames on networks with "VMs can reach each other" off (default for NAT and host-only; on for internal) | `test_net_gateway.c`, `NetworkDefinitionTests` |
| A confined VM cannot send data out through DNS | Lookups follow the firewall in allowlist and monitor mode (REFUSED or asked by name); host-only networks forward no lookups unless they say so | `test_net_dnsfwd.c`, `NetdSupervisorTests` |
| Guest-chosen names cannot fake the firewall prompt | Only plain names (letters, digits, `-`, `_`) are learned or shown | `test_net_dnsfwd.c`, `test_netd_ctl.c`, `FirewallTests` |
| Rules by name hold however many names point at an address, and one VM's lookups do not change another's decisions | Names are per VM, every name of an address is matched, a full table evicts from the VM holding the most | `test_net_fw.c` |
| Auto-forward cannot flood the Mac or take a Mac service's port | At most 32 auto-forwards per VM, guest port events at most once a second, ports a Mac program listens on are skipped, and the guest ports of bridges and forwards into the Mac are never forwarded back (a bridge would otherwise be a TCP port any local user reaches) | `ForwardManagerTests`, `ForwardPlanTests` |
| Terminal output from a guest cannot run code or fake the UI | Bounded OSC 8 links, titles without C0/C1/bidirectional controls, replies that never echo guest-chosen text, clipboard writes capped | `test_vt.c`, `fuzz_vt.c`, `TerminalModelTests`, `ClipboardPolicyTests` |
| Images a guest sends are only decoded when its VM allows them | Inline images (OSC 1337) are off for every VM unless its settings turn them on, never from the boot console, never in host shells. The terminal core reads only the file's header (PNG, JPEG or GIF; at most 4 MB, 8192 pixels a side, 32 M pixels), never decodes it, and lays it out over at most 255 x 255 cells; ImageIO then decodes only a complete file of that same format, off the main thread, at most the size its cells show (4096 pixels), and a tab keeps at most 64. The text area's size in pixels (CSI 14 t, 16 t) is told only while images are on | `test_vt_images.c`, `fuzz_vt.c`, `TerminalImagesTests`, `TerminalModelTests`, `VMConfigFileTests` |
| Keystrokes, pastes and clipboard writes involve only the context in front | In a window of split panes only the focused pane's visible context is first responder, hidden contexts leave the view hierarchy, and OSC 52 writes need the focused context in the key window | `PaneLayoutTests` (input goes to the visible context after every change), `ClipboardPolicyTests` |
| Paste and typed text cannot become ssh commands | `EscapeChar none` | `CloudInitTests` |
| Settings files cannot steer MonadHost into running commands other than a bridge's | Every `instance.json` field validated on create, update and load; a bad file is listed but never started. A stdio bridge (Phase 12) is the one setting that names a Mac command: its program by full path and plain arguments, run without a shell | `ConfigV2Tests`, `HostServiceTests`, `ProvisioningFlowTests`, `CommandBridgeTests` |
| Shared folders stay what the user chose | MonadHost resolves links and stores where a share really leads; `~/.monad` is never shared, a writable share may not hold it, and a folder above the home folder (`/`, `/Users`) is refused. The home folder itself (read-only, with the user's word) reaches the VM as its visible folders only: no dot folder (`~/.monad`, `~/.ssh`, `~/.aws`), no `~/Library`, no loose files, decided on the Mac so root in the guest cannot get around it. Outside the home folder, `~/.ssh` and `~/Library` need the user's word. A Lima VM's own folders (Lima's `~` mount too) go through the same rules, with one confirmation for those that need it | `SharePolicyTests`, `HostServiceTests`, `LimaListTests` |
| Agents reach Monad only as allowed | MCP calls from the Mac come through `MonadHost --mcp` over the XPC peer check; a VM reaches only its own endpoint (a 0600 socket per VM, forwarded to its loopback) with a token only it has, no `Origin`; `MCPAccess.decide` allows, asks or refuses each call (risky tools ask from the Mac; a VM without a role gets nothing; host-commands VMs only their commands; an orchestrator freely only on its children); questions time out as refusals; every call is audited | `MCPAccessTests`, `MCPHTTPTests`, `MCPProtocolTests`, `HostServiceTests`, `VMLifecycleTests` |
| A host command runs only what the user defined | The VM never names a program; values are parsed by Monad (no shell) and matched against anchored patterns before anything runs; the program runs in a folder the VM shares, in its own process group, with a time limit, one at a time | `HostCommandTests`, `HostCommandServerTests` |
| A settings file cannot bring Mac access in unnoticed | Shares, bridges, host commands, forwards into the Mac or open to other computers, LAN access, images and an agent role are set aside on import and confirmed on edit | `VMConfigFileTests` |
| Images are what the distro published | OpenPGP signatures with pinned keys where the distro signs, never an older signed checksum file than one seen before, unsigned checksums only from their own site over HTTPS, then the image's digest | `OpenPGPTests`, `ImagePipelineTests`, `ParserFuzzTests` |
| A VM's disk cannot steer MonadHost when Monad reads it | `mnd_diskcheck` reads fixed places only (the GPT and its table, superblocks; 4 KiB at a time), bounds every count and offset it reads, reports printable text only, and reads a VM's disk only once the VM is off, read only | `test_diskcheck.c`, `fuzz_decoders.c`, `DiskCheckTests`, `VMLifecycleTests` |
| Repair Disk opens a VM's disk only inside another VM | The disk goes to a temporary ephemeral VM of the same distribution (no shared folders, forwards or role), as a USB disk once that VM runs, never at boot (two disks of one cloud image share labels and UUIDs). Only commands Monad builds run there, on a device name it checked; the VM being repaired cannot start or be deleted meanwhile; a clone of the disk is kept first | `DiskRepairTests`, `DeviceModelTests` (only that VM has a USB controller) |

The decoders (`mnd_qcow2`, `mnd_xz`, `mnd_tar`) only see verified images today; `fuzz_decoders.c`
keeps them safe if that ever changes. `fuzz_net.c` drives the whole network core with invariants.

## Distributions the user adds (2026-10-12)

A distribution the user adds (`~/.monad/distros`, Settings › Distributions) is the user's choice,
and Monad does not stand in its way: it may be unsigned and its addresses may be plain http (a
mirror on their own network). Monad follows best practice for its own distributions (https only,
pinned signing keys, enforced by `DistroConfig.validate`) and says what each choice costs in the
form. Because macOS refuses plain http unless an app allows it, Monad's Info.plist allows it
(`Config/AppTransport-Info.plist`, `NSAllowsArbitraryLoads`); image downloads are the only URLs
Monad opens, and which addresses are allowed stays Monad's own rule. An unsigned distro on plain
http has no integrity check against anyone on the path: the form says so before it is saved.

## Profiles

A profile runs as root in the guest only. The built-in ones download from the projects
themselves over HTTPS and trust those sites: Node.js from nodejs.org (checked against the
checksums published there), nerdctl from its GitHub releases (likewise), npm packages at their
current version from the npm registry, and herdr through its own installer from herdr.dev (which
checks its binary against the release's published hash). Nothing of it runs on the Mac; what is at
stake is what the user keeps in that VM.

## Agents (2026-10-12)

Decided with the user: agents on the Mac are asked only for risky tools, with "always" for one
tool or for all (they already run as the user, so a prompt is the boundary for what reaches
further, not for the Mac itself); an orchestrator VM works freely on the VMs it made and asks for
anything else; a host command is "unsafe but necessary": the user chooses the program and the
patterns, and a loose pattern is pointed out, not refused. Not promised: that an agent the user
answered "always" for will use it well, or that a program behind a host command handles every
value its pattern lets through safely.

## macOS guests (2026-10-23)

A macOS VM is the same kind of sandbox as a Linux one (vsock ssh only, netd's network and firewall,
the isolation check before a shell), with a few things of its own. In the release since 2026-10-23.

- **One root step, when a VM is made.** Apple's installer leaves a disk with no account, so Monad
  asks for the user's password once (macOS's own prompt, after a panel in plain words) and runs
  `monad-macsetup.sh` as root. It copies the disk and the staged files into a folder only root
  writes, refuses links and files that are not the user's, checks every directory on the way into
  the disk, mounts it nosuid and nodev, and never writes into the user's folders. It runs from the
  app, never from MonadHost. Tests: `test_macsetup.sh` (CTests), `MacSetupTests`.
- **Apple's private input API**, behind one seam in `MNDVirtualMachine.m`: keys and clicks into the
  VM's display, used to type in recovery (SIP), the account's password and a paste at the login
  window. It reaches only the VM's own virtual keyboard and pointer. Apple's private screenshot call
  is never used (it kills the VM without Apple's entitlement). A later macOS can remove these
  classes; Monad then says the steps cannot run, it does not guess.
- **SIP and full disk access are the user's choice per VM.** Turning SIP off is typed blind in
  recovery and checked with `csrutil status` at the next boot: a change that did not take is
  undone in the settings and shown, never taken for done. Full disk access is one TCC row for
  Monad's ssh sessions, written on the stopped disk as the user.
- **The account's password lives in the VM's folder** (`mac-password`, 0600) and, while automatic
  login is on (the default), in the guest's `/etc/kcpassword` (Apple's obfuscation, root only):
  root in the VM can read it, as on any Mac that logs in by itself. Auto-fill types it when the
  guest's agent sees a password prompt, only once the user has said yes and only while automatic
  login is on (with it off the guest has only a hash, and typing on its word would hand it the
  password); a prompt that is not the account's gets it too. It is never in a process's arguments
  or a log.
- **The desktop window** is shown by MonadHost (the process that runs the VM). ⌘V puts the Mac's
  text on the VM's clipboard over ssh (stdin, one paste at a time), only when the user presses it;
  nothing flows from the VM's clipboard to the Mac. Everything inside the window is the guest's
  drawing, including anything that looks like a macOS or Monad password dialog: Monad's own
  prompts never appear inside it.
- **Copies** (`clone_vm`, Duplicate…) share the original's account, password, ssh keys and host
  keys: they are the same Mac, with a machine identifier of their own. What was allowed for the
  original alone (shared folders, bridges, host commands, forwards into the Mac, an agent role) is
  not copied, so a copy made by an agent never gets access the user did not give it.

Not promised: that recovery's screens stay where the steps expect them, or that Apple's limit of
two running macOS VMs (Virtualization's, in any app) leaves room for another.

## Decisions (2026-10-05)

- **Clipboard writes by a guest (OSC 52) stay on by default**, within limits: at most 100 KB,
  only from the tab the user is looking at, never from the boot console. Off in Settings › Privacy.
  Reading the Mac's clipboard is never possible.
- **VMs are kept apart unless their network allows it** ("VMs can reach each other", per network).
- **DNS is filtered by the rules** for confined VMs (allowlist and monitor mode); host-only
  networks forward no lookups unless they opt in.
- **An address range the user typed may open the LAN; a name never does.**
- **At most 32 auto-forwards per VM**, lowest ports first; auto-forward itself stays on by default.
- **Forwards into the Mac are confirmed one by one** (2026-10-06): no per-VM switch; adding an
  "Into Mac" forward says what the VM will reach and asks. Such a forward goes over ssh, past the
  VM's firewall, to exactly the port or socket the user named.
- **A VM port reaches other computers only when the user says so** (2026-10-27): a VM port or
  SOCKS proxy on the Mac listens on 127.0.0.1 unless the user types another address in Add
  Forward, which says that other computers can connect and asks. A settings file's such forwards
  are set aside on import and confirmed on edit, and a copy of the VM leaves them behind.
  Auto-forward and the MCP tools use the loopback only. A SOCKS proxy open to the network lets
  other computers send traffic out through the VM, within its firewall.
- **Same-user processes: the cheap parts are fixed** (below).
- **Images a guest sends stay undecoded unless the VM allows them** (2026-10-10): a per-VM switch,
  off when a VM is made (also from an imported settings file, unless the user keeps it). With it on,
  image data from the guest reaches ImageIO, Apple's decoders, within the caps above. A Phase 15
  review item.
- **Imported VM settings files are untrusted** (2026-10-10): checked as on create, and what
  reaches into the Mac (shared folders, bridges, forwards into the Mac or open to other computers,
  `allowLAN`, images) stays out unless the user keeps it in the import sheet. A Phase 15 review
  item.

## Same-user processes

Monad does not fully keep other processes of the same macOS user out, and the first release is
signed ad hoc (no team ID). What holds:

- **MonadHost serves only Monad's own binaries as installed.** Ad hoc, anyone can sign a program
  with Monad's identifiers, so MonadHost also requires each client's code hash to be the one of
  the Monad.app beside it (or of MonadHost itself, for `MonadHost --mcp`), read from disk at each
  connection (`HostXPCSecurity.clientRequirement`; `XPCTransportTests`). A program that only borrows
  the identifier is refused; one that can rewrite the installed app can be it.
- **The app checks MonadHost by identifier only** (pinning the host's hash would leave a rebuilt or
  updated app unable to reach the MonadHost still running its VMs). What a fake MonadHost could ask
  of the app is bounded: the macOS root step runs only on that VM's own disk and staged files
  (`MacSetup.requestProblem`), only while Monad's bundle on disk is intact and is the code running
  (`MacSetup.bundleProblem`), and root runs the script's text the app read, never a file
  (`MacSetupTests`).
- A VM's `instance.json` is validated whenever MonadHost reads it, so a changed file cannot run
  commands and a VM with an invalid one does not start.

What does not hold: a same-user process can read and change `~/.monad` (VM disks, ssh keys to the
VMs, settings, "always allow" grants), connect to a VM's ssh socket, and, if it can write to
`/Applications/Monad.app` and sign it again before Monad is opened, nothing ad hoc can tell that
Monad from the real one. Keep Monad in `/Applications` (macOS's App Management protects apps
there from other apps). Treat a same-user process that is hostile as already having the user's VMs.

## What Monad does not promise

- **A VM that is not confined can look up any name.** Without "Only what the rules allow" or
  monitor mode, DNS leaves through the Mac's resolvers; a deny by name holds on the connection, but
  data can leave in the lookup itself. Confine the VM to stop that.
- **Blocking by name is only as good as the lookups Monad sees.** A program that finds addresses
  another way (its own resolver over an allowed address, hard-coded addresses) is not matched by
  name. For a guarantee, use "Only what the rules allow".
- **Auto-forward checks Mac programs with `lsof`**, which sees the user's own processes only; a
  service run by another user (root, `_postgres`) is not seen, and ssh may still bind next to it.
- **Auto-forward checks when it adds a forward, not afterwards.** A Mac server started later on
  all addresses binds next to the VM's forward, and the Mac's `localhost:port` keeps reaching the
  VM until the forward goes (the guest stops listening, or the port is added to "Ports to skip").
- **A writable shared folder is writable.** A guest can plant files the Mac later runs or reads
  with trust: git hooks, `.envrc`, build scripts, shell rc files. It can also plant symbolic links:
  a link it makes in the share leads wherever it says on the Mac, so a Mac program that opens or
  writes that path follows it (a project file replaced by a link to `~/.ssh/authorized_keys` is
  written there by the next editor or build that saves it). The guest itself cannot follow its
  links out of the share (checked below). Share read-only what you do not want changed.
- **Monad cannot stop Lima from starting a Lima VM that Monad runs.** Both would write to the same
  disk and could corrupt it. Monad refuses to start one while Lima runs it, keeps one Monad VM per
  Lima VM, and its window warns while it runs, but `limactl start` does not ask Monad.
- **Ping (ICMP) to the LAN and the Mac** follows the same firewall as TCP and UDP; on the
  development Mac the ICMP tests currently get no reply (an environment issue, see docs/STATUS.md).

## Checked on the Mac, and still to check

Checked (2026-10-05, through the test suite on the development Mac):

- netd's sandbox refuses connecting to a unix socket (F-13), with a control showing the same
  connect works outside the sandbox.
- ssh's `-L 127.0.0.1:port` bind succeeds next to a Mac server of the same user listening on all
  addresses (IPv4 or dual-stack IPv6, with or without SO_REUSEADDR), and the Mac's own
  connections to `127.0.0.1:port` then reach the VM, with no error from ssh (F-03,
  `LoopbackShadowTests`). This is why auto-forward checks for Mac programs on a port first.
- A symbolic link a guest makes in a writable share is resolved by the guest (2026-10-06, by hand):
  `ln -s / share/root` shows the guest's own `/` inside the guest, and the Mac's `/` on the Mac.
  A guest cannot reach Mac files through a link; Mac programs that follow such a link can (F-14).

To check by hand on the Mac:

- **Auto-forward next to another user's server (F-03):** a server run by root or another user on
  a port the VM also listens on: `lsof` does not see it, so whether ssh's bind is refused (by the
  kernel's port protection between users) or the VM takes the port is not known yet. Checked for
  the user's own servers: Monad reports the port as in use (2026-10-05).
- **ICMP (STATUS Known gaps):** `/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode`;
  stealth mode would explain the missing echo replies.

## Reporting

This is a personal project with no bug bounty. Report security issues privately to the maintainer
rather than in a public issue.
