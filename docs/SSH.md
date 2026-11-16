# SSH hosts

A tab can be a shell on a server reached over ssh, and ports are carried between such a server and
this Mac or a VM: set by hand, or by themselves once Monad's agent runs on the server. The servers
are listed in Virtual Machines › SSH, beside the VMs, and drawn on the canvas. The security side is
in [SECURITY.md](SECURITY.md) (SSH hosts); this is how it is built.

## An SSH host

| Field | What |
|---|---|
| `name` | Its name in Monad (letters, digits and dashes, 32 at most). Tabs, forwards and its Keychain item go by it; it cannot change. |
| `host`, `port`, `user` | A DNS name or an IP address, the port (22 unless said), the account. |
| `auth` | `password`, `key` or `generated` (below). |
| `keyPath` | `key` only: one private key file, by its full path. Left out: ssh's own keys and agent. |
| `jump` | Another SSH host to connect through (one level; that host is reached directly). |
| `keyInstalled` | `generated`: MonadHost saw the server accept Monad's key. |
| `forwards` | Ports and sockets between this Mac and the server, set by hand (below). Left out: none. |
| `agent` | Monad's agent is on the server, with your yes (below). Left out: no. |
| `autoForward` | With the agent: `minimumPort` (1024 or more) and `ignoredPorts`, as a VM's. Left out: from 1024, none skipped. |

MonadHost owns them: `~/.monad/ssh-hosts/<name>/host.json` (0600), read back as untrusted and
validated (`SSHHost.validate`), at most 64. The app mirrors them through `HostClient` and changes
them with requests (`setSSHHost`, `removeSSHHost`, …), like VMs. The same folder holds Monad's key
pair for that server (`id_ed25519`, `id_ed25519.pub`) and, while Monad is connected to it, its ssh
master's socket and log (`ctl.sock`, `ssh-master.log`). `~/.monad/ssh-hosts/known_hosts` holds the
host keys accepted in Monad.

Monad never reads `~/.ssh/config`: every ssh it runs for an SSH host is `/usr/bin/ssh -F none`
with the options built in one place (`SSHHost.sshArguments`).

### Signing in

