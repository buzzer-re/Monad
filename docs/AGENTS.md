# Agents: Monad's MCP server, host commands, orchestrator VMs

Monad speaks the Model Context Protocol, so a coding agent (Claude Code, Codex, anything with MCP)
can drive it: make and run VMs, run commands and move text files in them, add distributions, and
change forwards, firewall rules, shares, bridges and host commands. The same server can be mapped
into a VM, so an agent there can run Mac commands you defined (host commands) or, as an
orchestrator, make and run VMs of its own.

## Agents on this Mac

```sh
claude mcp add monad -- /Applications/Monad.app/Contents/MacOS/MonadHost --mcp
codex mcp add monad -- /Applications/Monad.app/Contents/MacOS/MonadHost --mcp
```

(Settings › Agents has the line for your copy, with a Copy button.) `MonadHost --mcp` is the same
signed binary as MonadHost: it reads MCP messages on stdin and relays them over XPC to the
MonadHost that runs your VMs, which checks it like it checks the app. Monad must have run once.

Tools that read or that stay inside a VM run at once. Tools that reach into the Mac or cannot be
undone ask you first: `delete_vm`, `add_distro`, `remove_distro`, `add_mac_forward`,
`allow_destination`, `set_firewall`, `set_group`, `add_share`, `add_bridge`, `add_host_command`, `set_agent_role`,
`set_macos_security`. The
question shows the tool and its arguments; the answers are Deny, Allow Once, Always Allow that
tool, and Always Allow Everything. An unanswered question is refused after two minutes. "Always"
answers are kept in `~/.monad/agents/grants.json` and taken back in Settings › Agents.

## Tools

| Tool | What it does |
|---|---|
| `list_vms`, `get_vm` | The VMs, or one in full |
| `read_vm_log` | A VM's log (what Monad did with it: boots, recovery steps, errors), its last lines |
| `read_recovery_screens` | A macOS VM's screen as each of recovery's waits ended (its last SIP change), as pictures (Debug builds only) |
| `create_vm` | A VM from an installed distribution, started once made unless `start` is false |
| `start_vm`, `stop_vm`, `restart_vm`, `delete_vm` | |
| `clone_vm` | A copy of a stopped macOS VM (`new_name`, `start`): same system and account, its own machine identity, the disk cloned. Shared folders, bridges, host commands, forwards into the Mac and an agent role are not copied |
| `set_macos_security` | A macOS VM's Security page: `sip`, `full_disk_access`, `auto_login`, `boot_to_recovery` (once); only what is given changes, at the next start (asks) |
| `exec` | A shell command in a running VM, as its user: status, stdout, stderr (1 MB each), 600 s at most |
| `read_file`, `write_file` | A text file in a running VM, up to 1 MB |
| `list_distros`, `add_distro`, `remove_distro` | `add_distro` takes an image's address, as Settings does |
| `list_networks`, `list_connections` | |
| `create_network` | A network (nat, host-only, internal, none) on the first free subnet unless one is given; `vms_reach_each_other` |
| `delete_network` | A network no VM is on (never the default one) |
| `set_group` | A VM's group in the Virtual Machines list (asks: a group's firewall tag may allow more) |
| `restrict_vm` | Tightens a VM's firewall: only what its rules allow, and this Mac's network blocked unless said |
| `set_firewall` | Sets a VM's firewall either way (asks: it can loosen it) |
| `list_canvas`, `add_note`, `edit_note`, `remove_note` | What the canvas shows, and notes, labels, zones and arrows on it (docs/CANVAS.md) |
| `add_forward`, `add_mac_forward`, `remove_forward` | Into the VM; into the Mac (`remote`, `unixRemote`) |
| `block_destination`, `allow_destination`, `remove_firewall_rule` | |
| `add_share`, `remove_share` | Read-only unless said, under the same rules as the window |
| `add_bridge`, `remove_bridge`, `add_host_command`, `remove_host_command` | |
| `set_agent_role` | A VM's role (below) |

Every change goes through the requests the app makes, so the window's checks hold: validation,
the share rules, the Mac's limits.

