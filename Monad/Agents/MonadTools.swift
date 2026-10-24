//
//  MonadTools.swift — Monad's MCP tools (agents phase): what an agent can
//  do with Monad, each through the same path the app takes (HostService's
//  requests, so every check the window gets applies: validation, share
//  rules, host limits), plus running commands and moving text files in a
//  running VM over its ssh. Each tool says how risky it is; MCPAccess
//  decides who may call it and when the user is asked.
//

import Foundation

@MainActor
final class MonadTools {
    private unowned let service: HostService
    private let connection: HostConnection
    private let distros: () -> DistroStore
    private let networks: NetworkStore
    private let discover: (ImageLink) async -> ImageDiscovery
    private var nextID: UInt64 = 0

    init(service: HostService, distros: @escaping () -> DistroStore, networks: NetworkStore = NetworkStore(),
         discover: @escaping (ImageLink) async -> ImageDiscovery = { await ImagePipeline.live.discover($0) }) {
        self.service = service
        self.distros = distros
        self.networks = networks
        self.discover = discover
        connection = service.internalConnection()
    }

    /// Exec and file tools: limits.
    static let maxExecSeconds = 600
    static let maxFileBytes = 1 << 20

    // MARK: Requests through HostService

    private func request(_ op: HostRequest.Op, name: String? = nil, config: InstanceConfig? = nil, force: Bool? = nil) async throws -> HostResponse {
        if nextID == 0 {
            nextID = 1
            _ = await connection.handle(HostRequest(id: 0, op: .hello, version: HostProtocol.version))
        }
        nextID += 1
        let r = await connection.handle(HostRequest(id: nextID, op: op, name: name, force: force, config: config))
        guard r.ok else { throw MonadError(r.error ?? "Monad could not do that.") }
        return r
    }

    private func vm(_ name: String) throws -> VMInstance {
        guard let vm = service.manager.existing(name) else { throw MonadError("There is no VM called \(name).") }
        return vm
    }

    /// Change a VM's settings through `update`, as its window does.
    private func update(_ name: String, _ change: (inout InstanceConfig) throws -> Void) async throws -> VMSnapshot {
        var config = try vm(name).config
        try change(&config)
        let r = try await request(.update, config: config)
        if let snap = r.instance { return snap }
        return service.snapshot(try vm(name))
    }

    // MARK: What agents see of a VM

    struct VMSummary: Encodable {
        let name: String
        let state: String
        let distro: String
        let release: String?
        let cpus: Int
        let memoryGiB: Int
        let diskGiB: Int
        let network: String?
        let group: String?
        let ephemeral: Bool
        let listening: [String]?
        let forwards: [String]?
        let pendingRestart: [String]?
    }

    func summary(_ s: VMSnapshot) -> VMSummary {
        VMSummary(name: s.name, state: s.state.label, distro: s.config.distro, release: s.config.release,
                  cpus: s.config.cpus, memoryGiB: s.config.memoryGiB, diskGiB: s.config.diskGiB,
                  network: s.config.networks.first?.network, group: s.config.group, ephemeral: s.config.ephemeral,
                  listening: s.ports.isEmpty ? nil : s.ports.map { "\($0.address):\($0.port)" },
                  forwards: s.forwards.map { $0.map { "\($0.flag) \($0.spec)" } },
                  pendingRestart: s.pendingRestart)
    }

    // MARK: Schemas

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func strings(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }

    private static let vmName = string("The VM's name.")

    // MARK: The tools

