# A Linux VM's display

A Linux VM has no display unless its Display setting is on. With it on, the VM gets a framebuffer, a
keyboard and a pointer, and its ⋯ menu's Open Desktop shows the display in a window on the Mac.
Programs with windows run on it. This page says what is built, what was measured on the way, and
what is not there yet: each Linux program as a Mac window of its own, and drawing by the Mac's GPU.

## What is built

- **The setting** (`display` in the VM's settings, off by default; New VM sheet › Access, the VM's
  Overview › Desktop, `create_vm`'s `display`). It adds three devices when the VM starts
  (`MNDVirtualMachine.m`): `VZVirtioGraphicsDeviceConfiguration` with one scanout, a USB keyboard and
  a USB pointer. It applies at the next start. A macOS VM always has its own display and does not
  take the setting.
- **Open Desktop** (the VM's ⋯ menu, a terminal window's … menu when its tab is on that VM, the
  VM's Overview). MonadHost, which runs the VM, shows the window (`MacDesktop.swift`, Apple's
  `VZVirtualMachineView`), as for a macOS VM. It needs macOS 27 on the Mac. Closing the window leaves
  the VM and what runs on its display as they are.
- **The display is the size of its window.** Resizing the window resizes the VM's display; the
  session on it is told the screen's scale (2 on a Retina screen) so what it draws is the size it
  would be on the Mac.
- **⌘V in the window** puts the Mac's text on the session's clipboard, through ssh (`wl-copy`).
  Pasting it is then the Linux program's own key (Ctrl-V in most). The VM never reads the Mac's
  clipboard, and nothing comes back from the VM's.
- **The Desktop profile** (`Monad/Profiles/desktop.profile.json`, for distributions with apt; run
  on Ubuntu 26.04). It installs labwc (a window manager), Xwayland (for programs that only know
  X11), foot (a terminal), and sets up:
  - `monad-display.service`: labwc as the VM's user on tty7, started at boot when the VM has a
    display (`/dev/dri/card0`), inert when it has none;
  - `/usr/local/lib/monad/display-follow`: makes the session use the size and scale the Mac gives;
  - `gui`: `gui firefox` in a tab starts a program on the display.

  It is a window manager with a menu on the background (right click), not a desktop with a panel
  and a file manager. XFCE was tried and is not offered yet: started this way on Ubuntu 26.04 its
  panel ends at once (the image loader's sandbox fails in that session; the cause is not found).

## What the guest needs

`virtio_gpu` and USB HID drivers in its kernel. Ubuntu's cloud image has them. Debian's and Kali's
cloud images boot a kernel built for clouds, which most likely has neither (not run): they need
the distribution's full kernel first.

## What was measured (2026-11-18, macOS 27.0.1, an M5 Pro, Ubuntu 26.04 guest)

| Question | Answer |
|---|---|
| Does Apple pass a GPU to a Linux guest? | No. The guest's kernel says of the device: `features: -virgl -edid -resource_blob -host_visible`, `-context_init`, `number of cap sets: 0`. No 3D commands, no memory shared with the Mac, no way to carry OpenGL or Vulkan through it. The macOS 27.2 SDK's headers name no 3D for it either. OpenGL in the guest is drawn by its CPUs (Mesa's llvmpipe) |
| What the Mac gets of the display | `VZVirtualMachineView`'s layer shows an `IOSurface` of the display's size (BGRA), from a chain of three that swap as the guest draws. The Mac's compositor draws it straight from there: no copy by Monad, no encoding, no network |
| Several views of one display | Yes: two views on one machine showed the same surface at once |
| A part of the surface in another window | A plain layer takes the same `IOSurface` as its contents with a `contentsRect`: set without error; how it looks on screen was not seen |
| Does the display follow its window? | The Mac's new size reaches the guest as the display's first mode within a second. labwc does not take it by itself (its own list of modes keeps the old sizes): `display-follow` sets it as a custom mode on each change. Checked: a window of 2400×1500 pixels gave a display, a session and a surface of 2400×1500, at scale 2 |
| Sizes | 1920×1200 at start. The guest can set any size itself up to 8192×8192 (the kernel's limits for the device), and the Mac's surface follows: 5120×2880, 8192×4320 and 8192×8192 were set from the guest and read back on the Mac. That is room for about eight full Retina screens of windows side by side. A surface that large costs its memory three times on the Mac (the chain) |
| Can a program of Monad's own drive the display? | Yes: kernel mode setting through ioctls alone (no library), compiled in the guest with its `cc`; a test pattern and then real programs' windows were read back on the Mac |
| First start with the profile | About a minute to install it; the session is up 9 seconds after a later start |

## What is not built

**Each Linux program as its own Mac window.** Today the programs are inside one window, the VM's
display. The way there, which the measurements support: Monad's own window manager in the guest
lays every program's window out side by side on one large display and tells Monad where each is;
on the Mac each becomes a window showing its part of the same surface, so the pixels still go from
the VM to the screen without a copy; keys, clicks and scrolling go back to the guest over Monad's
own channel.

Its first part is written (`GuestWM/`, tested in `CTests/test_wm_wire.c` and `test_wm_server.c`):
`monad-wm` takes the display, speaks Wayland to programs with code of its own (the wire format,
`wl_compositor`, `wl_shm`, `xdg_wm_base` top-level windows), gives each window a place of its own
and copies what the program drew there, and prints where each window is. Run by hand in a Debug
VM, two `weston-simple-shm` stood side by side and moved, read back on the Mac. Not there yet:
keyboard and pointer, menus and other popups, the clipboard, X11 programs through Xwayland (most
real programs need at least the first two: foot, GTK and Qt do not start on it yet), the channel
to MonadHost, the Mac's windows, and installing it (the Desktop profile still sets up labwc). It
is C, compiled in the guest by the distribution's `cc`: Xcode cannot build Linux programs, and
Monad ships no binary it did not build.

**Drawing by the Mac's GPU.** Apple's device cannot carry it (the first row above), and
Virtualization takes no device of Monad's own. What remains is to send a program's OpenGL calls
out of the guest over Monad's channel and run them on the Mac with Metal: a graphics library for
the guest and an OpenGL-to-Metal implementation with a shader compiler on the Mac, written from
nothing (Monad takes no third-party code, so not ANGLE, MoltenVK or virglrenderer). Projects of
that kind are years of work for a team. Until then: windows are put on screen by the Mac's GPU;
what is in them is drawn by the VM's CPUs. That is the speed of a Linux desktop without a graphics
card: fine for editors, terminals, tools and most pages in a browser; slow for WebGL, video at
large sizes and 3D programs.

## Security

A display is three more devices of Apple's that a hostile guest can talk to (the virtio-gpu
device's commands, two USB devices), in Apple's process for the VM, not in MonadHost. That is why
it is off unless asked for, set apart when settings are imported, said when an edit turns it on,
and never given to a VM another VM makes (`docs/SECURITY.md`). Monad's own code reads nothing the
guest draws: the window shows it, and that is all.
