# A VM's settings (instance.json)

Each VM's settings live in `~/.monad/instances/<name>/instance.json` (a Debug build's under
`~/.monad-debug`). The same JSON is what the VM window's **Configuration** page shows, edits and
exports (a backup), and what **Import** in the Virtual Machines window reads to make a new VM. So a
VM can be written by hand or by a script, much like a libvirt domain's XML.

On the Configuration page you can edit the settings or paste others in, then **Apply**. The text
is checked as you type: the JSON itself (with the line of an error), keys Monad does not know (with
the one probably meant, since a misspelt key would otherwise be dropped), each value's type, and
the values as Save checks them. Clicking a problem selects it in the text. What was set when the
VM was made (`name`, `distro`, `release`, `image`, `user`, `diskGiB`, `ephemeral`, `createdAt`,
`attached`, `copiedFrom`, `guestOS`) cannot change there. An edit that newly lets the VM reach into the Mac (a
shared folder, a bridge, a forward into the Mac, `allowLAN`, `inlineImages`) says so and is applied
only after you confirm it.

Monad writes every key, with sorted keys. A file you write needs only three of them, `version`,
`name` and `distro`. Every other key falls back to what the New VM sheet starts with, or to the
safe choice where there is one. MonadHost checks every value on create, on each save and when it
loads a VM. An `instance.json` changed by hand while Monad runs is listed but not started until
it is saved again from Monad.

## A short example

```json
{
  "version": 2,
  "name": "web",
  "distro": "ubuntu",
  "release": "24.04",
  "cpus": 2,
  "memoryGiB": 4,
  "diskGiB": 40,
  "networks": [{ "network": "default" }],
  "firewall": {
    "allowlist": true,
    "rules": [
      { "action": "allow", "proto": "tcp", "target": "github.com", "ports": [443, 443] },
      { "action": "allow", "proto": "any", "target": "ubuntu.com" }
    ]
  },
  "forwards": [{ "kind": "local", "hostPort": 8080, "guestPort": 80 }],
  "profiles": ["server"],
  "startAtLaunch": true
}
```

This makes an Ubuntu 24.04 VM called `web` with 2 CPUs, 4 GB of memory and a 40 GB disk, on the
`default` network. Only `github.com` on port 443 and `ubuntu.com` can be reached. Port 80 of the VM
is at `127.0.0.1:8080` on the Mac. It sets up the Server profile on first boot and starts when
Monad opens.

## Importing a file

Import treats a file as untrusted and makes a **new** VM from it:

- The VM is made now, from a fresh image of its distribution: `image` and `createdAt` are set
  again, and `ephemeral` is off.
- A name that is taken gets a number (`web-2`). A name Monad cannot take becomes `imported`. You
  can change it in the import sheet.
- Network cards get new MAC addresses. A network this Mac does not have becomes `default`.
- CPUs and memory above what this Mac gives a VM are lowered to that.
- A Lima VM's file (`attached`, `copiedFrom`) makes a VM from a fresh image instead. The Lima VM's
  disk is not in the file.
- **What reaches into this Mac is left out unless you keep it** in the import sheet: shared
  folders, bridges, forwards into the Mac (`remote`, `unixRemote`), `allowLAN` and
  `inlineImages` (image data the VM sends, decoded on the Mac). A shared folder
  that needs your word (the home folder, anything outside it, `~/.ssh`, `~/Library`) is never
  imported. Add it in the VM's settings, which ask you first.
- Each change is listed in the sheet before anything is made.

## Fields

"Fixed" fields are set when the VM is made and never change. "After a restart" fields are saved
at once and used from the VM's next boot. Every other field applies to a running VM as soon as
it is saved.

### The VM

