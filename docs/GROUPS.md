# Groups: VMs gathered by what they are for

The Virtual Machines window lists VMs in groups ("coding", "analysis", "agents"), the way
VirtualBox does, so a long list stays readable. A group is also a firewall tag: the rules of the
tag named like the group apply to every VM in it.

## What a group is

- A VM is in one group or none: its settings' `group` (letters, digits, `-` and `_`, up to 32,
  the rule for firewall tag names). It is changed like any other setting, through MonadHost's
  update, so every check applies and every app sees it.
- The groups' order, the groups with no VM yet, and which are collapsed belong to the app, in
  `~/.monad/vm-groups.json` (0600, `VMGroupStore`; bad or repeated names are left out). A group a
  VM names that the file does not list is shown after the others, so a VM moved by an agent or
  by hand is never hidden.
- `VMGroups.sections` turns the list into headings: the saved groups in their order, then the
  others by name, then the VMs in no group (headed "No group" once there are groups). VMs keep
  the list's order inside their group. Tested in `VMGroupsTests`.

## In the window

- New Group (top right) names one. A VM moves with Move to Group in its ⋯ menu (or New Group…
  there), by dragging its handle onto a group's heading, or onto a VM of another group (it takes
  that place and joins that group). "No group" takes VMs out.
- A heading is a row the size of a VM's: a folder, the group's name, how many VMs it holds and
  how many run (and the first names while collapsed). A click on it collapses or opens it.
  Headings scroll with the list, never sticking over one another. Its menu has Rename… (its VMs and its firewall tag follow; a tag already
  using the new name is refused), Firewall Rules…, Move Up, Move Down and Delete Group… (its VMs
  stay, in no group, and lose its rules; the rules stay in Settings › Firewall as a plain tag).

## The firewall

`InstanceConfig.effectiveFirewall` is the VM's firewall with its group attached
(`VMFirewall.group`, never written to the VM's file). `Firewall.resolve` applies the VM's own
rules, then its tags', then the group's tag if there is one; a group with no tag adds nothing and
is not reported as a missing tag, and a group the VM also carries as a tag counts once. netd
gets the effective firewall when the VM joins a network and whenever it changes, so moving a VM
to another group changes what it may reach at once. Monitor-mode answers can be saved on the
group (its tag is made then), and the Connections page names the group's rules when one decided.
A VM's Network page shows its group with the number of rules and Group Rules….

Firewall Rules… in a group's menu opens Settings › Firewall on the group's tag, made empty if it
did not exist yet.

## The default VM

Grouping changes the list's order, so the default VM (the first tab when Monad opens, and what ⌘T
opens with no tab in front) is no longer "the top one": it is the one chosen with Make Default,
marked "default VM". Until one is chosen it is the top of the list, as before.
MonadHost keeps the choice in `instances/order.json` (`defaultVM`), answers `setDefault`, and
tells every app with the `defaultVM` event; deleting the default VM makes the top one the default
again. An app talking to an older MonadHost falls back to moving the VM to the top.

## Agents

`set_group` (MCP) puts a VM in a group or none, and `list_vms` shows each VM's group. It asks the
user first: the group's tag may allow what the VM's own rules do not.
