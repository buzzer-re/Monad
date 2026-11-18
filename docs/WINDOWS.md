# A Linux VM's programs as windows on the Mac

With the App windows profile, each window of a program in a Linux VM is a window on the Mac: its
own title bar and buttons, the Mac's pointer and keyboard layout, the Mac's shadow. The VM needs no
display for it (its Display setting is for a desktop, `docs/DISPLAY.md`). This page says how it is
built, what was run and measured, and what is not there yet.

## How it works

Monad's own window manager runs in the guest (`monad-wm`). Programs draw into memory they share
with it, as Wayland has it. It keeps each window's pixels at a place of its own on a sheet of
memory, and sends MonadHost what changed, over a vsock port only the Mac can dial. MonadHost
shows each window as a Mac window that draws those pixels. Keys, clicks and scrolling go back
over the same connection. No display device of Apple's is in between.

**Setting it up** (`Monad/Profiles/app-windows.profile.json`, for distributions with apt; run on
Ubuntu 26.04): add the App windows profile to a VM, in the New VM sheet, the VM's settings, or
from the VM's ⋯ menu › Apps. The window manager is C, and a Mac cannot build a Linux program, so
the VM builds it: Monad's installer puts its sources (`GuestWM/`, as they are in the app), a
build script (`monad-wm-build.sh`), its service (`monad-wm.service`, off) and what programs need
to find it (`/etc/profile.d/monad-windows.sh`) in every Linux VM at each boot; the profile
installs a C compiler and a terminal (foot), builds the program and turns the service on. From
then on the installer rebuilds it at a boot where this Monad's sources are not the ones it was
built from, so the window manager is always this Monad's. The service starts as root, for the
user's session to be there (`monad-wm-session.sh`: the user's services run, so a program finds
its settings and portals), and goes on as the VM's user. A program started from a tab (`foot &`)
or from the VM's Apps menu opens as a window on the Mac. A new VM made with the profile and no
display had its window manager answering MonadHost 25 seconds after its first boot was up.