    /// Every tool, for any caller; MCPAccess narrows the list per caller.
    func all() -> [MCPTool] {
        [
            MCPTool(name: "list_vms", description: "List the VMs: name, state, distribution, size, network, forwards.",
                    schema: Self.schema([:]), risk: .read) { [unowned self] call in
                let r = try await self.request(.list)
                // An orchestrator sees itself and the VMs it made.
                let visible = (r.instances ?? []).filter { s in
                    guard case .vm(let me) = call.caller else { return true }
                    return s.name == me || s.config.parent == me
                }
                return .json(["vms": visible.map(self.summary)])
            },
            MCPTool(name: "get_vm", description: "One VM's settings and state in full.",
                    schema: Self.schema(["name": Self.vmName], required: ["name"]), risk: .read) { [unowned self] call in
                let s = self.service.snapshot(try self.vm(try call.string("name")))
                return .json(s)
            },
            MCPTool(name: "create_vm",
                    description: "Create a VM from an installed distribution (list_distros) and, unless start is false, start it. "
                        + "It is ready for exec once its state is Running.",
                    schema: Self.schema([
                        "name": Self.string("Letters, digits and dashes, up to 32."),
                        "distro": Self.string("A distribution id from list_distros (default: Monad's default)."),
                        "release": Self.string("A release id of that distribution (default: its default)."),
                        "cpus": Self.integer("CPU cores."), "memory_gib": Self.integer("Memory in GiB."),
                        "disk_gib": Self.integer("Disk size in GiB."),
                        "network": Self.string("A network name from list_networks (default: default)."),
                        "profiles": Self.strings("Profiles to set up (agentic, server, …)."),
                        "start": Self.boolean("Start it once made (default true)."),
                    ], required: ["name"]), risk: .normal) { [unowned self] call in
                var c = InstanceConfig.defaults(name: try call.string("name"))
                if let d = try call.optionalString("distro") { c.distro = d; c.release = nil }
                if let r = try call.optionalString("release") { c.release = r }
                if let v = try call.optionalInt("cpus") { c.cpus = v }
                if let v = try call.optionalInt("memory_gib") { c.memoryGiB = v }
                if let v = try call.optionalInt("disk_gib") { c.diskGiB = v }
                if let n = try call.optionalString("network") { c.networks = [NetworkAttachment(network: n, macAddress: nil)] }
                let profiles = try call.strings("profiles")
                if !profiles.isEmpty { c.profiles = profiles }
                if case .vm(let parent) = call.caller { try self.makeChild(&c, of: parent) }
                let r = try await self.request(.create, config: c)
                if try call.optionalBool("start") ?? true { _ = try await self.request(.start, name: c.name) }
                let snap = try r.instance ?? self.service.snapshot(self.vm(c.name))
                return .json(self.summary(snap))
            },
            MCPTool(name: "start_vm", description: "Start a VM.", schema: Self.schema(["name": Self.vmName], required: ["name"]),
                    risk: .normal) { [unowned self] call in
                .json(self.summary(try await self.request(.start, name: try call.string("name")).instance!))
            },
            MCPTool(name: "stop_vm", description: "Shut a VM down (force: power it off at once).",
                    schema: Self.schema(["name": Self.vmName, "force": Self.boolean("Power off without a clean shutdown.")],
                                        required: ["name"]), risk: .normal) { [unowned self] call in
                .json(self.summary(try await self.request(.stop, name: try call.string("name"),
                                                          force: try call.optionalBool("force")).instance!))
            },
            MCPTool(name: "restart_vm", description: "Restart a VM (picks up settings that wait for a restart).",
                    schema: Self.schema(["name": Self.vmName], required: ["name"]), risk: .normal) { [unowned self] call in
                .json(self.summary(try await self.request(.restart, name: try call.string("name")).instance!))
            },
            MCPTool(name: "delete_vm", description: "Delete a VM and its disk. It cannot be undone.",
                    schema: Self.schema(["name": Self.vmName], required: ["name"]), risk: .risky) { [unowned self] call in
                let name = try call.string("name")
                _ = try await self.request(.delete, name: name)
                return MCPResult(text: "Deleted \(name).")
            },
            MCPTool(name: "clone_vm",
                    description: "Copy a stopped macOS VM: the same system, account and files, with a machine identity of its own "
                        + "(its disk is cloned, so it takes no room until it changes). Shared folders, bridges, host commands, "
                        + "forwards into the Mac and an agent role stay with the original.",
                    schema: Self.schema(["name": Self.vmName,
                                         "new_name": Self.string("The copy's name: letters, digits and dashes, up to 32."),
                                         "start": Self.boolean("Start the copy once made (default false).")],
                                        required: ["name", "new_name"]), risk: .normal) { [unowned self] call in
                let copy = try self.vm(try call.string("name")).config.copy(named: try call.string("new_name"))
                var c = copy.config
                let left = copy.left
                if case .vm(let parent) = call.caller { try self.makeChild(&c, of: parent) }
                _ = try await self.request(.clone, name: try call.string("name"), config: c)
                var snap = try self.service.snapshot(self.vm(c.name))
                if try call.optionalBool("start") ?? false { snap = try await self.request(.start, name: c.name).instance ?? snap }
                var result = MCPResult.json(self.summary(snap))
                if !left.isEmpty {
                    result.text += "\nNot copied (add them to \(c.name) if it needs them): \(left.joined(separator: ", "))."
                }
                return result
            },
            MCPTool(name: "read_vm_log",
                    description: "A VM's log: what Monad did with it (boots, recovery steps, settings applied, errors), its "
                        + "last lines, oldest first.",
                    schema: Self.schema(["name": Self.vmName, "lines": Self.integer("How many (default 100, at most 2000).")],
                                        required: ["name"]), risk: .read) { [unowned self] call in
                let vm = try self.vm(try call.string("name"))
                let count = min(max(try call.optionalInt("lines") ?? 100, 1), 2000)
                vm.log.flush()
                let lines = VMLog.read(vm.paths.vmLog).split(separator: "\n", omittingEmptySubsequences: true)
                return MCPResult(text: lines.suffix(count).joined(separator: "\n"))
            },
            MCPTool(name: "exec",
                    description: "Run a shell command in a running VM as its user and return its exit status, stdout and stderr "
                        + "(each up to 1 MB). At most \(Self.maxExecSeconds) seconds.",
                    schema: Self.schema(["name": Self.vmName, "command": Self.string("The command, run by the user's shell."),
                                         "stdin": Self.string("Text given as its input."),
                                         "timeout_seconds": Self.integer("Up to \(Self.maxExecSeconds) (default 120).")],
                                        required: ["name", "command"]), risk: .normal) { [unowned self] call in
                let timeout = min(max(try call.optionalInt("timeout_seconds") ?? 120, 1), Self.maxExecSeconds)
                let r = try await self.vm(try call.string("name")).guestRun(try call.string("command"),
                                                                            stdin: try call.optionalString("stdin").map { Data($0.utf8) },
                                                                            timeout: TimeInterval(timeout))
                struct Out: Encodable { let status: Int32; let stdout: String; let stderr: String; let truncated: Bool }
                var result = MCPResult.json(Out(status: r.status, stdout: r.stdoutString, stderr: r.stderrString,
                                                truncated: r.outputTruncated))
                result.isError = r.status != 0
                return result
            },
            MCPTool(name: "read_file", description: "Read a text file in a running VM (up to 1 MB).",
                    schema: Self.schema(["name": Self.vmName, "path": Self.string("The file's path in the VM.")],
                                        required: ["name", "path"]), risk: .normal) { [unowned self] call in
                let path = try Self.guestPath(try call.string("path"))
                let r = try await self.vm(try call.string("name")).guestRun("head -c \(Self.maxFileBytes + 1) -- \(Self.quoted(path))", timeout: 60)
                guard r.status == 0 else { throw MonadError(r.stderrString.isEmpty ? "Cannot read \(path)." : r.stderrString) }
                guard r.stdout.count <= Self.maxFileBytes else { throw MonadError("\(path) is larger than 1 MB.") }
                return MCPResult(text: r.stdoutString)
            },
            MCPTool(name: "write_file", description: "Write a text file in a running VM (up to 1 MB), replacing it.",
                    schema: Self.schema(["name": Self.vmName, "path": Self.string("The file's path in the VM."),
                                         "content": Self.string("The text to write.")],
                                        required: ["name", "path", "content"]), risk: .normal) { [unowned self] call in
                let path = try Self.guestPath(try call.string("path"))
                let content = Data(try call.string("content").utf8)
                guard content.count <= Self.maxFileBytes else { throw MonadError("At most 1 MB.") }
                let r = try await self.vm(try call.string("name")).guestRun("cat > \(Self.quoted(path))", stdin: content, timeout: 60)
                guard r.status == 0 else { throw MonadError(r.stderrString.isEmpty ? "Cannot write \(path)." : r.stderrString) }
                return MCPResult(text: "Wrote \(content.count) bytes to \(path).")
            },
            MCPTool(name: "list_distros", description: "The distributions VMs can be made from, with their releases.",
                    schema: Self.schema([:]), risk: .read) { [unowned self] _ in
                struct D: Encodable { let id, name: String; let releases: [String]; let defaultRelease: String; let added: Bool }
                let catalog = self.distros().catalog
                return .json(["distros": catalog.distros.map {
                    D(id: $0.id, name: $0.name, releases: $0.releases.map(\.id), defaultRelease: $0.defaultRelease.id,
                      added: catalog.added[$0.id] != nil)
                }])
            },
            MCPTool(name: "add_distro",
                    description: "Add a distribution from a cloud image's address (.qcow2, .img, .raw, also .xz or .gz) for arm64. "
                        + "Monad looks next to it for its checksums and signature.",
                    schema: Self.schema(["link": Self.string("The image's https address."),
                                         "name": Self.string("Its name (default: from the file name)."),
                                         "release": Self.string("Its version (default: from the file name)."),
                                         "package_manager": Self.string("apt, dnf or zypper, so profiles can install packages."),
                                         "public_key": Self.string("The project's armored OpenPGP key, to check the signature.")],
                                        required: ["link"]), risk: .risky) { [unowned self] call in
                let link = try ImageLink(try call.string("link"))
                guard !link.isLocal else { throw MonadError("Give an http or https address.") }
                var draft = DistroDraft()
                draft.use(link, found: await self.discover(link))
                if let n = try call.optionalString("name") { draft.name = n }
                if let r = try call.optionalString("release") { draft.basicRelease = r }
                if let pm = try call.optionalString("package_manager") { draft.packageManager = pm }
                if let key = try call.optionalString("public_key") { draft.setKey(key) }
                if let problem = draft.problems.values.first { throw MonadError(problem) }
                try self.distros().add(try draft.json())
                let c = try draft.config()
                let how = c.image.checksums == nil ? "used as it is (no checksum file next to it)"
                    : c.isSigned ? "checked against its signed checksums" : "checked against its checksums"
                return MCPResult(text: "Added \(c.name) (\(c.id)), release \(c.defaultRelease.id). Its image is \(how).")
            },
            MCPTool(name: "remove_distro", description: "Remove a distribution that was added (none of Monad's own).",
                    schema: Self.schema(["id": Self.string("The distribution's id.")], required: ["id"]), risk: .risky) { [unowned self] call in
                let id = try call.string("id")
                let users = self.service.manager.instances.filter { $0.config.distro == id }.map(\.name)
                try self.distros().remove(id, usedBy: users)
                return MCPResult(text: "Removed \(id).")
            },
            MCPTool(name: "list_networks", description: "The networks VMs can join: kind, subnet, whether VMs on it reach each other.",
                    schema: Self.schema([:]), risk: .read) { [unowned self] _ in
                .json(["networks": try self.networks.all()])
            },
            MCPTool(name: "list_connections", description: "What a VM connected to, and what its firewall said (most recent first).",
                    schema: Self.schema(["name": Self.vmName], required: ["name"]), risk: .read) { [unowned self] call in
                .json(["connections": try await self.request(.connections, name: try call.string("name")).connections ?? []])
            },
            MCPTool(name: "add_forward",
                    description: "Make a VM's port or socket reachable on this Mac (local: Mac port to VM port; socks: a SOCKS proxy "
                        + "whose traffic leaves from the VM; unixLocal: Mac socket to VM socket).",
                    schema: Self.schema(["name": Self.vmName, "kind": Self.string("local, socks or unixLocal."),
                                         "host_port": Self.integer("Port on this Mac (local, socks)."),
                                         "guest_port": Self.integer("Port in the VM (local)."),
                                         "host_socket": Self.string("Socket path on this Mac (unixLocal)."),
                                         "guest_socket": Self.string("Socket path in the VM (unixLocal).")],
                                        required: ["name", "kind"]), risk: .normal) { [unowned self] call in
                let rule = try Self.forward(call, allowed: [.local, .socks, .unixLocal])
                return .json(self.summary(try await self.update(try call.string("name")) { $0.forwards.append(rule) }))
            },
            MCPTool(name: "add_mac_forward",
                    description: "Let a VM reach this Mac: remote (a VM port to a Mac port) or unixRemote (a VM socket to a Mac socket).",
                    schema: Self.schema(["name": Self.vmName, "kind": Self.string("remote or unixRemote."),
                                         "host_port": Self.integer("Port on this Mac (remote)."),
                                         "guest_port": Self.integer("Port in the VM (remote)."),
                                         "host_socket": Self.string("Socket path on this Mac (unixRemote)."),
                                         "guest_socket": Self.string("Socket path in the VM (unixRemote).")],
                                        required: ["name", "kind"]), risk: .risky) { [unowned self] call in
                let rule = try Self.forward(call, allowed: [.remote, .unixRemote])
                return .json(self.summary(try await self.update(try call.string("name")) { $0.forwards.append(rule) }))
            },
            MCPTool(name: "remove_forward", description: "Remove a forward of a VM, by its place in get_vm's config.forwards (from 0).",
                    schema: Self.schema(["name": Self.vmName, "index": Self.integer("Its index.")], required: ["name", "index"]),
                    risk: .normal) { [unowned self] call in
                let i = try call.int("index")
                return .json(self.summary(try await self.update(try call.string("name")) {
                    guard $0.forwards.indices.contains(i) else { throw MonadError("There is no forward \(i).") }
                    $0.forwards.remove(at: i)
                }))
            },
            MCPTool(name: "block_destination", description: "A firewall rule denying a VM a destination (name, *.name or address/prefix).",
                    schema: Self.firewallSchema, risk: .normal) { [unowned self] call in
                let rule = try Self.firewallRule(call, action: .deny)
                return .json(self.summary(try await self.update(try call.string("name")) { $0.firewall.rules.insert(rule, at: 0) }))
            },
            MCPTool(name: "allow_destination", description: "A firewall rule allowing a VM a destination (name, *.name or address/prefix).",
                    schema: Self.firewallSchema, risk: .risky) { [unowned self] call in
                let rule = try Self.firewallRule(call, action: .allow)
                return .json(self.summary(try await self.update(try call.string("name")) { $0.firewall.rules.insert(rule, at: 0) }))
            },
            MCPTool(name: "remove_firewall_rule", description: "Remove a firewall rule of a VM, by its place in config.firewall.rules (from 0).",
                    schema: Self.schema(["name": Self.vmName, "index": Self.integer("Its index.")], required: ["name", "index"]),
                    risk: .normal) { [unowned self] call in
                let i = try call.int("index")
                return .json(self.summary(try await self.update(try call.string("name")) {
                    guard $0.firewall.rules.indices.contains(i) else { throw MonadError("There is no rule \(i).") }
                    $0.firewall.rules.remove(at: i)
                }))
            },
            MCPTool(name: "add_share",
                    description: "Share a folder of this Mac with a VM (read-only unless read_only is false). The VM gets the "
                        + "shared folder device at its next restart if it has none.",
                    schema: Self.schema(["name": Self.vmName, "host_path": Self.string("The folder on this Mac."),
                                         "guest_path": Self.string("Where it appears in the VM."),
                                         "read_only": Self.boolean("Default true.")], required: ["name", "host_path", "guest_path"]),
                    risk: .risky) { [unowned self] call in
                let share = SharedFolder(hostPath: try call.string("host_path"), guestPath: try call.string("guest_path"),
                                         readOnly: try call.optionalBool("read_only") ?? true, confirmed: true)
                return .json(self.summary(try await self.update(try call.string("name")) {
                    $0.sharing.runtimeEnabled = true
                    $0.sharing.shares.append(share)
                }))
            },
            MCPTool(name: "remove_share", description: "Stop sharing a folder with a VM, by its host path.",
                    schema: Self.schema(["name": Self.vmName, "host_path": Self.string("The folder on this Mac.")],
                                        required: ["name", "host_path"]), risk: .normal) { [unowned self] call in
                let path = SharePolicy.resolve(try call.string("host_path"))
                return .json(self.summary(try await self.update(try call.string("name")) {
                    $0.sharing.shares.removeAll { SharePolicy.resolve($0.hostPath) == path }
                }))
            },
            MCPTool(name: "add_bridge",
                    description: "A bridge: each connection to a port or socket in the VM runs a program on this Mac with the "
                        + "connection as its input and output (for example xcrun mcpbridge).",
                    schema: Self.schema(["name": Self.vmName, "bridge": Self.string("The bridge's name."),
                                         "command": Self.strings("The program by its full path, then its arguments."),
                                         "guest_port": Self.integer("A port in the VM, 1024 to 65535."),
                                         "guest_socket": Self.string("Or a socket path in the VM.")],
                                        required: ["name", "bridge", "command"]), risk: .risky) { [unowned self] call in
                let bridge = CommandBridge(name: try call.string("bridge"), command: try call.strings("command"),
                                           guestPort: try call.optionalInt("guest_port"), guestSocket: try call.optionalString("guest_socket"))
                return .json(self.summary(try await self.update(try call.string("name")) { $0.bridges.append(bridge) }))
            },
            MCPTool(name: "remove_bridge", description: "Remove a bridge of a VM, by its name.",
                    schema: Self.schema(["name": Self.vmName, "bridge": Self.string("The bridge's name.")], required: ["name", "bridge"]),
                    risk: .normal) { [unowned self] call in
                let b = try call.string("bridge")
                return .json(self.summary(try await self.update(try call.string("name")) { $0.bridges.removeAll { $0.name == b } }))
            },
            MCPTool(name: "add_host_command",
                    description: "A host command: a program on this Mac the VM runs with values it gives, each checked against "
                        + "a pattern (from ^ to $) before anything runs; it runs in a folder the VM shares.",
                    schema: Self.schema([
                        "name": Self.vmName, "command": Self.string("The host command's name (lowercase, digits, dashes)."),
                        "summary": Self.string("One sentence for agents."),
                        "program": Self.string("The program by its full path."),
                        "fixed_arguments": Self.strings("Always passed first."),
                        "arguments": .object(["type": .string("array"), "description": .string("The values the VM may give, in order."),
                                              "items": Self.schema(["name": Self.string("lowercase"), "pattern": Self.string("^…$"),
                                                                    "required": Self.boolean("Default true."),
                                                                    "summary": Self.string("For agents.")], required: ["name", "pattern"])]),
                        "working_directory": Self.string("A folder inside one this VM shares."),
                        "timeout_seconds": Self.integer("1 to 86400 (default 3600)."),
                        "guest_port": Self.integer("A port in the VM, 1024 to 65535."),
                        "guest_socket": Self.string("Or a socket path in the VM."),
                        "environment": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")])]),
                    ], required: ["name", "command", "program", "working_directory"]), risk: .risky) { [unowned self] call in
                let command = try Self.hostCommand(call)
                return .json(self.summary(try await self.update(try call.string("name")) { $0.hostCommands.append(command) }))
            },
            MCPTool(name: "set_agent_role",
                    description: "What a VM may do with Monad itself: none, hostCommands (its host commands as MCP tools) or "
                        + "orchestrator (it makes and runs VMs of its own, asks the user for more). Its agents find Monad at "
                        + "127.0.0.1:<port> in the VM.",
                    schema: Self.schema(["name": Self.vmName, "role": Self.string("none, hostCommands or orchestrator."),
                                         "port": Self.integer("The MCP port in the VM (default 7766)."),
                                         "max_children": Self.integer("Orchestrator: VMs of its own at once (default 4)."),
                                         "child_cpus": Self.integer("Orchestrator: CPUs for them together."),
                                         "child_memory_gib": Self.integer("Orchestrator: memory for them together.")],
                                        required: ["name", "role"]), risk: .risky) { [unowned self] call in
                let role = try call.string("role")
                var access: AgentAccess?
                if role != "none" {
                    guard let r = AgentAccess.Role(rawValue: role) else { throw MonadError("role is none, hostCommands or orchestrator.") }
                    access = AgentAccess(role: r, guestPort: try call.optionalInt("port") ?? AgentAccess.defaultPort,
                                         maxChildren: try call.optionalInt("max_children") ?? 4,
                                         childCPUs: try call.optionalInt("child_cpus"), childMemoryGiB: try call.optionalInt("child_memory_gib"))
                }
                return .json(self.summary(try await self.update(try call.string("name")) { $0.agents = access }))
            },
            MCPTool(name: "remove_host_command", description: "Remove a host command of a VM, by its name.",
                    schema: Self.schema(["name": Self.vmName, "command": Self.string("The host command's name.")], required: ["name", "command"]),
                    risk: .normal) { [unowned self] call in
                let c = try call.string("command")
                return .json(self.summary(try await self.update(try call.string("name")) { $0.hostCommands.removeAll { $0.name == c } }))
            },
        ] + networkTools() + canvasTools() + debugTools()
    }

