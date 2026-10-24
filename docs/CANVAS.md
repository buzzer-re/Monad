# The canvas: VMs and networks on one map

The canvas (VM › Canvas) draws every Monad network as a frame with its VMs inside it, This Mac and
the Internet beside them, and lines for what moves between them. Moving a VM into another frame
moves it to that network. It is a view on the VMs' settings, never a second copy of them: what the
canvas changes goes through the same update and validation as the VM window.

## Data flow

```
netd (switch)        mnd_net_peers: per sending VM, the VMs it sent unicast frames to
   │                 (frames, bytes, last seen; at most 16 per VM, gone with either VM)
   │  peers <network> [from=<n>]          control channel, one line per page
   ▼
MonadHost            NetdSupervisor.traffic(): every network's pages, ports named by VM
   │  traffic request                     (HostProtocol, logged only when it fails)
   ▼
Monad.app            HostClient.traffic() every 2 s while the canvas shows
   │                 HostClient.instances (VM settings and state), NetworkStore (networks)
   ▼
CanvasModel          frames, nodes, edges, drops → intents
   │
   ▼
Canvas view          draws the model; a confirmed intent → HostClient.update(config)
```

Nothing guest-controlled reaches the drawing without a check on the way: netd's tokens are read
strictly (`NetPeer`, like `NetConnection`), ports become VM names only for ports MonadHost itself
handed out, and traffic naming a VM the canvas does not show is left out.

## The model (`Monad/Canvas/CanvasModel.swift`)

Geometry only, no UI, tested in `CanvasModelTests`.

- **Inputs.** `CanvasVM` per VM (name, its Monad network or none, running, whether forwards or
  bridges link it to this Mac), read from its settings; `CanvasNetwork` per network (name, kind);
  `VMTraffic` from MonadHost.
- **Frames and nodes.** Each network has a frame; VMs on no Monad network (no network device,
  Apple's NAT, a network that is gone) share an area of their own (`CanvasModel.outside`). Nodes
  are VM cards of a fixed size. This Mac stands left of the frames, the Internet above them.
- **Placement.** A new network's frame goes right of the others; a new VM takes the first free
  slot of its frame (two columns). Frames grow to hold their nodes, and a frame that comes to
  overlap another moves right with its nodes. Nothing the user placed moves by itself; what is
  gone is dropped from the layout.
- **Membership by containment.** A VM's network is the frame it sits in. Dropping a node:
  - in another network's frame: the drop returns `.moveVM(name, from:, to:)` and the node waits
    there for the answer (refreshes leave it be). Yes: the window saves the VM's network, and once
    its settings say so the move is settled. No (or saving fails): `cancelMove` puts it back;
  - in its own frame: it stays where it is put;
  - anywhere else: it goes back to where the drag started.
- **Moving a frame** moves its VMs with it.
- **Edges.** Traffic between two VMs is one edge for both directions (bytes added up, live when
  seen in the last 10 s); VMs with forwards or bridges get an edge to This Mac; NAT networks get
  an edge to the Internet (internal, host-only and switch-only networks have no way out).

## Persistence

`~/.monad/canvas.json` (0600, `CanvasStore`): a version, the frames by network, the node centres
by VM, and where This Mac and the Internet stand. A file that cannot be read, or one from a newer Monad, starts the layout again; values that
are not finite or absurdly large are dropped. Only positions are kept there; which network a VM is
on always comes from its own settings.

## Interactions (the view, `Monad/App/CanvasView.swift`)

VM › Canvas (⇧⌘K) opens it, edge to edge under a clear titlebar. The look follows deployment
canvases such as Railway's: a dotted ground, networks as dashed groups with a label chip (name,
kind, subnet), VMs as cards (a distribution tile, name and release, a status pill, CPUs and
memory, a mark when forwards or bridges reach this Mac), in Monad's colours (obsidian, and the
icon's ember for selection and live traffic), light and dark.

- **Moving around.** Two fingers pan, a pinch or ⌘-scroll zooms around the pointer (a local event
  monitor, so it works over cards too; scroll views keep their scrolling); dragging the ground
  pans; the zoom cluster has −, the zoom level, + and Fit. Fit also runs when the window opens.
- **Selecting.** A click on a card opens its inspector on the right: actions (Terminal, Open Tab,
  Start, Restart, Shut Down), the machine, its network and firewall in words, forwards and bridges, and
  its traffic with other VMs; Connections… and Settings… open the VM window there. Esc or a click
  on the ground closes it.
- **Making.** New (top right) makes a VM or a network in the middle of the view; a right-click on
  the ground makes one where the pointer is ("New VM in lab" inside a network). A VM is made with
  the New VM sheet, its network chosen; a network with Settings › Networks' model. Each appears
  where it was made (`CanvasModel.hint`). A right-click on a group (or its label) edits it; a
  network with VMs on it is not deleted.
- **Moving VMs.** Drag a VM into another network's group: Monad asks "Move <vm> to <network>?",
  saves the VM's network (`CanvasModel.config(_:movedTo:)`: its MAC kept, nothing else changed),
  and offers to restart it when it runs (a network change applies at the next boot). No, or a
  failed save, puts the VM back. Drag a group by its label to move it with its VMs.
