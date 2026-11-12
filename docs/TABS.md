# Tabs, tab groups and the saved session

A terminal window holds tabs, each the split panes of one or more VM sessions. Tabs can be put in
groups, the way Firefox does it, and Monad opens the windows, tabs and groups of last time when it
starts, each shell in the directory it was in.

## The tab strip

Monad draws the strip itself (`TabStripView`): the system's tab bar has no place for groups. It
shows under the titlebar once a window has two tabs or a group, and takes the paint of a
see-through theme's titlebar. A window is one `NSWindow` whatever its number of tabs; only the tab
in front is in it, and the others' sessions go on out of sight.

- A click brings a tab to front; its × or a middle click closes it. ⌘W closes the context in
  front, then the tab, then the window. ⌘1 … ⌘9 and Show Next/Previous Tab (⌘} and ⌘{) go over
  the tabs in sight.
- "+" opens another tab on the VM in front, as ⌘T does; "…" has the other VMs.
- A tab drags to another place in the strip. Its menu (right-click) moves it to a window of its
  own; Window ▸ Merge All Windows brings every window's tabs, groups included, into the one in
  front.

## Groups

A group is a named, coloured run of tabs that stay together, shown after its label, with a line of
its colour under the label and its tabs.

- **Make one:** a tab's menu ▸ Add Tab to New Group (or Window ▸ Add Tab to New Group), then type
  its name and pick a colour under the label. Add Tab to Group ▸ puts a tab in one that exists;
  Remove from Group takes it out. A tab dropped on a grouped tab joins that group; dropped on a
  tab in none, or past the last tab, it leaves its group.
- **Collapse:** a click on the label hides the group's tabs, and another shows them. The tab in
  front stays in sight while its group is collapsed, so the window never shows a tab the strip
  does not.
- **The label's menu:** Name and Color…, Color ▸, Collapse/Expand Group, New Tab in Group, Move
  Group to New Window, Ungroup Tabs (the tabs stay) and Close Group (its tabs close).
- A label drags the whole group; a group never lands inside another.
- A new tab goes last, in no group, unless it was asked for in one. A group left without tabs is
  gone.

The model is `TabStrip` (pure, `TabStripTests`): the tabs in order, the groups, the tab in front.
`TabStripLayout` (`TabStripLayoutTests`) places labels, tabs and buttons, and says where a drag
lets go.

## The saved session

Settings › Terminal › Open the tabs of last time (on by default). While it is on, Monad keeps in
`~/.monad/session.json` (0600, `SessionStore`):

- each terminal window's place on the screen, its tabs in order, its groups (name, colour,
  collapsed) and the tab in front;
- each tab's panes (the split tree and its shares) and each pane's contexts;
- for each context the VM by name (or that it is a host shell), the directory its shell is in, and
  the theme chosen for that tab.

Nothing a program printed is kept, and no scrollback. Tabs on ephemeral VMs are left out: those
VMs are discarded when Monad quits. The file is written a second after something in it changes and
when Monad quits. Closing the last window keeps its tabs for the next start; turning the setting
off removes the file.

When Monad starts, each saved window opens where it was (in the middle of the screen when that
place is on a display that is gone). A tab starts its sessions when it first comes to front, so a
session with many tabs does not start every VM they are on at once: the tab in front of each
window starts, the others wait. A VM's shell starts with `cd <directory>` and then the login shell
(the home folder if the directory is gone); a host shell starts in the directory while it is still
a folder on the Mac.

### Where a shell is

A VM's shell says where it is with OSC 7 at each prompt. `/etc/profile.d/monad.sh`
(`GuestDiscovery.profileScript`, pushed at every boot; `~/.monad/profile.sh` in a macOS guest)
makes an interactive bash or zsh do it. Other shells need it in their own prompt:

```sh
printf '\033]7;file://%s%s\033\\' "$HOSTNAME" "$PWD"
```

A shell that does not report opens again in the home folder. A VM made before this needs one boot
with this Monad, and a new login shell, for the hook to be there. A host shell needs nothing: the
Mac knows its directory.

### What the file is trusted with

The directories in it came from guests (OSC 7), so the file is read as untrusted
(`SavedSession.sanitized`, `SavedSessionTests`): VM names must look like names, directories must
be absolute, printable and at most 4096 bytes, a pane tree must hold together, and windows, tabs
and contexts are bounded; what does not fit is left out. A directory is only ever passed quoted to
the VM that the tab is on, or checked to be a folder before a host shell starts there.