    // MARK: Networks and firewalls

    private func networkTools() -> [MCPTool] {
        [
            MCPTool(name: "create_network",
                    description: "Make a network VMs can join (create_vm's network): nat reaches the internet through this Mac, "
                        + "host-only reaches only this Mac, internal and none reach nothing outside. VMs on it reach each other "
                        + "when vms_reach_each_other is on (the default for internal and none, off for nat and host-only).",
                    schema: Self.schema(["name": Self.string("Lowercase letters, digits and dashes, up to 32."),
                                         "kind": Self.string("nat (default), host-only, internal or none."),
                                         "subnet": Self.string("A private IPv4 range such as 10.80.0.0/24 (default: the first free 10.N.0.0/24)."),
                                         "vms_reach_each_other": Self.boolean("Whether its VMs reach each other.")],
                                        required: ["name"]), risk: .normal) { [unowned self] call in
                let name = try call.string("name")
                let kindText = try call.optionalString("kind") ?? "nat"
                guard let kind = NetworkDefinition.Kind(rawValue: kindText) else {
                    throw MonadError("kind is nat, host-only, internal or none.")
                }
                let all = try self.networks.all()
                guard !all.contains(where: { $0.name == name }), name != NetworkDefinition.appleNATName else {
                    throw MonadError("A network named \(name) already exists.")
                }
                let subnet = try call.optionalString("subnet")
                    ?? (78...254).lazy.map { "10.\($0).0.0/24" }.first { s in !all.contains { Self.overlap($0.subnet, s) } }
                    ?? "10.254.0.0/24"
                if let taken = all.first(where: { Self.overlap($0.subnet, subnet) }) {
                    throw MonadError("\(subnet) overlaps \(taken.name)'s \(taken.subnet).")
                }
                var n = NetworkDefinition(name: name, kind: kind, subnet: subnet)
                if let peers = try call.optionalBool("vms_reach_each_other") { n.vmsReachEachOther = peers }
                try self.networks.save(n)
                return .json(n)
            },
            MCPTool(name: "delete_network", description: "Delete a network no VM is on (never the default one).",
                    schema: Self.schema(["name": Self.string("The network's name.")], required: ["name"]),
                    risk: .normal) { [unowned self] call in
                let name = try call.string("name")
                guard try self.networks.network(named: name) != nil else { throw MonadError("There is no network called \(name).") }
                let users = self.service.manager.instances.filter { $0.config.networks.contains { $0.network == name } }.map(\.name)
                guard users.isEmpty else {
                    throw MonadError("\(users.joined(separator: ", ")) \(users.count == 1 ? "is" : "are") on \(name). Move or delete them first.")
                }
                try self.networks.delete(named: name)
                return MCPResult(text: "Deleted \(name).")
            },
            MCPTool(name: "set_group",
                    description: "Put a VM in a group of the Virtual Machines list (coding, analysis, agents, …), or in none "
                        + "with an empty group. A group works as a firewall tag: the rules of the tag named like the group "
                        + "apply to every VM in it.",
                    schema: Self.schema(["name": Self.vmName,
                                         "group": Self.string("Letters, digits, - and _, up to 32; empty for none.")],
                                        required: ["name", "group"]), risk: .risky) { [unowned self] call in
                // Risky: the group's tag may allow what the VM's own rules do not.
                let group = try call.string("group")
                guard group.isEmpty || VMGroups.isValidName(group) else {
                    throw MonadError("“\(group.prefix(40))” is not a group name: letters, digits, - and _, up to 32.")
                }
                return .json(self.summary(try await self.update(try call.string("name")) { $0.group = group.isEmpty ? nil : group }))
            },
            MCPTool(name: "restrict_vm",
                    description: "Tighten a VM's firewall: only what its rules allow (no internet unless a rule allows it), "
                        + "and unless block_lan is false, nothing on this Mac's network or the Mac. VMs on the same Monad network "
                        + "with vms_reach_each_other still reach it (that is the network, not the firewall).",
                    schema: Self.schema(["name": Self.vmName, "block_lan": Self.boolean("Block this Mac and its network too (default true).")],
                                        required: ["name"]), risk: .normal) { [unowned self] call in
                let blockLAN = try call.optionalBool("block_lan") ?? true
                return .json(self.summary(try await self.update(try call.string("name")) {
                    $0.firewall.allowlist = true
                    $0.firewall.monitor = false
                    if blockLAN { $0.firewall.allowLAN = false }
                }))
            },
            MCPTool(name: "set_macos_security",
                    description: "A macOS VM's Security page: System Integrity Protection, full disk access for Monad's sessions, "
                        + "logging in automatically, and booting to recovery once. Only what is given changes. SIP and boot to "
                        + "recovery apply at the next start (recovery is a few minutes; turning SIP on needs the internet in the VM).",
                    schema: Self.schema(["name": Self.vmName,
                                         "sip": Self.boolean("System Integrity Protection on."),
                                         "full_disk_access": Self.boolean("Monad's sessions read protected folders (Documents, …)."),
                                         "auto_login": Self.boolean("It logs in by itself at boot."),
                                         "boot_to_recovery": Self.boolean("The next start opens recovery and its desktop (once).")],
                                        required: ["name"]), risk: .risky) { [unowned self] call in
                let sip = try call.optionalBool("sip"), access = try call.optionalBool("full_disk_access")
                let login = try call.optionalBool("auto_login"), recovery = try call.optionalBool("boot_to_recovery")
                return .json(self.summary(try await self.update(try call.string("name")) {
                    guard $0.guestOS == .macos else { throw MonadError("\($0.name) is not a macOS VM.") }
                    if let sip { $0.systemIntegrityProtection = sip }
                    if let access { $0.fullDiskAccess = access }
                    if let login { $0.autoLogin = login }
                    if let recovery { $0.bootToRecovery = recovery }
                }))
            },
            MCPTool(name: "set_firewall",
                    description: "Set a VM's firewall: only_allowed (only what its rules allow), allow_lan (this Mac and its network), "
                        + "ask (the user is asked about each new destination). Each left out stays as it is.",
                    schema: Self.schema(["name": Self.vmName, "only_allowed": Self.boolean("Only what its rules allow."),
                                         "allow_lan": Self.boolean("Reach this Mac and its network."),
                                         "ask": Self.boolean("Ask the user about new destinations (monitor mode).")],
                                        required: ["name"]), risk: .risky) { [unowned self] call in
                let only = try call.optionalBool("only_allowed"), lan = try call.optionalBool("allow_lan")
                let ask = try call.optionalBool("ask")
                return .json(self.summary(try await self.update(try call.string("name")) {
                    if let only { $0.firewall.allowlist = only }
                    if let lan { $0.firewall.allowLAN = lan }
                    if let ask { $0.firewall.monitor = ask }
                }))
            },
        ]
    }

