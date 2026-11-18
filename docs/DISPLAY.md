# A Linux VM's display

A Linux VM has no display unless its Display setting is on. With it on, the VM gets a framebuffer, a
keyboard and a pointer, and its ⋯ menu's Open Desktop shows the display in a window on the Mac.
A desktop runs on it. This page says what is built and what was measured on the way. A VM's
programs as Mac windows of their own need no display: `docs/WINDOWS.md`.

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
| A part of the display in another window | It can be done: a window holding a `VZVirtualMachineView` of its own, as large as the whole display and moved behind the window so that only one part of it is inside. With foot on the display, the view in its Mac window held a 3840×2160 framebuffer and the window's part of it was foot, at scale 2 (read from the view's layer; the screen itself was not looked at) |
| Does the display follow its window? | The Mac's new size reaches the guest as the display's first mode within a second. labwc does not take it by itself (its own list of modes keeps the old sizes): `display-follow` sets it as a custom mode on each change. Checked: a window of 2400×1500 pixels gave a display, a session and a surface of 2400×1500, at scale 2 |
| Sizes | 1920×1200 at start. The guest can set any size itself up to 8192×8192 (the kernel's limits for the device), and the Mac's surface follows: 5120×2880, 8192×4320 and 8192×8192 were set from the guest and read back on the Mac. That is room for about eight full Retina screens of windows side by side. A surface that large costs its memory three times on the Mac (the chain) |
| Can a program of Monad's own drive the display? | Yes: kernel mode setting through ioctls alone (no library), compiled in the guest with its `cc`; a test pattern and then real programs' windows were read back on the Mac |
| First start with the profile | About a minute to install it; the session is up 9 seconds after a later start |

## Each Linux program as a Mac window

Not a matter of the display any more: `docs/WINDOWS.md`. The windows first showed Apple's view of
this display, each its own part of it (the rows above); that lagged, and they now draw pixels
the VM's window manager sends over Monad's own channel. A VM needs no display for them, and can
have the desktop and the windows at once.

## Security

A display is three more devices of Apple's that a hostile guest can talk to (the virtio-gpu
device's commands, two USB devices), in Apple's process for the VM, not in MonadHost. That is why
it is off unless asked for, set apart when settings are imported, said when an edit turns it on,
and never given to a VM another VM makes (`docs/SECURITY.md`). Monad's own code reads nothing the
guest draws on it: the window shows it, and that is all.