- **Password:** ssh offers no key. The password is asked in Monad's panel, and kept in the login
  Keychain (service `dev.monad.ssh`, the host's name as the account) if you say so, or typed in the
  host's sheet. Only MonadHost reads it.
- **Private key:** ssh's own keys and agent, or one key file. A passphrase is asked in Monad's
  panel.
- **Key pair from Monad:** Monad makes an ed25519 pair for that server alone and installs its
  public half with `/usr/bin/ssh-copy-id`, which signs in with what this Mac already has (its
  keys, the agent) or asks for the password once. After that only Monad's key is offered. The
  server keeps the key in `authorized_keys` until you remove it there.

## Questions ssh asks

ssh never asks in a tab. Every ssh Monad starts for an SSH host has `SSH_ASKPASS_REQUIRE=force`
and MonadHost's own binary as `SSH_ASKPASS`, with a ticket in `MONAD_ASKPASS_TICKET`:

```
ssh ── runs ──▶ MonadHost (askpass mode: one argument, the prompt)
                 └─ XPC ──▶ the running MonadHost (SSHHostManager.ask)
                             ├─ the Keychain, for ssh's own password question
                             └─ the app's panel (SSHPromptPanel), for everything else
```

MonadHost issues a ticket for each ssh (`sshTicket` for a tab or an upload, its own for a master or
`ssh-copy-id`); it names the SSH host and lasts ten minutes. A question without a live ticket is
refused. A stored password answers only `user@host's password:` and `(user@host) Password:` for
that host (or the one it connects through), once per connection; the host key question, a
passphrase, a code or a second password question go to the panel. Unanswered, a question ends
after two minutes and ssh takes it as no answer.

## A tab

`SessionTarget.ssh(name)`: `TerminalSessionViewController.connectSSH` asks MonadHost for the host
and a ticket (installing Monad's key first when it is not on the server yet) and runs ssh on a
pty. Each tab is its own connection. A tab that loses its connection says so and waits for Return;
it does not sign in again by itself. Dropped files and pasted pictures are uploaded like a VM's
(`~/.monad/uploads`, `~/.monad/shots` on the server). The saved session keeps the tab by the host's
name and the directory its shell reported (OSC 7); a split of its pane starts there too. Monad
installs nothing on the server, so a shell that does not report its directory (docs/TABS.md)
opens again, and splits, in the home folder.

## A port between a VM and an SSH host

A VM's `sshForwards` ([CONFIG.md](CONFIG.md)), added in its Port Forwarding page (Add Forward ›
SSH Host) or with `add_ssh_forward`:

```
intoVM:    VM 127.0.0.1:guestPort ──▶ VM's ssh master (-R) ──▶ socket ──▶ SSH host's master (-L) ──▶ remoteHost:remotePort
ontoHost:  remoteHost:remotePort on the server ──▶ SSH host's master (-R) ──▶ socket ──▶ VM's master (-L) ──▶ VM 127.0.0.1:guestPort
```

The socket is `sshfwd-<id>.sock` in the VM's folder. The VM's half is one more forward on its
master (`VMInstance.applyForwards`); the server's half is kept by `SSHHostManager`, which runs one
ssh master per SSH host that carries anything (a `ForwardManager`, as for a VM), started when the
first VM needs it and ended with the last. A forward is up when both halves are; its row says
which is not. When the master cannot start (a question left unanswered, a key refused) or its
connection is lost and one new try fails, the forwards stay down until Connect Again in the host's
⋯ menu (or on the canvas), or until a VM's forwards through it change.

In Add Forward › SSH Host, "The server reaches" is typed or picked: the server itself, or another
of your SSH hosts by name, at the address Monad has for it (`VMSettingsDraft.reachChoices`).

## Ports between this Mac and an SSH host

An SSH host has forwards of its own, in its sheet under Port forwarding: a VM's rules
(`ForwardRule`: a server port on the Mac, a Mac port on the server, a SOCKS proxy that leaves from
the server, unix sockets), with the server in the VM's place and the same checks
(`InstanceConfig.validate(forwards:)`), 32 at most. A forward that lets the server reach this Mac,
or that other computers can reach, is asked about when it is added: the server's end is on its
loopback, so every account there reaches it.

They need no agent. The same master carries them (`SSHHostManager.reconcile`), and MonadHost
keeps it while it runs: it connects as it starts (`connectHosts`) to the hosts that have forwards
or the agent, and ends every master as it ends (`stopAll`), so no forward on a Mac port outlives
Monad. MonadHost runs while Monad is open or a VM runs. A host that asks (no password kept, a new
host key) asks in Monad's panel when Monad opens.

## Monad's agent on a server

"Forward ports automatically" in the host's sheet asks first (`SSHHostAgent.question`), since it
puts something on your server. With your yes, each time MonadHost connects it:

1. asks the server what it is (`uname -s`: Linux and macOS have an agent, anything else says so);
2. writes the agent to `~/.monad/monad-agent.sh` there (0600): the same script a VM runs
   (`monad-agent.sh`, or `monad-macos-agent.sh`), so it always matches this Monad;
3. runs it with `sh`, over the master (no second sign-in), its input and output one stream
   (`ProcessChannel`), read like a VM's agent (`AgentClient`, `AgentProtocol`).

The agent runs as the account Monad signs in as: nothing is installed as root, the server starts
nothing itself, and the agent ends with the connection. It only says which TCP ports the server
listens on, every two seconds. Those from 1024 up, on the loopback or on every address, come to
this Mac's localhost at the same port (`ForwardPlan`, as for a VM): 32 at most, lowest first,
never one in "Ports to skip", never over a port a Mac program listens on (the sheet then says
which program), and never a port a VM's forward put on the server (that one is the VM's).

- **Linux:** every listener on the server (`/proc/net/tcp`).
- **macOS:** netstat shows an account that is not root no TCP socket (macOS 27), so the agent
  reads lsof there: the listeners of that account's own programs.
- An agent that ends is run again, less and less often when it ends at once. A server Monad has
  no agent for is not asked again until Connect Again.
- Turning it off stops the agent and removes the script while Monad is still connected (otherwise
  the file stays, and nothing runs it). Removing the host does the same.

## On the canvas

Each SSH host is a card below the networks ([CANVAS.md](CANVAS.md)), kept where it is dragged
(`canvas.json`). A VM with forwards through a host that are on has a line to its card: teal while
they are up, dashed orange when one failed, dotted while the VM is not running. A click shows the
host's address, how Monad signs in, the forwards through it by VM, and its own (with how its agent
is doing); from there or its right-click a tab or a docked terminal opens on it, and its sheet for
its settings. New on the canvas, or a right-click on the ground, adds a host with the same sheet as
Virtual Machines › SSH. Notes, labels, zones and arrows name it `ssh:<name>`; they go with it when
it is removed. The canvas gets what the hosts' list gets (`SSHHostSnapshot`): never a key or a
password.