    /// Whether two subnets share addresses.
    static func overlap(_ a: String, _ b: String) -> Bool {
        guard let x = NetworkDefinition.parseCIDR(a), let y = NetworkDefinition.parseCIDR(b) else { return false }
        let prefix = min(x.prefix, y.prefix)
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        return x.address & mask == y.address & mask
    }

    // MARK: The canvas

    /// A note as agents see it.
    struct NoteOut: Encodable {
        let id: String
        let kind: String
        let text: String
        let color: String
        let on: String?
        let to: String?
        let around: [String]?
        let x, y, width, height: Double?
        let points: Int?
        let author: String

        init(_ n: CanvasNote) {
            id = n.id
            kind = n.kind.rawValue
            text = n.text
            color = n.tint.rawValue
            on = n.on
            to = n.to
            around = n.around
            x = n.frame.map { Double($0.minX) }
            y = n.frame.map { Double($0.minY) }
            width = n.frame.map { Double($0.width) }
            height = n.frame.map { Double($0.height) }
            points = n.points?.count
            author = n.author
        }
    }

    private static let refHelp = "A VM or network by name, or vm:<name>, net:<name>, note:<id>, mac or internet."

    /// Tools for working on Monad itself: in Debug builds only.
    private func debugTools() -> [MCPTool] {
        #if DEBUG
        [
            MCPTool(name: "read_recovery_screens",
                    description: "A macOS VM's screen as each of recovery's waits ended, from Monad's last run there (changing "
                        + "SIP): their names, and one of them as a picture (the last by default).",
                    schema: Self.schema(["name": Self.vmName, "screen": Self.string("A name from the list.")],
                                        required: ["name"]), risk: .read) { [unowned self] call in
                let dir = try self.vm(try call.string("name")).paths.recoveryScreens
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }
                    .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                guard let shown = try call.optionalString("screen") ?? names.last else {
                    return MCPResult(text: "There are no recovery screens: Monad has not changed SIP in this VM since it kept them.")
                }
                guard names.contains(shown) else { throw MonadError("There is no recovery screen “\(shown)”.") }
                var result = MCPResult(text: "Screens: \(names.joined(separator: ", ")). Shown: \(shown).")
                result.images = [try Data(contentsOf: dir.appendingPathComponent("\(shown).png"))]
                return result
            }
        ]
        #else
        []
        #endif
    }

    private func canvasTools() -> [MCPTool] {
        let noteFields: [String: JSONValue] = [
            "text": Self.string("Its words (Markdown in notes; a label up to \(CanvasNote.maxLabel) characters)."),
            "color": Self.string(CanvasNote.Tint.allCases.map(\.rawValue).joined(separator: ", ") + "."),
            "on": Self.string("label: the VM or network it is on; note: what it is pinned beside; arrow: where it starts. " + Self.refHelp),
            "to": Self.string("arrow: where it ends. " + Self.refHelp),
            "around": Self.strings("zone: the VMs and networks it wraps (it follows them)."),
            "x": Self.number("note, zone: left edge on the canvas (list_canvas shows where things are)."),
            "y": Self.number("note, zone: top edge."), "width": Self.number("note, zone: width."),
            "height": Self.number("note, zone: height."),
        ]
        return [
            MCPTool(name: "list_canvas",
                    description: "What Monad's canvas shows: the VMs (by network) and networks, where each is, and the notes, "
                        + "labels, zones, arrows and ink written on it.",
                    schema: Self.schema([:]), risk: .read) { [unowned self] _ in
                struct Place: Encodable { let name: String; let network: String?; let x, y, width, height: Double? }
                let layout = CanvasStore().load()
                func place(_ name: String, _ network: String?, _ r: CGRect?) -> Place {
                    Place(name: name, network: network, x: r.map { Double($0.minX) }, y: r.map { Double($0.minY) },
                          width: r.map { Double($0.width) }, height: r.map { Double($0.height) })
                }
                let vms = self.service.manager.instances.map { vm in
                    place(vm.name, vm.config.networks.first?.network,
                          layout.nodes[vm.name].map(CanvasModel.nodeRect))
                }
                let networks = try self.networks.all().map { place($0.name, nil, layout.frames[$0.name]) }
                struct Out: Encodable { let vms: [Place]; let networks: [Place]; let notes: [NoteOut] }
                return .json(Out(vms: vms, networks: networks, notes: self.service.notes.map(NoteOut.init)))
            },
            MCPTool(name: "add_note",
                    description: "Write on Monad's canvas, where the user sees it at once: a note (Markdown on a card, free or "
                        + "pinned beside a VM or network), a label (a short chip on a VM or network), a zone (a titled area "
                        + "around VMs and networks, or at x, y, width, height) or an arrow with words between two things.",
                    schema: Self.schema(noteFields.merging(["kind": Self.string("note (default), label, zone or arrow.")]) { a, _ in a }),
                    risk: .normal) { [unowned self] call in
                let kindText = try call.optionalString("kind") ?? "note"
                guard let kind = CanvasNote.Kind(rawValue: kindText), kind != .ink else {
                    throw MonadError("kind is note, label, zone or arrow.")
                }
                var n = CanvasNote(id: CanvasNote.newID(), kind: kind)
                try self.apply(call, to: &n)
                let saved = try self.service.setNote(n, author: MCPGrants.key(call.caller))
                return .json(["id": saved.id])
            },
            MCPTool(name: "edit_note",
                    description: "Change a note, label, zone or arrow on the canvas by its id (list_canvas); what is left out "
                        + "stays. An empty on unpins a note.",
                    schema: Self.schema(noteFields.merging(["id": Self.string("Its id.")]) { a, _ in a }, required: ["id"]),
                    risk: .normal) { [unowned self] call in
                let id = try call.string("id")
                guard var n = self.service.notes.first(where: { $0.id == id }) else {
                    throw MonadError("There is no note \(id) on the canvas.")
                }
                try self.apply(call, to: &n)
                try self.service.setNote(n, author: MCPGrants.key(call.caller))
                return MCPResult(text: "Changed \(id).")
            },
            MCPTool(name: "remove_note", description: "Remove a note, label, zone, arrow or ink from the canvas by its id.",
                    schema: Self.schema(["id": Self.string("Its id.")], required: ["id"]), risk: .normal) { [unowned self] call in
                let id = try call.string("id")
                try self.service.removeNote(id)
                return MCPResult(text: "Removed \(id).")
            },
        ]
    }

    private static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    /// The call's fields on a note, things named plainly made refs.
    private func apply(_ call: MCPCall, to n: inout CanvasNote) throws {
        let vms = service.manager.instances.map(\.name)
        let networks = (try? self.networks.all().map(\.name)) ?? []
        func ref(_ text: String) throws -> String {
            guard let r = CanvasRef.resolve(text, vms: vms, networks: networks) else {
                throw MonadError("“\(text.prefix(40))” is not on the canvas. " + Self.refHelp)
            }
            return r
        }
        if let t = try call.optionalString("text") { n.text = t }
        if let c = try call.optionalString("color") {
            guard let tint = CanvasNote.Tint(rawValue: c) else {
                throw MonadError("color is " + CanvasNote.Tint.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            n.tint = tint
        }
        if let on = try call.optionalString("on") { n.on = on.isEmpty ? nil : try ref(on) }
        if let to = try call.optionalString("to") { n.to = try ref(to) }
        if call.arguments["around"] != nil { n.around = try call.strings("around").map(ref) }
        let x = try call.optionalNumber("x"), y = try call.optionalNumber("y")
        let w = try call.optionalNumber("width"), h = try call.optionalNumber("height")
        if x != nil || y != nil || w != nil || h != nil {
            let current = n.frame ?? CGRect(origin: .zero, size: CanvasNotesLayout.size(of: n.text))
            n.frame = CGRect(x: x ?? current.minX, y: y ?? current.minY, width: w ?? current.width, height: h ?? current.height)
        }
    }

    // MARK: Host commands as tools

    /// A host command's run as the tools see it: output so far (the last
    /// 256 KB), how it ended, its folder in the VM.
    final class Run: @unchecked Sendable {
        let id: String
        let vm: String
        let command: String
        let started = Date()
        private let lock = NSLock()
        private var output = Data()
        private var _status: Int32?
        private var _timedOut = false
        private var _folder: String?
        private var _refused: String?
        static let keep = 256 << 10

        init(id: String, vm: String, command: String) {
            self.id = id
            self.vm = vm
            self.command = command
        }

        func apply(_ e: HostCommandServer.Event) {
            lock.withLock {
                switch e {
                case .queued: break
                case .started(_, let folder): _folder = folder
                case .output(let d):
                    output.append(d)
                    if output.count > Self.keep { output.removeFirst(output.count - Self.keep) }
                case .exit(let status, let timedOut, let folder):
                    _status = status
                    _timedOut = timedOut
                    _folder = folder ?? _folder
                case .refused(let why):
                    _refused = why
                    _status = -1
                }
            }
        }

        var done: Bool { lock.withLock { _status != nil } }

        struct Report: Encodable {
            let run, command, state: String
            let status: Int32?
            let timedOut: Bool?
            let folder: String?
            let output: String
        }

        var report: Report {
            lock.withLock {
                Report(run: id, command: command, state: _refused != nil ? "refused: \(_refused!)" : _status == nil ? "running" : "ended",
                       status: _status, timedOut: _status == nil ? nil : _timedOut, folder: _folder,
                       output: String(decoding: output, as: UTF8.self))
            }
        }

        var failed: Bool { lock.withLock { (_status ?? 0) != 0 } }
    }

    private var runs: [String: Run] = [:]

    private func wait(_ run: Run, seconds: Int) async -> MCPResult {
        let deadline = Date().addingTimeInterval(TimeInterval(min(max(seconds, 0), 3600)))
        while !run.done, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        var r = MCPResult.json(run.report)
        r.isError = run.done && run.failed
        return r
    }

    /// A VM caller's host commands, one tool each, and the tools for runs.
    func hostTools(for caller: MCPCaller) -> [MCPTool] {
        guard case .vm(let vmName) = caller, let vm = service.manager.existing(vmName) else { return [] }
        let waitSchema = Self.integer("Seconds to wait for the end (default 300, up to 3600); after that the run goes on.")
        var tools: [MCPTool] = vm.config.hostCommands.filter { vm.hostCommandServer(named: $0.name) != nil }.map { command in
            var properties: [String: JSONValue] = ["wait": waitSchema]
            for a in command.arguments {
                properties[a.name] = .object(["type": .string("string"), "pattern": .string(a.pattern),
                                              "description": .string(a.summary.isEmpty ? a.name : a.summary)])
            }
            return MCPTool(name: "host_\(command.name)",
                           description: (command.summary.isEmpty ? "Runs \(command.name) on the Mac." : command.summary)
                               + " Runs on the Mac, one run at a time; returns the output so far, the status and the run's folder "
                               + "(in ~/.monad/exchange/runs); run_wait takes up a run still going.",
                           schema: Self.schema(properties, required: command.arguments.filter(\.required).map(\.name)),
                           risk: .normal) { [unowned self] call in
                var values: [String] = []
                var gap: String?
                for a in command.arguments {
                    if let v = try call.optionalString(a.name) {
                        if let g = gap { throw MonadError("Give \(g) too: values go in order.") }
                        values.append(v)
                    } else if gap == nil {
                        gap = a.name
                    }
                }
                guard let server = self.service.manager.existing(vmName)?.hostCommandServer(named: command.name)?.server else {
                    throw MonadError("\(command.name) is not serving now.")
                }
                let run = Run(id: String(UUID().uuidString.prefix(8)).lowercased(), vm: vmName, command: command.name)
                try await server.submitChecking(values) { run.apply($0) }
                self.runs[run.id] = run
                if self.runs.count > 50, let oldest = self.runs.values.min(by: { $0.started < $1.started }) {
                    self.runs[oldest.id] = nil
                }
                return await self.wait(run, seconds: try call.optionalInt("wait") ?? 300)
            }
        }
        tools += [
            MCPTool(name: "run_wait", description: "Wait for a host command's run to end and return its output and status.",
                    schema: Self.schema(["run": Self.string("The run's id."), "wait": waitSchema], required: ["run"]),
                    risk: .read) { [unowned self] call in
                guard let run = self.runs[try call.string("run")], run.vm == vmName else { throw MonadError("No such run.") }
                return await self.wait(run, seconds: try call.optionalInt("wait") ?? 300)
            },
            MCPTool(name: "run_status", description: "A host command's run as it is now.",
                    schema: Self.schema(["run": Self.string("The run's id.")], required: ["run"]), risk: .read) { [unowned self] call in
                guard let run = self.runs[try call.string("run")], run.vm == vmName else { throw MonadError("No such run.") }
                return .json(run.report)
            },
            MCPTool(name: "list_runs", description: "This VM's latest host command runs.", schema: Self.schema([:]),
                    risk: .read) { [unowned self] _ in
                let mine = self.runs.values.filter { $0.vm == vmName }.sorted { $0.started > $1.started }
                return .json(["runs": mine.map { r in ["run": r.id, "command": r.command, "state": r.report.state] }])
            },
        ]
        return tools
    }

    // MARK: Children

    /// A VM an orchestrator makes: its child, on one of its networks, behind
    /// its firewall, with nothing that reaches the Mac, within its limits.
    private func makeChild(_ c: inout InstanceConfig, of parentName: String) throws {
        let parent = try vm(parentName).config
        guard let access = parent.agents, access.role == .orchestrator else { throw MonadError("This VM may not make VMs.") }
        let children = service.manager.instances.map(\.config).filter { $0.parent == parentName }
        guard children.count < access.maxChildren else {
            throw MonadError("This VM has made \(children.count) VMs already, the most it may (\(access.maxChildren)). Delete one first.")
        }
        let cpus = access.childCPUs ?? parent.cpus
        let memory = access.childMemoryGiB ?? parent.memoryGiB
        guard children.reduce(0, { $0 + $1.cpus }) + c.cpus <= cpus else {
            throw MonadError("Its VMs may use \(cpus) CPUs together; \(children.reduce(0) { $0 + $1.cpus }) are taken.")
        }
        guard children.reduce(0, { $0 + $1.memoryGiB }) + c.memoryGiB <= memory else {
            throw MonadError("Its VMs may use \(memory) GB of memory together; \(children.reduce(0) { $0 + $1.memoryGiB }) are taken.")
        }
        let networks = parent.networks.map(\.network)
        if let wanted = c.networks.first?.network, c.networks != InstanceConfig.defaults(name: c.name).networks,
           !networks.contains(wanted) {
            throw MonadError("Its VMs join its own networks: \(networks.joined(separator: ", ")).")
        }
        c.networks = parent.networks.prefix(1).map { NetworkAttachment(network: $0.network, macAddress: nil) }
        c.parent = parentName
        c.firewall = parent.firewall
        c.sharing = SharingSettings()
        c.bridges = []
        c.hostCommands = []
        c.agents = nil
        c.forwards = []
        c.startAtLaunch = false
    }

    // MARK: Argument helpers

    private static var firewallSchema: JSONValue {
        schema(["name": vmName, "target": string("A name (and its subdomains), *.name (subdomains only) or address/prefix."),
                "proto": string("any, tcp, udp or icmp (default any)."),
                "ports": string("A port or range like 443 or 8000-8100 (default all).")], required: ["name", "target"])
    }

    private static func firewallRule(_ call: MCPCall, action: FirewallRule.Action) throws -> FirewallRule {
        let proto = try FirewallRule.Proto(rawValue: call.optionalString("proto") ?? "any")
            ?? { throw MonadError("proto is any, tcp, udp or icmp.") }()
        var ports: ClosedRange<Int>?
        if let text = try call.optionalString("ports") {
            let parts = text.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (1...2).contains(parts.count), let lo = parts.first ?? nil, let hi = parts.last ?? nil, lo <= hi else {
                throw MonadError("ports is a port or a range like 8000-8100.")
            }
            ports = lo...hi
        }
        return FirewallRule(action: action, proto: proto, target: try call.string("target"), ports: ports)
    }

    private static func forward(_ call: MCPCall, allowed: [ForwardRule.Kind]) throws -> ForwardRule {
        guard let kind = ForwardRule.Kind(rawValue: try call.string("kind")), allowed.contains(kind) else {
            throw MonadError("kind is \(allowed.map(\.rawValue).joined(separator: " or ")).")
        }
        return ForwardRule(kind: kind, hostPort: try call.optionalInt("host_port"), guestPort: try call.optionalInt("guest_port"),
                           hostSocket: try call.optionalString("host_socket"), guestSocket: try call.optionalString("guest_socket"))
    }

    private static func hostCommand(_ call: MCPCall) throws -> HostCommand {
        var args: [HostCommand.Argument] = []
        if case .array(let items)? = call.arguments["arguments"] {
            for item in items {
                guard case .object(let o) = item else { throw MonadError("arguments is a list of objects.") }
                let a = MCPCall(caller: call.caller, arguments: o)
                args.append(.init(name: try a.string("name"), pattern: try a.string("pattern"),
                                  required: try a.optionalBool("required") ?? true, summary: try a.optionalString("summary") ?? ""))
            }
        }
        var env: [String: String] = [:]
        if case .object(let o)? = call.arguments["environment"] {
            for (k, v) in o {
                guard case .string(let s) = v else { throw MonadError("environment's values are strings.") }
                env[k] = s
            }
        }
        return HostCommand(name: try call.string("command"), summary: try call.optionalString("summary") ?? "",
                           program: try call.string("program"), fixedArguments: try call.strings("fixed_arguments"),
                           arguments: args, workingDirectory: try call.string("working_directory"),
                           timeoutSeconds: try call.optionalInt("timeout_seconds") ?? 3600, environment: env,
                           guestPort: try call.optionalInt("guest_port"), guestSocket: try call.optionalString("guest_socket"))
    }

    /// A path in the guest given to a shell command: absolute or relative,
    /// no control characters (it is quoted, never expanded).
    private static func guestPath(_ p: String) throws -> String {
        guard !p.isEmpty, p.utf8.count <= 4096, !HostCommand.hasControl(p) else { throw MonadError("That is not a path.") }
        return p
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
