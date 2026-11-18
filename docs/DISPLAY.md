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
| A part of the display in another window | Each window holds a `VZVirtualMachineView` of its own, as large as the whole display and moved behind the window so that only one part of it is inside. With foot on the display, the view in its Mac window held a 3840×2160 framebuffer and the window's part of it was foot, at scale 2 (read from the view's layer; the screen itself was not looked at) |
| Does the display follow its window? | The Mac's new size reaches the guest as the display's first mode within a second. labwc does not take it by itself (its own list of modes keeps the old sizes): `display-follow` sets it as a custom mode on each change. Checked: a window of 2400×1500 pixels gave a display, a session and a surface of 2400×1500, at scale 2 |
| Sizes | 1920×1200 at start. The guest can set any size itself up to 8192×8192 (the kernel's limits for the device), and the Mac's surface follows: 5120×2880, 8192×4320 and 8192×8192 were set from the guest and read back on the Mac. That is room for about eight full Retina screens of windows side by side. A surface that large costs its memory three times on the Mac (the chain) |
| Can a program of Monad's own drive the display? | Yes: kernel mode setting through ioctls alone (no library), compiled in the guest with its `cc`; a test pattern and then real programs' windows were read back on the Mac |
| First start with the profile | About a minute to install it; the session is up 9 seconds after a later start |

## Each Linux program as a Mac window: the App windows profile, for a terminal so far

The Desktop profile puts the programs inside one window, the VM's display. The App windows
profile is the other way, and takes the display in its place: Monad's own window manager in the
guest lays every program's window out on one large display and tells MonadHost where each is;
on the Mac each becomes a window showing its part of the display, so the pixels still go from
the VM to the screen without a copy; keys, clicks and scrolling go back to the guest over
Monad's own channel.

**Setting it up** (`Monad/Profiles/app-windows.profile.json`, for distributions with apt; run on
Ubuntu 26.04): a VM with Display on and the App windows profile. The window manager is C, and a
Mac cannot build a Linux program, so the VM builds it: Monad's installer puts its sources
(`GuestWM/`, as they are in the app), a build script (`monad-wm-build.sh`) and its service
(`monad-wm.service`, off) in every VM with a display at each boot; the profile installs a C
compiler and a terminal (foot), builds the program and turns the service on. From then on the
installer rebuilds it at a boot where this Monad's sources are not the ones it was built from, so
the window manager is always this Monad's. The service takes the display as root and goes on as
the VM's user. A program started from a tab (`foot &`) opens as a window on the Mac. A new VM
made with Display and the profile had its window manager answering MonadHost 80 seconds after
its first boot began, and 11 seconds after a restart.

**In the guest** (`GuestWM/`, tested in `CTests/test_wm_*.c` and fuzzed by `fuzz_wm`): `monad-wm`
takes the display and speaks Wayland to programs with code of its own (the wire format,
`wl_compositor` with subsurfaces, `wl_shm`, `xdg_wm_base` top-level windows and popups,
`wl_seat`, xdg-decoration). Each window gets a place of its own on the display, in rows, a gap
from the next; what the program drew is drawn there from its buffers, only where it says
something changed, at the scale it drew at (programs are told the Mac screen's). A menu, a
tooltip or a list that drops down is a window too, told with the window it is on and where the
program put it there; a menu that asked for the keyboard has it while it is up. Programs that
ask are told the frame is not theirs to draw. The pointer and the keyboard are not read from the
VM's devices: the window manager is told which window the pointer is over and which one is in
front, and only the program owning that window hears of it. It is C, compiled in the guest by
the distribution's `cc`: Xcode cannot build Linux programs, and Monad ships no binary it did not
build.

**Between the two**, one channel: lines of text on vsock port 1025, which MonadHost dials when
the guest's installer says the window manager is set up, and which the window manager takes
from the Mac only (`GuestWM/mwm_ctl.h` has every line; `GuestWindowProtocol.swift` reads the
guest's as hostile).

**On the Mac** (`LinuxAppWindows.swift`, shown by MonadHost like the desktop): a window for each
of the guest's, titled with the program's title and the VM's name, the size the program drew at
in points. Dragging its edge asks the program to draw at the new size; its red button asks the
program to close the window. A popup is a window with no frame on the window it belongs to,
moving with it, shown only where it touches that window; turning to something else (the
window's frame, another window, another app) tells the program its menus are done with. The
keys are the Mac's layout as it is: a table of what each key types (plain, with Shift, with
Option) made with `UCKeyTranslate` and written out in the guest as the programs' keymap, dead
keys included, sent again when the layout changes. Command is sent as Control (⌘C, ⌘V, ⌘S, ⌘Q,
⌘W do in a Linux program what they do on the Mac), the left Option as Alt, the right Option as
the key for the characters Option types. ⌘M, ⌘H and ⌘` stay the Mac's.

Run in Debug VMs (first with the window manager installed by hand, then in a new VM made with
Display and the profile): foot opened as a Mac window "foot — wm-try" at Retina scale; a command
typed into it through this Mac's layout ran; a second foot opened as a second window; resizing
the Mac's window resized the terminal (40 rows by 138 columns at 897×520 points); closing it
ended foot. GNOME's Calculator (GTK 4) opened as a window; clicks on its buttons gave 7+5=12;
its mode menu opened as a popup under its button, and choosing Advanced there closed the menu
and widened the window to the new layout. The typing, clicking, resizing and closing were done
through the Debug tool `drive_window`, which calls what the window's own events call, and what
a window shows was read from its view (`read_windows`): nobody has looked at these windows on
the screen yet, or used them with a real pointer and keyboard.

Not there yet: the clipboard (programs may bind its interface, and nothing is carried, so even
copy and paste inside foot does nothing); the pointer's shape (always the Mac's arrow); X11
programs through Xwayland; programs that draw their own title bar whatever they are told
(GTK's) get the Mac's above it; a popup that is not a rectangle (GTK 4's menus have round
corners and a point) is black where it is cut out; a popup is where the program put it, with
no regard for the Mac screen's edges; a window with no room left on the display is not shown;
MonadHost has no Dock icon or menus, so these windows are not in ⌘Tab; the desktop and the
windows cannot be had at once (each profile turns the other's service off; Open Desktop on a VM
with App windows shows the display the windows are laid out on); distributions without apt; Qt
programs were not tried.

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