| Key | Type | If left out | Notes |
|---|---|---|---|
| `version` | number | (needed) | `2`. A file without it is read as Monad's first format. A higher number is from a newer Monad and is refused. |
| `name` | string | (needed) | Letters, digits and dashes, starting with a letter or digit, at most 32. Two names that differ only in case are the same VM. Fixed. |
| `distro` | string | (needed) | A distribution id: `ubuntu`, `debian`, `fedora`, `opensuse` (one file each in `Monad/Distros`). Fixed. |
| `release` | string | the distribution's default | For example `24.04`, `13`, `44`, `16.0`, `rolling`. Recorded at creation. Fixed. |
| `image` | string | `""` | The base image the disk was made from, set by Monad. Fixed. |
| `user` | string | your Mac user name, made fit (else `dev`) | The guest login: lowercase letters, digits, `-` and `_`, at most 32, never `root`. Fixed. |
| `cpus` | number | Settings › Virtual Machines | 1 to what this Mac gives a VM. After a restart. |
| `memoryGiB` | number | Settings › Virtual Machines | GB the VM boots with, 1 to what this Mac gives a VM. After a restart. |
| `memoryTargetGiB` | number | `memoryGiB` | GB the VM is asked to use while it runs (the balloon), at most `memoryGiB`. |
| `diskGiB` | number | Settings › Virtual Machines | At least 10. The disk grows as it fills, up to this. Fixed. |
| `networks` | list | one card on `default` | Network cards in order (see below). `[]` means no network at all. After a restart. |
| `firewall` | object | nothing blocked but the Mac and its network | See below. |
| `sharing` | object | no sharing | See below. |
| `forwards` | list | none | Port and socket forwards (see below). |
| `bridges` | list | none | Mac commands the VM can use (see below), at most 8 with the host commands. |
| `hostCommands` | list | none | Mac commands the VM runs with values it varies under patterns (see below). |
| `agents` | object | none | What the VM may do with Monad itself: `role` (`hostCommands` or `orchestrator`), `guestPort` (Monad's MCP endpoint on the VM's loopback, default 7766), and for an orchestrator `maxChildren` (default 4), `childCPUs` and `childMemoryGiB` (its VMs together; default its own size). Reaches into the Mac. |
| `parent` | string | none | The orchestrator VM that made this one. Fixed. |
| `autoForward` | object | on, from port 1024 | Forwarding of the ports the guest listens on (see below). |
| `profiles` | list of strings | none | Profile ids set up on first boot: built in `agentic` and `server`, or yours in `~/.monad/profiles`. |
| `theme` | string | the app's | A terminal theme id for this VM's tabs (`monad-dark`, `automatic`, or one of yours). |
| `startAtLaunch` | true or false | false | Start the VM when Monad opens, without a tab. Written only when true. |
| `inlineImages` | true or false | false | Programs in the VM can show pictures in its tabs (iTerm2's inline images, as neofetch, fastfetch and imgcat use them: PNG, JPEG or GIF, at most 4 MB). Monad decodes image data the VM sends only when this is on. Written only when true. |
| `ephemeral` | true or false | false | Deleted when its last tab closes. Never imported. Fixed. |
| `createdAt` | date | now | ISO 8601 (`2026-10-10T12:00:00Z`). Fixed. |
| `guestOS` | `linux` or `macos` | `linux` | What runs in the VM, from its distribution's kind. Written only for macOS. Fixed. |
| `autoLogin` | true or false | true | macOS only: it logs in by itself at boot, so its desktop opens without a login window. Written only when false. Applies at the next boot. |
| `desktopAutofill` | true or false | not asked | macOS only: Monad types the account's password into the password prompts on its desktop (an admin dialog, the lock screen). Asked the first time the desktop is opened. |
| `bootToRecovery` | true or false | false | macOS only: the next start opens macOS Recovery and its desktop; set back to false as it does. Written only when true. |
| `fullDiskAccess` | true or false | true | macOS only: Monad's sessions may read protected folders (Documents, Desktop, …). Written only when false. Applied to the stopped VM's disk at its next start. |
| `systemIntegrityProtection` | true or false | true | macOS only: System Integrity Protection. Written only when false. A change is made in the VM's recovery at its next start (the Security page). |
| `attached` | object | none | A Lima VM whose disk this VM boots where it is (see below). Fixed. |
| `copiedFrom` | object | none | The Lima VM this VM's disk was copied from. Fixed. |

### Network cards (`networks`)

| Key | Type | If left out | Notes |
|---|---|---|---|
| `network` | string | (needed) | A Monad network (`~/.monad/networks/<name>.json`, lowercase letters, digits and dashes) or `apple-nat` (Apple's NAT, which the firewall cannot see into). Older files may say `nat`. |
| `macAddress` | string | made at first boot | `xx:xx:xx:xx:xx:xx`. |

### Firewall (`firewall`)

Applies to Monad networks (not to Apple's NAT).

| Key | Type | If left out | Notes |
|---|---|---|---|
| `allowlist` | true or false | false | Nothing leaves unless a rule allows it. |
| `allowLAN` | true or false | false | The Mac and its local network are reachable without a rule. Reaches into the Mac. |
| `monitor` | true or false | false | Ask about each new destination no rule decides. |
| `rules` | list | none | At most 64, tried in order, the first that matches decides. |
| `tags` | list of strings | none | Firewall tags (`~/.monad/firewall-tags`) whose rules apply after the VM's own, in this order. |

Each rule:

| Key | Type | If left out | Notes |
|---|---|---|---|
| `action` | string | (needed) | `allow` or `deny`. |
| `proto` | string | (needed) | `any`, `tcp`, `udp` or `icmp`. |
| `target` | string | (needed) | `a.b.c.d/prefix`, a host name (the name and its subdomains) or `*.name` (subdomains only). A name never opens the Mac or its network. |
| `ports` | `[first, last]` | every port | 1 to 65535. Not for `icmp`. |

### Shared folders (`sharing`)

| Key | Type | If left out | Notes |
|---|---|---|---|
| `runtimeEnabled` | true or false | false | The VM gets its folder-sharing device. Needed for any share. After a restart. |
| `shares` | list | none | Mac folders seen in the VM. Reaches into the Mac. |

Each share:

| Key | Type | If left out | Notes |
|---|---|---|---|
| `hostPath` | string | (needed) | An absolute Mac path. Monad's own folder is never shared. A writable share may not hold it. |
| `guestPath` | string | (needed) | Where it is in the VM: absolute, not a system folder (`/etc`, `/usr`, `/proc` and so on). |
| `readOnly` | true or false | true | |
| `confirmed` | true or false | none | Set by the VM window once you agreed to a folder that needs it. Never taken from an imported file. |

A shared folder is mounted again when the VM reboots by itself (`sudo reboot`): Monad notices the
new boot when the VM's agent comes back, checks it as at a start, and mounts its folders.

A folder inside a share whose owner may not read it (mode 000, 100 or 300 on the Mac) cannot be
seen from the VM: `ls -l` shows it as `d?????????` and nothing in the VM can open, change or remove
it, `chmod` included. That is how Apple's shared-folder server works (it opens a folder to look
it up). Tools that make such folders for a while, like `makepkg` with its `pkg/`, are best run
outside the share (for makepkg, `BUILDDIR=/tmp/makepkg`). A folder left that way is fixed from the
Mac (`chmod u+rwx` in Terminal, or Get Info in Finder).

### Forwards (`forwards`)

| Key | Type | If left out | Notes |
|---|---|---|---|
| `id` | string (UUID) | a new one | |
| `kind` | string | (needed) | `local` (a VM port on the Mac), `remote` (a Mac port in the VM), `socks` (a SOCKS proxy on the Mac whose traffic leaves from the VM), `unixLocal` (a VM socket on the Mac), `unixRemote` (a Mac socket in the VM). `remote` and `unixRemote` reach into the Mac. |
| `hostAddress` | string | `127.0.0.1` | The Mac address a `local` or `socks` forward listens on. |
| `hostPort` | number | (needed for ports) | 1024 to 65535 when it listens on the Mac. |
| `guestHost` | string | `127.0.0.1` | The address in the VM (an IP address or a host name). |
| `guestPort` | number | (needed for `local` and `remote`) | 1 to 65535. |
| `hostSocket` | string | (needed for sockets) | Absolute path on the Mac. |
| `guestSocket` | string | (needed for sockets) | Absolute path in the VM. |
| `enabled` | true or false | true | |

### Bridges (`bridges`)

Each connection the VM makes runs the command on the Mac, as you, with the connection as its
input and output. Reaches into the Mac.

| Key | Type | If left out | Notes |
|---|---|---|---|
| `id` | string (UUID) | a new one | Names its socket and log in the VM's folder. |
| `name` | string | (needed) | Up to 32 letters, digits, spaces, dots, dashes or underscores. |
| `command` | list of strings | (needed) | The program by its full path, then up to 31 arguments. No shell reads them. |
| `guestPort` | number | | Where the VM reaches it: a port of its loopback, 1024 to 65535 ... |
| `guestSocket` | string | | ... or an absolute socket path. Exactly one of the two. |
| `enabled` | true or false | true | |

### Host commands (`hostCommands`)

A program on the Mac the VM can run with values it chooses, each checked against a pattern
before anything runs (docs/AGENTS.md). Reaches into the Mac.

| Key | Type | If left out | Notes |
|---|---|---|---|
| `id` | string (UUID) | (needed) | Names its socket and log in the VM's folder. |
| `name` | string | (needed) | Also its MCP tool's name: lowercase letters, digits and dashes, up to 32. |
| `summary` | string | empty | One sentence for the agent, up to 300 characters. |
| `program` | string | (needed) | The program by its full path. |
| `fixedArguments` | list of strings | none | Always passed first; the VM never sees them. |
| `arguments` | list | none | The values the VM may give, in order, at most 16, each with `name` (lowercase, digits, `_`), `pattern` (a regular expression from `^` to `$`, printable ASCII, at most 256 characters), `required` (true unless said) and `summary`. |
| `workingDirectory` | string | (needed) | Full path inside a folder this VM shares. |
| `timeoutSeconds` | number | 3600 | 1 to 86400. The program and everything it started are ended then. |
| `results` | true or false | true | Each run gets a folder in the exchange folder (`~/.monad/exchange/runs` in the VM). |
| `environment` | object | none | More variables, such as `PATH` (Monad's own is launchd's). Never `HOME`, `SHELL`, `DYLD_*`, `LD_*` or `MONAD_*`. |
| `guestPort` | number | | Where the VM reaches it: a port of its loopback, 1024 to 65535 ... |
| `guestSocket` | string | | ... or an absolute socket path. Exactly one of the two. |
| `enabled` | true or false | true | |

### Automatic forwarding (`autoForward`)

| Key | Type | If left out | Notes |
|---|---|---|---|
| `enabled` | true or false | true | Ports the guest listens on are forwarded to the same port on the Mac's loopback (at most 32). |
| `minimumPort` | number | 1024 | Never below 1024. |
| `ignoredPorts` | list of numbers | none | Never forwarded. |

### Lima VMs (`attached`, `copiedFrom`)

Set by the Virtual Machines window's Lima tab, never imported.

| Key | Type | Notes |
|---|---|---|
| `kind` | string | `lima`. |
| `instance` | string | The Lima instance's name. |
| `dir` | string | Its folder (`~/.lima/<instance>`), named after it. |
| `home` | string | The guest user's home as Lima made it (`/home/<user>.linux`). |

## Other files

- `~/.monad/instances/order.json`: the VMs' order in the Virtual Machines window, and the default
  VM chosen with Make Default (the first tab when Monad opens; the top one until one is chosen).
- `~/.monad/vm-groups.json`: the groups of the Virtual Machines window, in order, and which are
  collapsed (docs/GROUPS.md). A VM's group is its settings' `group`.
- `~/.monad/networks/<name>.json`: Monad networks (Settings › Networks).
- `~/.monad/firewall-tags/<name>.json`: firewall tags (Settings › Firewall).
- `~/.monad/profiles/<id>.profile.json`: your own profiles (Settings › Profiles).
- `~/.monad/canvas.json`: where things are on the canvas (`docs/CANVAS.md`).
