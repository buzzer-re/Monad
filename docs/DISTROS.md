# Distributions: how they work and how to add one

A distribution in Monad is one JSON file. It says where the distro's cloud images are and how to
check them. Everything else about the guest is decided by the guest itself when it boots, the
way Lima's templates work: a Lima template is only image URLs, and Lima's boot scripts find out
what the guest has.

Monad's own files live in the app (`Monad/Distros/<id>.distro.json`, keys in
`Monad/Distros/keys/`). Files you add live in `~/.monad/distros/<id>.distro.json`
(`~/.monad-debug/distros` for the Debug build). Settings › Distributions lists both. New
Distribution… is a form for the same file, each problem said by field. Its Simple view is like
picking a disk image in a virtual machine app: paste the image's address (or choose a file on this
Mac) and that is it. Monad looks next to the image for a checksum file that lists it (the names in
the folder's listing that look like one, then `CHECKSUM`, `SHA256SUMS`, `SHA512SUMS` and the
like) and for that file's signature (`.asc`, `.gpg`, `.sign`, `.sig`), and takes the name and
version from the image's file name. With a checksum file every download is checked against it;
when it is signed the form offers the project's key, optional, and with it the signature is
checked too. Without one (or for a file on this Mac) the image is used as it is. The Advanced
switch shows every field of the file, and a distro that uses one Simple does not show opens
there. Advanced's Check reads the checksum file first (it sets the line format and the hash from
it and lists the disk images it names under Images), then fetches it and its signature again,
verifies them and finds the image, without downloading it. Edit… opens an added distro in the form. Add From File… takes
a file someone wrote, after showing what it would download and how it is checked. Remove takes
one no VM uses, and files that were left out are listed with the reason. The New VM sheet offers an added distro at once, and
MonadHost reads the folder again for each new image.

## What a guest needs

Monad works with a cloud image that has:

- **cloud-init** reading a NoCloud seed (an ISO labelled `cidata`). Monad writes the user, the
  ssh key, its own units and scripts with it.
- **systemd.** Monad's sshd and guest agent are socket-activated units on vsock.
- **OpenSSH server**, at `/usr/sbin/sshd` unless the file says otherwise. It never listens on the
  network: every unit named `ssh.service`, `ssh.socket`, `sshd.service` or `sshd.socket` is masked,
  and Monad's own `monad-sshd.socket` serves vsock port 22 only.
- **A kernel with virtio-vsock** (`vmw_vsock_virtio_transport`, loaded at every boot if it is a
  module) and the usual virtio drivers (block, net, console).
- **An arm64 image** (Monad runs Apple silicon guests natively, nothing is emulated), qcow2, raw,
  or a raw disk inside a tar.xz. A qcow2 or raw image may be compressed as `.xz` or `.gz`
  (`name.qcow2.xz`). Images for Intel PCs (amd64, x86_64) are refused.

What the guest decides by itself, so the file does not say it:

| | How |
|---|---|
| Network sshd units | All four names masked; a name the guest lacks costs nothing |
| Admin groups | The user joins whichever of `wheel`, `sudo`, `adm` exist; sudo comes from the sudoers rule cloud-init writes |
| SELinux | Present (`/sys/fs/selinux/enforce`): Monad's module (`Guest/monad.cil`) is loaded, systemd starts sshd itself. Absent: sshd starts through `env --ignore-signal=CHLD` (no zombie per connection) |
| Host keys | `ssh-keygen -A` before each sshd |
| Kernel console | `console=hvc0` added last, through whichever of grubby, an `/etc/default/grub.d` drop-in or `/etc/default/grub` the guest has, from its second boot on (`Guest/monad-console.sh`): the kernel's and the boot's own messages reach `serial.log` and the boot tab, even when the boot fails before sshd. Not in Lima VMs |
| `img` | `/usr/local/bin/img` (`Guest/monad-img.sh`), put in place and kept current by the installer at every boot, unless another `img` is there: pictures in a tab when the VM allows images, through `base64`, `od` and `wc` from GNU, busybox or BSD |