- **This Mac and the Internet** stay where they are put: placed once beside the groups, then
  dragged where the user wants them (kept in the layout; they no longer follow the groups'
  bounds, which made the Internet look tied to every network). A click or a right-click on This
  Mac shows every forward and bridge between the Mac and the VMs, by VM (`MacLinks`), each VM
  with a way to its Port Forwarding page.
- **Edges.** Traffic between VMs is a curve between the facing card edges, or an arc under two
  neighbours, its width from the bytes, labelled with them, and flowing in ember while live (seen
  in the last 10 s). Dotted curves go to This Mac, a thin blue one from each NAT network to the
  Internet.
- **Terminals in the canvas.** A VM's right-click "Terminal in the Canvas", or the inspector's
  Terminal, opens a dock below the canvas with a terminal on that VM (`CanvasWindowController`).
  The dock is the terminal window's panes (`TerminalPanes`, shared with `TerminalWindowController`):
  a VM already docked is brought to front, another one opens as a new context in the focused pane,
  and the pane menu (on a pane's header and in the terminal's right-click) switches, opens and
  closes contexts and splits; a pane dragged by its header moves within the dock. The Shell menu's
  Split Side by Side (⇧⌘V), Split Stacked (⇧⌘H) and the pane moves (⌘ and an arrow) act on the
  dock while its terminal is in front, and ⌘W closes the context in front there. The divider
  resizes the dock; its bar shows the terminal in front and closes all its terminals (×); the
  last context closing hides it. Closing the window closes its terminals.
- The map refreshes every 2 seconds while it shows, and at once when a VM is made, changed or
  removed; it stops when its window closes. What appears while the canvas is open grows in (VMs
  and their cards, network frames with a ring, notes, and arrows and ink drawn along). A preview
  with sample VMs (`CanvasWindowModel.preview()`) shows every element without a MonadHost.

## Notes, labels, zones, arrows and ink (`Monad/Canvas/CanvasNotes.swift`)

Things written on the canvas by the user or by agents (the MCP tools `list_canvas`, `add_note`,
`edit_note`, `remove_note`). MonadHost keeps them in `~/.monad/canvas-notes.json` (0600) and
pushes every change to every app (`HostEvent.notes`); the app asks for them with `notes`, and
writes with `setNote` and `removeNote`. A note an app writes is "you"'s; one an agent writes says
which ("mac", or "vm:<name>"), and an edit keeps who wrote it.

- **Kinds.** A note is Markdown (inline) on a coloured card: free, or pinned beside a VM or
  network (several stack down; moved away, a dotted thread still joins them). A label is a chip
  on a VM (under its card) or a network (under its frame). A zone is a titled, tinted area: drawn
  by hand, or wrapped around VMs and networks, following them as they move. An arrow joins any two
  things (VMs, networks, notes, This Mac, the Internet), edge to edge, with words in the middle.
  Ink is a freehand stroke, simplified (Ramer–Douglas–Peucker) to at most 2,000 points.
- **Things by name.** `vm:<name>`, `net:<name>`, `note:<id>`, `mac`, `internet`; the tools also
  take a VM's or a network's plain name.
- **Checks.** Every note is checked like an agent's input wherever it comes from: ids of 1–16
  lowercase letters and digits, refs well formed, a label up to 80 characters and other text up
  to 4,000, no control characters, coordinates finite and within ±10⁷, sizes up to 20,000, a
  zone wrapping at most 16 things, at most 500 notes. A file note that fails is left out.
- **Forgetting.** A VM deleted takes its labels and arrows along, notes pinned to it are
  unpinned, and zones stop wrapping it (a zone that wrapped only it goes). A note removed takes
  the arrows to it. Notes on a network that is gone are not drawn.
- **Placement and hits** (`CanvasNotesLayout`, tested in `CanvasNotesTests`): a note without a
  place of its own sits right of what it is pinned to, or in a column right of everything; a
  click near an arrow or a stroke, or on a zone's edge or title, selects it, the inside of a zone
  being left to what is in it.
- **Tools** (the palette, top middle): Select, Note (click the canvas, or a VM or a network to
  pin it), Label (a VM or a network), Zone (drag an area, or click a network to wrap it), Arrow
  (where it starts, then where it ends; a VM's right-click "Arrow From Here"), Pen; the colours,
  for what is written next or the selection; Delete for the selection. A double-click edits a
  note, label, zone title or arrow's words; a note left empty goes. Notes move by a drag and
  resize from their corner, as do drawn zones by their title and corner. Esc goes back to Select.
  VMs' and networks' right-click menus add a label, a note, or a zone around a network.
- **Delete and undo.** Delete (⌫) removes the selected note, label, zone, arrow or stroke; on a
  selected VM it asks first ("Delete … and its disk?"), as that cannot be undone. Keys reach the
  canvas only while focus is on it, never from a text field being edited or the docked terminal.
  Edit › Undo and Redo (⌘Z, ⇧⌘Z) go through the window's undo manager: writing, editing,
  recolouring, moving and deleting what is written (a note deleted comes back with the arrows
  that went with it), moving VMs, frames and landmarks by hand, and moving a VM to another
  network (its network set back; a running VM picks it up when it starts again). Deleting a VM
  is not undone.