## VMs with a role

Settings › Agents › Add to VM… (or `set_agent_role`) gives a VM one of two roles:

- **Host commands**: the VM's host commands are MCP tools for its agents (`host_<name>`, with
  `run_wait`, `run_status`, `list_runs`).
- **Orchestrator**: also every tool above. On VMs it made (its children) it works freely: make
  (up to its limit, with the CPUs and memory it may give them together), start, stop, delete, run
  commands, move files. Anything else asks you: another VM, itself beyond reading, Monad's
  settings, anything that reaches the Mac. "Always" answers are per VM. A child is on its parent's
  network behind its parent's firewall, with no shares, bridges, host commands, forwards or role.

MonadHost serves the VM's endpoint on a private socket (`~/.monad/instances/<vm>/mcp.sock`, 0600)
that the VM reaches at `http://127.0.0.1:7766/mcp` (the port is the role's), through a remote
forward on its ssh master. Requests carry the VM's token (`Authorization: Bearer`), which only
that VM has: it is made with the role, kept beside the socket and in the guest's
`~/.monad/mcp.env` (0600), and goes with the role. Requests with an `Origin` header are refused (a
web page in the guest has no business there).

What the guest finds without being told, rewritten whenever these settings change:

| | |
|---|---|
| `~/.monad/bridges.json` (`$MONAD_BRIDGES`) | Each bridge and host command, where it is in the VM; the MCP address |
| `~/.monad/mcp.env` | `MONAD_MCP_URL`, `MONAD_MCP_TOKEN`; read by `/etc/profile.d/monad.sh` |
| `~/.monad/exchange` (`$MONAD_EXCHANGE`) | Read-only; host command runs in `runs/` |

When Claude Code or Codex is installed in the VM, Monad registers itself with them (`claude mcp
add --scope user --transport http monad …`, `codex mcp add monad --url … --bearer-token-env-var
MONAD_MCP_TOKEN`), at every boot, when the role changes and after a profile is set up (the
Agentic profile installs both).

## Host commands

A host command is a program on the Mac the VM may run with values it chooses, each checked
against a pattern you set (the VM window's Port Forwarding page › Add Host Command…). The VM never
names a program. In `instance.json` as `hostCommands` (docs/CONFIG.md lists every key).

- The program by its full path, fixed arguments the VM never sees, and up to 16 values, each a
  regular expression from `^` to `$` that Monad compiles and matches against the whole value
  before anything runs. A pattern with `.*` is pointed out before you agree.
- It runs as you, without a shell, in its own process group, in a folder this VM shares, with
  launchd's plain environment plus what you set (`PATH`, usually), never `DYLD_*`, `LD_*`, `HOME`
  or `SHELL`. One run at a time; up to 4 wait. The time limit ends it and everything it started.
- Each run gets a folder in the exchange folder (`runs/<date>-<name>/`: `stdout.log`, `stderr.log`,
  `run.json`, written as it goes, `runs/latest` leads to the newest), and `MONAD_RUN_DIR` says
  where. Every run and refusal is in the command's log.

Without MCP, the command's socket or port speaks a line protocol (`nc -U` is enough):

```
→ run <values, quoted as a shell would>     (Monad's own parser: no expansion of any kind)
→ describe                                  (name, summary, arguments and patterns, one JSON line)
← monad-queued <n>
← monad-run <token>, then the program's output, then monad-exit <token> <status> <run folder>
← monad-refused <reason>
```

## The audit log

Every call, from the Mac or a VM: `~/.monad/agents/audit.log` (one line each: when, who, the tool,
its arguments, how it ended, how long it took; 1 MB, then the old one is kept as `.1`). Settings ›
Agents shows the latest. The arguments are kept as given (their first 500 characters): what an
agent wrote with `write_file` or ran with `exec`, tokens included if it typed them there.

An "Always Allow" for `clone_vm` on a VM lets it copy any stopped macOS VM, with its account,
password, keys and files, into a VM of its own. Making a macOS VM (`create_vm` with a macOS
distribution) always asks first, from the Mac and from a VM: it ends in the Mac's password prompt.