**In the guest** (`GuestWM/`, tested in `CTests/test_wm_*.c` and fuzzed by `fuzz_wm`): `monad-wm`
speaks Wayland to programs with code of its own (the wire format, `wl_compositor` with
subsurfaces, `wl_shm`, `xdg_wm_base` top-level windows and popups, `wl_seat`, xdg-decoration and
KDE's decoration protocol, cursor-shape, `wl_data_device`). Each window gets a place of its own
on the sheet (8192×8192 pixels; memory is taken only where a window stands), in rows, a gap from
the next. What the program drew is drawn there from its buffers, only where it says something
changed, at the scale it drew at (programs are told the Mac screen's), and as it drew it: what a
program left see-through stays see-through. What changed is kept as a few rectangles, not as
one around them all: a spinner in one corner and a progress bar in another are two small parts.
A menu, a tooltip or a list that drops down is a window too, told with the window it is on and
where the program put it there; a menu that asked for the keyboard has it while it is up.
Programs that ask are told the frame is not theirs to draw, and a window is told that every edge
of it meets a frame (tiled), so a program that draws a bar of its own draws square corners and
no shadow. The pointer and the keyboard are no devices of the VM: the window manager is told
which window the pointer is over and which one is in front, and only the program owning that
window hears of it. The clipboard is the programs' own: what one copies the one in front can
paste, written by the copier into the paster's pipe; only the program in front sets it or is
told what is on it, and nothing is dragged. How the pointer is to look is the word of the
program it is over, by name (text, pointer, a resize), or none when the program hides it. It is
C, compiled in the guest by the distribution's `cc`: Xcode cannot build Linux programs, and
Monad ships no binary it did not build.

**Between the two**, one connection on vsock port 1025, which MonadHost dials when the guest's
installer says the window manager is set up, and which the window manager takes from the Mac
only. Lines of text each way (`GuestWM/mwm_ctl.h` has every one; `GuestWindowProtocol.swift`
reads the guest's as hostile), and after a `pixels` line the pixels themselves: of a window in
the list last told, inside it, at most 32 MiB in one piece. A piece is sent when MonadHost has
read all that was said before, so what a program draws meanwhile waits and goes as one, the
newest: a slow Mac gets fewer pictures, not older ones. Pixels are packed when that halves them
at least (`GuestWM/mwm_pack.h`: runs of one colour, and "as the row above"; flat ground with text
on it takes under a hundredth), and unpacked by MonadHost in C that refuses whatever is not
exactly the picture it was said to be (`Monad/Backend/mnd_pixels.c`, `CTests/test_wm_pack.c`).

**On the Mac** (`LinuxAppWindows.swift`, shown by MonadHost like a VM's desktop): a window for
each of the guest's, titled with the program's title and the VM's name, the size the program
drew at in points, first shown when all of its picture came. The picture is memory the screen is
drawn from directly (`GuestPicture.swift`: two IOSurfaces taking turns, so the screen never
shows a part half written); MonadHost copies what arrives into it and does nothing else with
it. Dragging the window's edge asks the program to draw at the new size; its red button asks
the program to close the window. A popup is a window with no frame on the window it belongs to,
moving with it, shown only where it touches that window, see-through where the program drew
nothing (round corners, around a menu's arrow), with the Mac's shadow around what it drew.
Turning to something else (the window's frame, another window, another app) tells the program
its menus are done with. The keys are the Mac's layout as it is: a table of what each key types
(plain, with Shift, with Option) made with `UCKeyTranslate` and written out in the guest as the
programs' keymap, dead keys included, sent again when the layout changes. Command is sent as
Control (⌘C, ⌘V, ⌘S, ⌘Q, ⌘W do in a Linux program what they do on the Mac), the left Option as
Alt, the right Option as the key for the characters Option types. ⌘M, ⌘H and ⌘` stay the Mac's.

**The Mac's clipboard and the VM's** meet on those keys and at no other time
(`GuestClipboard.swift`). ⌘V (⇧⌘V in a terminal) gives the VM the Mac's text before the program
hears the key, when something was copied on the Mac since the VM last had its clipboard: at
most 1 MiB, text only, and from then on it is what a paste in the VM gives. ⌘C and ⌘X ask the
window manager for what the program in front copies next: its text comes back once, within two
seconds, at most 100 KiB, without control characters, and becomes the Mac's clipboard while the
user is still in that VM's windows. A copy that is no text (a picture) stays in the VM, and the
Mac's older text is not pasted over it. A program in the VM never reads the Mac's clipboard and
never sets it by itself; Copy chosen from a program's own menu stays in the VM.

**One title bar.** A program that draws a header bar of its own (GTK's, with its menus and
buttons in it) keeps it, under the Mac's title bar, and the two are made to read as one: the
guest's session is named `Monad` as a desktop, and a settings override for that desktop alone
(`90_monad.gschema.override`, written by `monad-wm-session.sh`; the user's own settings and the
Desktop profile's are not touched) takes the close button out of GTK's headers, so the window's
buttons are the Mac's only; the Mac's title bar takes the colour at the top of the header, with
light or dark buttons to match. Dragging the header, or double-clicking it, is the program
asking for its window to be moved or zoomed (`move`, `zoom`, `minimize` on the channel):
MonadHost does it only as the user's doing, when the left button went down in that window
within the last seconds (a move) or the user just clicked or typed there (the others). Programs
that leave the frame to the Mac (Qt, foot) have the Mac's plain title bar.

**The VM's programs** are in the VM's "…" menu under Apps (`GuestApps.swift`,
`GuestAppsView.swift`): the VM's desktop entries as `monad-apps.sh` lists them over the VM's
ssh connection, favourites first, with a panel to search them. Their icons are PNG files the
guest hands out (an SVG is drawn by the guest's `rsvg-convert` where it has one), kept by
MonadHost in the VM's folder (`app-icons/`) and decoded by Monad's own PNG decoder in the app,
at most 96 pixels. Favourites are the app's own preferences on this Mac.

**The pointer** is the Mac's, drawn by the Mac (`GuestCursor.swift`): an I-beam over text, a
hand over a link, the Mac's resize cursors, by the number of the shape the program named. No
picture of a pointer comes from the VM: a program that draws a cursor of its own gets the arrow,
and one that hides the pointer hides it over its own window only.

## What was run

In Debug VMs on Ubuntu 26.04, the last one made new with the profile and no display (no
`/dev/dri` in it): foot opened as a Mac window at Retina scale; a command typed into it through
this Mac's layout ran; resizing the Mac's window resized the terminal and its picture; `exit`
closed the window. GNOME's Calculator (GTK 4) opened as a window; clicks on its buttons gave
7+5=12; its menu opened as a popup under its button. GTK 3's widget factory and FeatherPad
(Qt 6) opened. With a clipboard of the test's own in the place of the Mac's: ⌘V typed its `7*6`
into Calculator, Return, ⌘A and ⌘C brought `42` back, ⇧⌘V in foot then pasted that 42, and
306,000 bytes pasted into `cat` in foot arrived whole within a second. The pointer's shape, as
the window manager told it, was the I-beam over foot and over Calculator's entry and the arrow
over its buttons. `read_apps` listed a VM's seven programs and stored three icons.

The typing, clicking, resizing and closing were done through the Debug tool `drive_window`,
which calls what the window's own events call, and what a window shows was read from its
picture's memory (`read_windows`). When the windows still showed Apple's view of the display,
Calculator, the widget factory, foot and FeatherPad were looked at on the screen and used with
a real pointer. Since they draw their own pixels nobody has looked at them on the screen: that
the picture is the right way up and in the right colours there is not checked. The Apps menu
and panel were not looked at either, and the Mac's real clipboard was never read or set (macOS
may ask before MonadHost reads it; not seen).

## What was measured (2026-11-18, macOS 27.0.1, an M5 Pro, a 4-CPU Ubuntu 26.04 guest, Retina scale)

The windows first showed Apple's view of the VM's display, each its part of it. That lagged, and
is why they draw their own pixels now.

| | Through Apple's display | Their own pixels |
|---|---|---|
| GTK 3's widget factory, two spinners and a progress bar moving | One rectangle around all three sent to the display each frame; each update took 11 ms in the guest however small. The VM's process 60% of a core, WindowServer 39 to 46% (22 to 30% with no Linux window open) | Three parts, 7 MB a second. MonadHost 2.5%, the VM's process 47% (the program's own drawing: 35% of a guest CPU, and the window manager 7%), WindowServer 44% (29% with no Linux window open) |
| foot, a full window (2860×1560 pixels) of text scrolling as fast as it goes | not measured | Packed: 62 pictures a second, 9 MB a second, MonadHost 20%. As they are: 34 a second, 604 MB a second, and the VM's process 2.9 cores to carry them |

- **WindowServer** takes about 15% of a core more while a Linux window changes 60 times a second,
  for a window of 1400×1000 pixels as for one of 2910×1544: the price of any Mac window that
  changes that often, not of how the pixels get there.
- **The VM's process** is where the guest's own CPU time shows. A program that draws with the
  CPU (GTK 3 at Retina scale) costs what it costs; only drawing on the Mac's GPU changes that.
- **Sending pixels as they are is not good enough** for a whole window: the VM's socket costs
  about four cores for each gigabyte a second. Packed, what programs mostly draw is small. A
  photograph or a video is not, and goes as it is.

## Not there yet

- Drawing by the Mac's GPU (below).
- X11 programs (through Xwayland).
- The clipboard carries text only between the Mac and the VM (a picture or files copied in the
  VM paste in the VM).
- A cursor a program draws itself (the arrow in its place).
- A program's header bar is under the Mac's title bar, not in it; programs that read no GNOME
  settings keep window buttons of their own in their headers.
- A popup is where the program put it, with no regard for the Mac screen's edges.
- Programs are told the screen is as large as the sheet (8192×8192), not the Mac's: one that
  sizes its first window by the screen opens too large.
- MonadHost has no Dock icon or menus, so these windows are not in ⌘Tab.
- A window with no room left on the sheet is not shown (64 windows at most).
- Pixels are unpacked and copied on MonadHost's main thread.
- Distributions without apt.

## Drawing by the Mac's GPU

Apple passes no GPU to a Linux guest (`docs/DISPLAY.md`, measured), and Virtualization takes no
device of Monad's own. What remains is to send a program's OpenGL calls out of the guest over
Monad's channel and run them on the Mac with Metal: a graphics library for the guest and an
OpenGL-to-Metal implementation with a shader compiler on the Mac, written from nothing (Monad
takes no third-party code, so not ANGLE, MoltenVK or virglrenderer). Not built. Until then:
windows are put on screen by the Mac's GPU; what is in them is drawn by the VM's CPUs. That is
the speed of a Linux desktop without a graphics card: fine for editors, terminals, tools and
most pages in a browser; slow for WebGL, video at large sizes and 3D programs.

## Security

`docs/SECURITY.md` has the rows and the reasons. In short: the guest decides how many windows
there are, what they are called and what is in them, so every title ends with the VM's name, a
new window takes the keys only when the user is in Monad already, and everything the guest says
is bounded and checked before it is shown. MonadHost reads the pixels a guest sends: into
memory of the size the guest's own window list allows (together no more than the sheet), at
the place the line before them said, unpacked by code that writes nowhere else. It does not
look at them. The Mac's clipboard meets the VM's only on the user's ⌘C, ⌘X and ⌘V.
