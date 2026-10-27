# macOS VMs (Phase 14)

macOS guests work like Linux ones: a terminal tab over ssh through virtio-vsock, and the same
forwards, shares, networks and firewall, canvas, MCP tools and uploads. They are fully headless:
no display, and no Setup Assistant. Turning System Integrity Protection off is a switch, at
creation and in the VM's settings. This file grows with the phase.

## The distribution

macOS is a distribution file like the Linux ones (`Monad/Distros/macos.distro.json`), of its own
kind:

```json
{ "id": "macos", "kind": "macos",
  "releases": [{ "id": "latest", "name": "macOS (the latest this Mac supports)", "default": true }],
  "image": { "url": "apple:latest", "format": "ipsw", "file": "restore.ipsw",
             "signature": { "kind": "none", "note": "Apple signs restore images; …" } } }
```

- `kind: "macos"` decides how Monad makes and reaches the guest (`GuestOS`), never the id.
- The image is an Apple restore image (IPSW). `apple:latest` asks Virtualization for the latest
  one this Mac supports (`VZMacOSRestoreImage.latestSupported`). An added distribution may instead
  give an IPSW's https address, or a file on this Mac (`file:///…/x.ipsw`), as UTM does.
- No checksum file: Apple signs restore images, Virtualization checks the image, and Apple
  personalizes each install.
- Downloads are kept in `~/.monad/images/macos/` under Apple's own file name, downloaded once and
  reused, the newest one used offline. Settings lists them and removes them
  (`ImagePipeline.restoreImages`, `removeRestoreImage`). A file on the Mac is used where it is.
- `GuestOS.ready` holds the kinds VMs are made of, in every build: macOS since 2026-10-23 (in
  Debug builds only while the phase was under way).

## Hardware and install

- A macOS VM's settings say `"guestOS": "macos"` (taken from its distribution when it is made,
  fixed after). It needs at least 4 GB of memory and a 40 GB disk.
- The VM's folder holds, beside `disk.raw`: `aux.img` (Apple's auxiliary storage),
  `hardware-model.bin` and `mac-machine-id.bin`. `VZMachine.vmConfig` points the backend at them,
  and `MNDVirtualMachine` builds `VZMacPlatformConfiguration` and `VZMacOSBootLoader` from them,
  refusing plainly when they are missing or the hardware model is not supported on this Mac.
  macOS guests get no EFI store, seed, memory balloon or graphics device.
- `VZMacInstaller` (`Monad/VM/MacInstaller.swift`) loads the restore image and picks its most
  featureful configuration this Mac supports. It writes the platform files and a sparse disk of
  the size asked for, then runs `VZMacOSInstaller` on a machine of its own, with no network
  device, at least 2 CPUs and 4 GB. Its progress is the VM's state ("Installing macOS — 42%").
  A progress message that arrives after the install ended or failed changes nothing
  (`VMInstance.reportProgress`).
- An installed VM is not started until it is set up (`mac-setup-done`, step 3): a start says so
  at once instead of waiting out the boot deadline.
- macOS VMs are made in the New VM sheet or by MCP `create_vm` with `"distro": "macos"`, in the
  release and Debug builds alike.

## Setup with no setup screens

After the install, MonadHost makes the VM's ssh key and settings, a random 24-character password
(kept in `mac-password`, 0600, for the user), and stages Monad's files in `mac-setup/`
(`MacSetup.stage`). It then asks the user through every connected app (the VM's snapshot carries
`macSetup`; Monad is opened if no app is). The app shows a panel in plain words and, on Continue,
runs `monad-macsetup.sh` through `osascript … with administrator privileges`, the same words as
macOS's own password prompt.

The root step (`Monad/Guest/monad-macsetup.sh`):
- clones the disk and copies the staged files into a fresh root-only folder in `/private/tmp`,
  then checks the copies there: plain files of the user's (a link, or a file of someone else's, is
  refused);
- attaches the clone without mounting it, finds its APFS Data volume (`diskutil apfs list`), and
  mounts it hidden, nosuid and nodev in that folder;
- writes the one-time launchd job `dev.monad.setup`, the staged files under
  `/usr/local/libexec/monad/setup`, and `/var/db/.AppleSetupDone`, checking every directory on
  the way is not a link;
- unmounts, detaches, and hands the folder to the user. It never writes into the user's folders.

MonadHost (as the user) takes the finished disk back only from such a folder: directly in
`/private/tmp`, named `monad-macsetup.*`, the user's, not a link, holding a plain `disk.raw`
(`MacSetup.adopt`). It then removes the staged files and marks the VM set up (`mac-setup-done`).
Saying no, or a failed step, leaves the VM listed as failed with why, and its Log page; its disk and platform files are removed. Delete it, or make a VM of that name again.