## The file

```json
{
  "schema": 1,
  "id": "rocky",
  "name": "Rocky Linux",
  "releases": [
    { "id": "10", "name": "Rocky Linux 10", "default": true }
  ],
  "architectures": { "arm64": "aarch64" },
  "image": {
    "checksums": {
      "url": "https://dl.rockylinux.org/pub/rocky/{release}/images/{arch}/CHECKSUM",
      "format": "bsd",
      "algorithm": "sha256"
    },
    "signature": {
      "kind": "detached",
      "url": "{checksums}.asc",
      "publicKeys": ["-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----\n"],
      "fingerprints": ["0123456789ABCDEF0123456789ABCDEF01234567"]
    },
    "file": "Rocky-{release}-GenericCloud-Base.latest.{arch}.qcow2",
    "url": "{dir}{file}",
    "format": "qcow2"
  },
  "guest": { "packageManager": "dnf" }
}
```

(The URL and file name are illustrative: check what the project actually publishes.)

A real one, checked against what the project publishes on 2026-10-12 (`DistroDraftTests`
verifies its real signature with Monad's verifier): **AlmaLinux 10**. In the Simple view: paste
`https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2`,
pick `dnf`, and optionally paste the key from
`https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux-10`. As a file: checksum file
`https://repo.almalinux.org/almalinux/{release}/cloud/{arch}/images/CHECKSUM` (`gnu`, `sha256`),
signature `{checksums}.asc` (detached), image `AlmaLinux-{release}-GenericCloud-latest.{arch}.qcow2`,
`arm64` → `aarch64`, release `10`, key `https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux-10`
(RSA 4096, fingerprint `EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572`), package manager `dnf`.

| Key | Meaning |
|---|---|
| `schema` | 1 |
| `id` | `^[a-z][a-z0-9-]{0,31}$`, and the file is named `<id>.distro.json`. Not one of Monad's own ids |
| `name` | Shown in the New VM sheet |
| `releases` | Each with `id`, `name`, optional `vars` (more `{placeholders}`); exactly one `"default": true` |
| `architectures` | `arm64` to the distro's word for it in its addresses (`aarch64` or `arm64`, usually); Apple silicon only |
| `image.checksums` | Optional for a distro you add: without it `image.url` is the image itself (an http or https address, or `file:///…` on this Mac), used as it is and downloaded once, `signature.kind` is `none` and the format `qcow2` or `raw`. Otherwise: `url` of the checksum file, or `index` (a directory listing) plus `pattern` (a glob naming the file in it). `format`: `gnu` (`<hash>  <file>`), `bsd` (`SHA256 (file) = hash`) or `single` (one hash). `algorithm`: `sha256` or `sha512` |
| `image.signature` | `kind`: `detached` (with `url`), `clearsigned` (the checksum file is signed itself) or `none`, with an optional `note` saying why (Monad's own must give one). A signature is recommended, not required: without one the image is only compared with checksums from the same server, which is fine for a mirror you host yourself. Signed: `publicKeys` (armored, up to 8, inline in the file) and `fingerprints` (40 upper-case hex digits of each primary key trusted to sign) |
| `image.file` | Glob selecting the image in the checksum file |
| `image.url` | Where the image is: `{dir}{file}` (next to the checksum file) unless it lives elsewhere. The form leaves it empty for that |
| `image.format` | `qcow2`, `raw` or `tar.xz` (then `member`: the disk inside). A `qcow2` image without qcow2's magic is read as raw (an `.img` is either) |
| `image.compression` | Optional, `xz` or `gz`: the published file is a compressed qcow2 or raw image (the checksum is the compressed file's). Unpacked with Monad's own xz decoder or zlib, holes kept |
| `guest` | Optional. `sshd`: absolute path if not `/usr/sbin/sshd`. `packageManager`: `apt`, `dnf` or `zypper`, so profiles can install packages; without it profiles are not offered |
| `preferred` | Monad's own files only |

Placeholders: `{release}`, `{arch}` and the release's `vars` everywhere; `{checksums}` (the
checksum file's URL) in `signature.url` and `image.url`; `{dir}` (its directory, with a trailing
slash) and `{file}` (the image name picked by `image.file`) in `image.url`. Every URL must be
https for Monad's own; a distro you add may use plain http too (a mirror on your own network: your
call, the form says what it costs). Every template must expand for every release.

How an image is checked (`Monad/Distro/ImagePipeline.swift`): the checksum file is downloaded
(1 MB at most), its signature checked against the pinned keys (`OpenPGP.swift`: v4 RSA or
Ed25519, SHA-256/384/512), the image name picked from it, the image downloaded and its digest
compared, then converted to a raw disk and cached. An unsigned distro is checked against its
checksum file over https only, and the New VM sheet says so.

## Rules for added files

A file in `~/.monad/distros` is read with care and left out, with the reason in Settings, if it:

- is not a plain file (links are not followed), or is larger than 256 KB;
- is not valid JSON or fails any rule above (http or https addresses, safe file names, known formats);
- names key files (`signature.keys`, which only Monad's own may use) instead of `publicKeys`;
- has `publicKeys` that do not contain every pinned fingerprint;
- reuses one of Monad's ids, or its id does not match its file name;
- says `"preferred": true`.

At most 64 added files are read. Adding a file is a trust decision: you are telling Monad which
keys may vouch for the images, so Settings shows the host and the fingerprints first.

## Porting a distro

1. Find its cloud image for arm64 (look for "cloud", "GenericCloud" or "Minimal-VM Cloud") and its
   checksum file. Lima's templates (`templates/_images/*.yaml` in lima-vm/lima) are a good list
   of URLs that work on Apple's virtualization.
2. Find how the checksum file is signed and get the key from the project's own site. Paste it in
   the form (or put its armored block in `publicKeys` and its fingerprint in `fingerprints`). No
   signature at all is allowed, if you trust where the images come from.
3. Paste the image's address in Settings › Distributions › New Distribution… (Advanced for
   templates, several releases or a directory listing), or write the file and use Add From File…
   (or drop it in the folder and press Reload).
4. Make a VM. If its creation fails (the image cannot be had, say), the tab says why. A distro the
   VM service does not know is refused in the New VM sheet: a VM service from an older Monad, kept
   while VMs run, does not know distros added since, and the Virtual Machines window offers to
   restart it. The boot tab shows the console; the guest prints `MONAD| ` lines about its setup
   (SELinux, vsock, sshd, the user and its key) and, until Monad logs in, every sshd error and
   SELinux denial about ssh or vsock (`Guest/monad-report.sh`). If the boot fails, the error ends
   with "The guest says: ..." and with what Monad found on the VM's disk once it was off (its partitions,
   and whether each filesystem's superblock or only a backup is intact); Settings › Logs has every line.
5. Once it logs in: check that a port opened in the VM is forwarded (the guest agent works) and
   that a shared folder mounts.

Things that break a port, from experience:

- **No cloud-init, or one that ignores NoCloud.** Nothing is set up: no user, no key.
- **sshd elsewhere.** Set `guest.sshd`.
- **SELinux with an old policy.** Look for `selinux denied` lines in the boot tab; Monad's module
  covers what Fedora 44 and openSUSE Leap 16.0 needed. A new denial means a rule to add to
  `Guest/monad.cil` (each rule in an `optional` block).
- **A boot loader Monad cannot set** (no grubby, update-grub or grub-mkconfig). The kernel's console stays off
  hvc0, so a boot that fails early leaves `serial.log` empty; the VM's log has the line that says so.
- **No systemd** (Alpine uses OpenRC). Not supported yet.