At the first boot `dev.monad.setup` runs `monad-macos-firstboot.sh` as root:
- makes the account with `sysadminctl -addUser … -admin`;
- installs the key, `/etc/sudoers.d/monad` (NOPASSWD, as on Linux) and an sshd drop-in (keys only,
  no root login);
- installs and starts `dev.monad.sshd` (Apple's own ssh job, but listening on the guest's loopback
  only, 127.0.0.1:22) and `dev.monad.guestd` (`MonadHost --guestd`);
- removes the password and itself.

Monad runs that first boot while the VM is made ("Starting macOS for the first time…", no network,
no shares, at most 10 minutes): it waits until it can log in over ssh once (sshd makes its host
keys then, and the Mac keeps the VM's), then shuts the VM down from inside (`sudo -n shutdown -h
now`; the power button would only ask, at a login window nobody sees). Powering the VM off from
the first-boot job itself, 0.1 s after sshd's job started, left sshd failing every login on the
next boot (2026-10-16), so the order is the one checked by hand. It then gives Monad's ssh sessions
full disk access: the one TCC row macOS's own "Allow full disk access for remote users" (Remote
Login) writes, for Apple's `/usr/libexec/sshd-keygen-wrapper` (which `dev.monad.sshd` runs), with
its code requirement compiled by the Security framework. SIP keeps TCC.db from the guest's own
root, so Monad writes it from the Mac, as the user: the stopped VM's disk attached read-write with
`hdiutil` (no admin), the row added with `sqlite3`, detached (`MacSetup.grantFullDiskAccess`).
A failure there is logged and the VM is made anyway: only protected folders (Documents, Desktop,
…) stay closed to its sessions.

Remote Login stays off.

`monad-guestd` (`mnd_guestd.c`) serves vsock port 22 by joining each connection to that sshd
(`nc 127.0.0.1 22`) and 1024 with the macOS agent (`monad-macos-agent.sh`, the Linux protocol over
`netstat`), one process per connection, at most 16 at a time per service.

Why sshd sits on the loopback: Apple's sshd opens a BSM audit session for each login with the
peer's address, and with a peer that has no IP address (vsock, a Unix socket) `setaudit_addr`
fails and sshd closes the connection right after the key is accepted ("Could not create new
audit session", found 2026-10-14 with sshd's own log). Linux's sshd has no such step, so there
sshd serves vsock directly.

Each boot checks nothing listens for ssh except on the loopback (`MacSetup.isolationScript`: a
:22 listener on any other address, as Remote Login makes, fails the VM closed like Linux) and
refreshes the agent and `img` and sets the Mac's time zone (`MacSetup.guestInstallScript`).

## Shared folders

macOS has no bind mounts, so a macOS VM gets its shared folders another way
(`GuestShares.macScript`). The VM's one shared folder device is mounted once with Apple's
`mount_virtiofs monad /var/run/monad/virtiofs`, and each folder is a symbolic link at its path in
the VM (`~/share` → `/var/run/monad/virtiofs/Users-dev-share`). The exchange folder is one of them,
at `~/.monad/exchange` (a macOS VM's home is in `/Users`).

- Links already right are kept. Links Monad made for folders no longer shared are removed (Monad
  keeps the list it made in `/var/db/monad/shares-made`), and nothing else is.
- An empty folder where a share goes is replaced by the link. A file, or a folder with something in
  it, is never touched: the VM's page says what is in the way.
- When the running VM's device gets a new folder list, the device is unmounted and mounted again.
- Read-only is the device's, per folder, as on Linux.
- Parent folders Monad makes, and the links, belong to the VM's user.

`mount` lists the device at its resolved path (`/private/var/run/...`, since `/var` is a link), so
the script compares that path. Comparing `/var/run/...` missed it, and the second mount of a
running VM failed with "Resource busy" (found 2026-10-16).

## Making one

macOS is in the New VM sheet's distributions. In place of a release it asks what
to install from: the latest macOS for this Mac (downloaded once from Apple and kept), a restore
image kept from an earlier download, or an IPSW file chosen with Choose IPSW… (used where it is,
never copied). Memory starts at 4 GB and the disk at 64 GB (at least 40 GB). There are no
profiles: macOS has no package manager for them. Kept restore images are listed in Settings ›
Distributions with their size and Remove.

## The desktop

Every macOS VM boots with a display, a keyboard and a pointer (a Linux VM has none). Open macOS
Desktop (the VM's ⋯ menu, a terminal window's … menu when its tab is a Mac, or the VM's Overview)
shows its screen in a window, for what needs a person: the developer tools' installer, a system
prompt. MonadHost, which runs the VM, shows the window (Apple's `VZVirtualMachineView`, reaching the
VM on its own queue through `VZVirtualMachineViewAdaptor`); it is otherwise never on screen.
Closing the window leaves the VM running; it closes when the VM stops. It also shows recovery while
SIP is changed.

- **Log in automatically** (on unless turned off, in the New VM sheet and on the Security page):
  the VM starts at its desktop. Monad writes `/etc/kcpassword` (the password XORed with Apple's
  key, root-only) and `autoLoginUser` while the VM is made and at each boot; a change applies at the
  next start.
- **The password** is Monad's, random, and shown on the VM's Overview only when you click Show.
  The desktop window's Type Password types it, with Return.
- **Auto-fill** (asked the first time the desktop is opened, then on the Security page): the
  guest's agent says when a password prompt comes on screen (a new `SecurityAgent`, or the screen
  locking), and Monad types the password into it a second later.
- **⌘V** in the window pastes the Mac's text: it goes on the VM's clipboard over ssh (`pbcopy`,
  only while the account is logged in on the desktop), then ⌘V is pressed in the VM. At the login
  window, or in recovery, it is typed instead. The VM has no other way to the Mac's clipboard.

## Full disk access

The Security section of the New VM sheet and the VM's Security page have Full disk access (on
unless turned off): the TCC row Remote Login's "Allow full disk access" writes, which lets Monad's
sessions read Documents, Desktop and the other protected folders. It is written when the VM is
made, and a later change is written into the stopped VM's disk at its next start, before macOS
boots (`MacSetup.setFullDiskAccess`). A change that cannot be written is shown on the page and the
VM starts as it was.

## System Integrity Protection

A macOS VM's Security page (and the New VM sheet, for a Mac VM) has a System Integrity Protection
switch. Turning it off asks first and says what happens: at the VM's next start, Monad starts it in recovery by itself, turns
SIP off there and restarts it into macOS, in a few minutes, with nothing for you to do.

How (`MacRecovery`, found on the Mac, see the spike table):

- The VM starts from recovery (`startUpFromMacOSRecovery`) on its own network, with no shared
  folders, and with a display (1920×1200), a USB keyboard and a pointer. A normal boot never has
  them.
- Monad types, waiting for the screen at each step: Options in the startup picker; then it waits
  until the screen is lit (the language list's grey; the boot screen is black, and its progress
  bar can stall for a minute), clicks the list's first row and types `English` (chosen by name,
  since the Mac's language comes first) and Return; ⇧⌘T for Terminal, `csrutil disable` (or
  `enable`), `y`, the account's password, then `shutdown -h now`. A VM that does not shut down
  within 3 minutes is powered off.
- The screen as each wait ended is kept in the VM's `recovery-screens` folder (Debug builds give
  them to agents with `read_recovery_screens`). That is how a run that clicked during the boot
  screen, then typed `csrutil` into the language list (choosing Čeština), was found.
- While it runs, the VM is starting, and its row, its Security page and its Log say which of the
  8 steps it is at (starting recovery, choosing Options, waiting for recovery to load, opening
  Terminal, running csrutil, confirming with the password, waiting for csrutil, shutting down). It
  can be grouped, edited and shut down meanwhile.
- Keys and clicks go through Apple's private input API (`_keyboards`, `_VZKeyEvent`,
  `_pointingDevices`), in one place in `MNDVirtualMachine.m`, each selector checked first. Monad
  never asks for a screenshot: that call is reserved for Apple and kills the VM.
- The VM then starts as usual, and `csrutil status` over ssh says how SIP is. The Security page
  shows it. A change that did not take is undone in the VM's settings (the switch shows what the
  VM has) and the page says why; switching it again tries again. Full disk access works the same.
- Turning SIP back on needs the internet in the VM: Apple signs the full-security boot policy.
- recoveryOS accepts only admins it finds on the Preboot volume. An account made without Setup
  Assistant is not copied there, even with its secure token and as the volume owner: `csrutil`
  then says "no admin users authorized for recovery" and asks for a user name (found 2026-10-20 by
  replaying the steps with screenshots). The first boot therefore runs
  `diskutil apfs updatePreboot /` before it shuts down; `diskutil apfs listUsers /` then shows
  the account as a Local Open Directory User.

## Plan

1. Restore images (done).
2. Hardware and install (done): VZMacOSBootLoader and VZMacPlatformConfiguration, with no graphics
   device; the auxiliary storage, hardware model and machine identifier kept in the instance
   folder; VZMacOSInstaller headless, its progress shown as the VM's state.
3. Setup skip (built, not yet run on the Mac): one admin prompt, explained in plain words. A root helper writes the account, the
   ssh key, `.AppleSetupDone`, sudo and Monad's daemon into the disk's Data volume, walking paths
   with `O_NOFOLLOW`.
4. In the guest (built, not yet run on the Mac): `monad-guestd` serves ssh (`sshd -i`) and the agent on AF_VSOCK; Remote Login
   stays off.
5. The Linux scripts' macOS variants: shares through `mount_virtiofs` and links (done), the
   isolation check (done), discovery.
6. SIP through recoveryOS, typed by a private keyboard API (done: the Security page). Each step
   waits for its screen: a 64×40 brightness grid of the framebuffer (a hidden `VZVirtualMachineView`'s
   IOSurface), changed since the last key and then still, at most the old fixed wait. Boot to
   Recovery (once) opens recovery and its desktop for the user; leaving it starts macOS.
7. The New VM sheet (done, Debug), MCP, limits, copies (done: `clone_vm`), docs.
   A Mac runs at most two macOS VMs at once, in any app, installs included. Virtualization
   checks it (`VZErrorVirtualMachineLimitExceeded`); Monad has no limit of its own and says
   which VMs are running when Apple refuses.

## Spike findings

To be filled in on the Mac (macOS 27 host):

| Question | Finding |
|---|---|
| Installs headless (no graphics device)? | Yes (2026-10-13, macOS 27.0.1 26A434 on a macOS 27 host): `VZMacOSInstaller` on a machine with no graphics and no network device, about 5 minutes. The restore image is 25 GB (17 minutes to download here). |
| Install needs Apple's servers online? | Not checked yet: the Mac was online. With under 4 GB free on the Mac the install failed twice near its end ("failed to install splat", AMRestoreErrorDomain 100) and once went through: Monad should check free space first. |
| Setup skipped by the disk payload? | Yes (2026-10-13): the one-time job ran at the first boot, `sysadminctl` made the admin account (uid 501, home made) and guestd started; macOS was up and online in under a minute. `sysadminctl` warns that an account made without its password typed in cannot unlock FileVault, which a VM does not use. |
| AF_VSOCK in the guest (sshd over vsock)? | Yes, through guestd (2026-10-14): the VM is Running about 20 seconds after it starts, the account has sudo, SIP is on. Apple's sshd cannot serve vsock itself (its audit session needs an IP peer), so guestd joins vsock to sshd on the loopback. |
| virtio-fs mounts with `mount_virtiofs`? | Yes (2026-10-16): the device mounts at `/var/run/monad/virtiofs` and each folder is a link into it; a file from the Mac reads, one written in the VM shows on the Mac, read-write as set. Unmounting the running device (`umount -f`) and mounting it again works. |
| DHCP on a Monad network (netd)? | Yes on the default network: the guest reached Apple's servers through netd. |
| Recovery boot plus private keyboard turns SIP off? | Yes (2026-10-20, on a clone): `startUpFromMacOSRecovery`, a `VZMacGraphicsDeviceConfiguration` display, a USB keyboard and a screen-coordinate pointer. Keys go through `VZVirtualMachine._keyboards` (`_VZKeyEvent`, type 0 down / 1 up, Mac virtual key codes), clicks through `_pointingDevices` (`_VZScreenCoordinatePointerEvent`, 0…1 from the top left). The screen is read from a `VZVirtualMachineView`'s IOSurface layer. The steps: Options, Return; a click on English (recovery's window takes no keys until clicked); ⇧⌘T for Terminal (a root shell, no login); `csrutil disable`, `y`, the account's password; `csrutil status` said disabled. No window is needed to type: a run with no view and no screenshots typed the same steps blind, and the guest shut down when `shutdown -h now` was typed. Turning SIP back on (`csrutil enable`, the same `y` and password) needs the internet ("Can't continue because you are not connected to the Internet": full security is personalized by Apple); turning it off works offline. Apple's NAT gave recovery no IPv4 address here, so the recovery boot should use the VM's own Monad network. Never call `VZGraphicsDisplay._takeScreenshotWithCompletionHandler:`: the VM service only allows it with Apple's private entitlement and kills the VM otherwise ("The virtual machine stopped unexpectedly"). |
| A clone with a new machine identifier boots? | An APFS clone of the disk and auxiliary storage boots (2026-10-16, same machine identifier, the original stopped). A new identifier is not checked yet. Monad Debug keeps the auxiliary storage locked even while the VM is stopped, so a clone is made from the files, not by a second machine on them. |
| Full disk access for ssh sessions with SIP on? | Yes (2026-10-14): `~/Documents` was "Operation not permitted" over ssh, even as root; one TCC row for `sshd-keygen-wrapper`, written as the user into the stopped VM's disk, opened it. |
