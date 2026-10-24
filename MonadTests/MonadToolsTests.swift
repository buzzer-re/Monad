//
//  MonadToolsTests.swift — Monad's MCP tools against a real HostService on
//  fake VMs: every tool goes the way the app's requests go (validation,
//  share rules, host limits), and says what it did or why not.
//

import XCTest
@testable import Monad

@MainActor
final class MonadToolsTests: XCTestCase {
    private var fixture: ManagerFixture!
    private var service: HostService!
    private var tools: MonadTools!
    private var tmp: TempDir!
    private var store: DistroStore!

    override func setUp() async throws {
        fixture = try ManagerFixture()
        tmp = TempDir()
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16),
                              sharePlaces: SharePolicy.Places(home: "/Users/dev", monad: "/Users/dev/.monad"),
                              agents: tmp.url.appendingPathComponent("agents"))
        store = DistroStore(directory: tmp.url.appendingPathComponent("distros"), bundled: try DistroCatalog.bundled())
        tools = MonadTools(service: service, distros: { [store] in store! },
                           networks: NetworkStore(directory: tmp.url.appendingPathComponent("networks")),
                           discover: { _ in ImageDiscovery(checksums: nil) })
    }

    private func tool(_ name: String) throws -> MCPTool {
        try XCTUnwrap(tools.all().first { $0.name == name }, name)
    }

    @discardableResult
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> MCPResult {
        try await tool(name).run(MCPCall(caller: .mac, arguments: arguments))
    }

    private func object(_ r: MCPResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any], r.text)
    }

    private func made(_ name: String) async throws -> VMInstance {
        try await call("create_vm", ["name": .string(name), "cpus": .number(2), "memory_gib": .number(2),
                                     "disk_gib": .number(10), "start": .bool(false)])
        let vm = try XCTUnwrap(fixture.manager.existing(name))
        await assertEventually { vm.state == .stopped }
        return vm
    }

    /// Every tool has a schema of type object, a description and a risk;
    /// what reads is read, what can reach the Mac or cannot be undone asks.
    func testTheToolTable() throws {
        let all = tools.all()
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "one tool per name")
        for t in all {
            XCTAssertFalse(t.description.isEmpty, t.name)
            XCTAssertEqual(t.schema.object?["type"], .string("object"), t.name)
            XCTAssertNotNil(t.name.range(of: "^[a-z][a-z_]*$", options: .regularExpression), t.name)
        }
        let risky = Set(all.filter { $0.risk == .risky }.map(\.name))
        XCTAssertEqual(risky, ["delete_vm", "add_distro", "remove_distro", "add_mac_forward", "allow_destination",
                               "add_share", "add_bridge", "add_host_command", "set_agent_role", "set_firewall", "set_group",
                               "set_macos_security"])
        XCTAssertEqual(Set(all.filter { $0.risk == .read }.map(\.name)),
                       ["list_vms", "get_vm", "list_distros", "list_networks", "list_connections", "list_canvas",
                        "read_vm_log", "read_recovery_screens"])
    }

    /// A VM's log (what Monad did with it), its last lines; read only.
    func testAVMsLogIsRead() async throws {
        let vm = try await made("web")
        vm.log.log("first")
        for i in 1...5 { vm.log.log("line \(i)") }
        vm.log.flush()
        let r = try await call("read_vm_log", ["name": .string("web"), "lines": .number(3)])
        let lines = r.text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, r.text)
        XCTAssertTrue(lines.last?.hasSuffix("line 5") ?? false, r.text)
        XCTAssertFalse(r.text.contains("first"))
        do {
            _ = try await call("read_vm_log", ["name": .string("nope")])
            XCTFail("no such VM")
        } catch {}
    }

    /// Recovery's screens from its last run: listed, and one of them (the
    /// last by default) given as a picture.
    func testRecoveryScreensAreShown() async throws {
        let vm = try await made("web")
        let none = try await call("read_recovery_screens", ["name": .string("web")])
        XCTAssertTrue(none.images.isEmpty)
        XCTAssertTrue(none.text.contains("no recovery screens"), none.text)
        let dir = vm.paths.recoveryScreens
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("step-1-wait-1.png"))
        try Data([2]).write(to: dir.appendingPathComponent("step-3-wait-2.png"))
        let last = try await call("read_recovery_screens", ["name": .string("web")])
        XCTAssertEqual(last.images, [Data([2])])
        XCTAssertTrue(last.text.contains("step-1-wait-1, step-3-wait-2"), last.text)
        let first = try await call("read_recovery_screens", ["name": .string("web"), "screen": .string("step-1-wait-1")])
        XCTAssertEqual(first.images, [Data([1])])
        do {
            _ = try await call("read_recovery_screens", ["name": .string("web"), "screen": .string("../vm")])
            XCTFail("only a listed screen")
        } catch {}
    }

    /// A result's pictures go to the agent as image content after its text.
    func testPicturesAreImageContent() async throws {
        let dir = try await made("web").paths.recoveryScreens
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([7]).write(to: dir.appendingPathComponent("step-1-wait-1.png"))
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_recovery_screens","arguments":{"name":"web"}}}"#
        let reply = await service.mcp.handle(Data(request.utf8), caller: .mac)
        let r = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(reply)) as? [String: Any])
        let content = try XCTUnwrap((r["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image"])
        XCTAssertEqual(content[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual(content[1]["data"] as? String, Data([7]).base64EncodedString())
    }

    /// The server names itself with the app's version, not the build's id.
    func testTheServerSaysItsVersion() async throws {
        let reply = await service.mcp.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8),
                                             caller: .mac)
        let r = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(reply)) as? [String: Any])
        let info = try XCTUnwrap((r["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["version"] as? String, HostService.appVersion)
        XCTAssertNotNil(HostService.appVersion.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression), HostService.appVersion)
    }

    /// MonadHost is a tool inside Monad.app, whose Bundle.main carries the
    /// tool's own plist (no version): the version is read from the app's
    /// Info.plist on disk.
    func testTheVersionIsReadFromTheAppAroundTheExecutable() throws {
        let app = tmp.url.appendingPathComponent("Monad.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.3"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(HostService.appVersion(executable: app.appendingPathComponent("MacOS/MonadHost")), "2.3")
        XCTAssertNil(HostService.appVersion(executable: tmp.url.appendingPathComponent("loose/MonadHost")))
    }

    /// Groups: set and cleared by name, shown in list_vms, checked like a
    /// tag name.
    func testGroups() async throws {
        let vm = try await made("web")
        try await call("set_group", ["name": .string("web"), "group": .string("analysis")])
        XCTAssertEqual(vm.config.group, "analysis")
        let list = try object(try await call("list_vms"))
        XCTAssertEqual((list["vms"] as? [[String: Any]])?.first?["group"] as? String, "analysis")
        try await call("set_group", ["name": .string("web"), "group": .string("")])
        XCTAssertNil(vm.config.group)
        do {
            try await call("set_group", ["name": .string("web"), "group": .string("no spaces")])
            XCTFail("not a group name")
        } catch {}
    }

    /// A VM made with start on starts once it is made (it is still being
    /// prepared when the start is asked for).
    func testAVMMadeToStartStarts() async throws {
        try await call("create_vm", ["name": .string("web"), "cpus": .number(2), "memory_gib": .number(2), "disk_gib": .number(10)])
        let vm = try XCTUnwrap(fixture.manager.existing("web"))
        await assertEventually("\(vm.state)") { vm.state == .ready }
    }

    /// Networks: the first free subnet unless one is given, the kind's
    /// default for VMs reaching each other unless said; names and subnets
    /// are not taken twice.
    func testNetworksAreMade() async throws {
        let networks = NetworkStore(directory: tmp.url.appendingPathComponent("networks"))
        try await call("create_network", ["name": .string("dirty"), "kind": .string("internal")])
        let dirty = try XCTUnwrap(try networks.network(named: "dirty"))
        XCTAssertEqual(dirty.subnet, "10.78.0.0/24", "the first free one (default has 10.77)")
        XCTAssertTrue(dirty.vmsReachEachOther)
        try await call("create_network", ["name": .string("lab"), "kind": .string("nat"), "vms_reach_each_other": .bool(true),
                                          "subnet": .string("192.168.50.0/24")])
        let lab = try XCTUnwrap(try networks.network(named: "lab"))
        XCTAssertEqual(lab.kind, .nat)
        XCTAssertEqual(lab.subnet, "192.168.50.0/24")
        XCTAssertTrue(lab.vmsReachEachOther)
        for (args, why) in [(["name": JSONValue.string("lab")], "taken"),
                            (["name": .string("other"), "subnet": .string("192.168.50.0/24")], "subnet taken"),
                            (["name": .string("other"), "subnet": .string("10.78.0.0/16")], "subnet overlaps"),
                            (["name": .string("other"), "kind": .string("bridge")], "no such kind"),
                            (["name": .string("Bad Name")], "a bad name")] {
            do {
                try await call("create_network", args)
                XCTFail(why)
            } catch {}
        }
    }

    /// A network goes when no VM is on it; the default one never.
    func testNetworksAreDeleted() async throws {
        let networks = NetworkStore(directory: tmp.url.appendingPathComponent("networks"))
        try await call("create_network", ["name": .string("lab")])
        try await call("create_network", ["name": .string("spare")])
        try await call("create_vm", ["name": .string("web"), "cpus": .number(2), "memory_gib": .number(2),
                                     "disk_gib": .number(10), "network": .string("lab"), "start": .bool(false)])
        do {
            try await call("delete_network", ["name": .string("lab")])
            XCTFail("web is on it")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("web"), error.localizedDescription)
        }
        try await call("delete_network", ["name": .string("spare")])
        XCTAssertNil(try networks.network(named: "spare"))
        for name in ["default", "ghost"] {
            do {
                try await call("delete_network", ["name": .string(name)])
                XCTFail(name)
            } catch {}
        }
    }

    /// Tightening a firewall needs nobody's word; set_firewall can loosen
    /// it, so it asks.
    func testFirewallsTightenAndAreSet() async throws {
        let vm = try await made("box")
        try await call("restrict_vm", ["name": .string("box")])
        XCTAssertTrue(vm.config.firewall.allowlist)
        XCTAssertFalse(vm.config.firewall.allowLAN)
        try await call("set_firewall", ["name": .string("box"), "only_allowed": .bool(false), "allow_lan": .bool(true),
                                        "ask": .bool(true)])
        XCTAssertFalse(vm.config.firewall.allowlist)
        XCTAssertTrue(vm.config.firewall.allowLAN)
        XCTAssertTrue(vm.config.firewall.monitor)
        try await call("restrict_vm", ["name": .string("box"), "block_lan": .bool(false)])
        XCTAssertTrue(vm.config.firewall.allowlist)
        XCTAssertTrue(vm.config.firewall.allowLAN, "left as it was")
        XCTAssertFalse(vm.config.firewall.monitor, "only what its rules allow, no questions")
    }

    /// Notes on the canvas: things named plainly, the author kept, edits and
    /// removal by id, and what is not on the canvas refused.
    func testCanvasNotes() async throws {
        _ = try await made("web")
        let label = try object(try await call("add_note", ["kind": .string("label"), "text": .string("C2"), "on": .string("web"),
                                                           "color": .string("red")]))
        let labelID = try XCTUnwrap(label["id"] as? String)
        try await call("add_note", ["kind": .string("zone"), "text": .string("Malware lab"),
                                    "around": .array([.string("web"), .string("default")])])
        try await call("add_note", ["kind": .string("arrow"), "text": .string("beacons"), "on": .string("web"), "to": .string("internet")])
        let free = try object(try await call("add_note", ["text": .string("**Rules**: no internet")]))
        let freeID = try XCTUnwrap(free["id"] as? String)
        XCTAssertEqual(service.notes.map(\.kind), [.label, .zone, .arrow, .note])
        XCTAssertEqual(service.notes.first?.on, "vm:web")
        XCTAssertEqual(service.notes.first?.tint, .red)
        XCTAssertEqual(service.notes[1].around, ["vm:web", "net:default"])
        XCTAssertEqual(Set(service.notes.map(\.author)), ["mac"])

        let listed = try object(try await call("list_canvas"))
        XCTAssertEqual((listed["notes"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((listed["vms"] as? [[String: Any]])?.first?["name"] as? String, "web")

        try await call("edit_note", ["id": .string(freeID), "text": .string("changed"), "x": .number(10), "y": .number(20),
                                     "width": .number(300), "height": .number(120)])
        let edited = try XCTUnwrap(service.notes.first { $0.id == freeID })
        XCTAssertEqual(edited.text, "changed")
        XCTAssertEqual(edited.frame, CGRect(x: 10, y: 20, width: 300, height: 120))
        try await call("remove_note", ["id": .string(labelID)])
        XCTAssertEqual(service.notes.count, 3)

        // The user's note: moved by an agent it stays the user's; its words
        // changed, it shows who wrote them now.
        var mine = CanvasNote(id: CanvasNote.newID(), kind: .note)
        mine.text = "my plan"
        mine = try service.setNote(mine, author: "you")
        try await call("edit_note", ["id": .string(mine.id), "x": .number(40)])
        XCTAssertEqual(service.notes.first { $0.id == mine.id }?.author, "you", "moved only")
        try await call("edit_note", ["id": .string(mine.id), "text": .string("Click to finish the setup")])
        XCTAssertEqual(service.notes.first { $0.id == mine.id }?.author, "mac", "the words are the agent's now")
        try await call("remove_note", ["id": .string(mine.id)])

        for (name, args) in [("add_note", ["kind": JSONValue.string("label"), "text": .string("x"), "on": .string("ghost")]),
                             ("add_note", ["kind": .string("ink")]),
                             ("add_note", ["color": .string("chartreuse")]),
                             ("edit_note", ["id": .string("nope"), "text": .string("x")]),
                             ("remove_note", ["id": .string(labelID)])] {
            do {
                try await call(name, args)
                XCTFail("\(name) \(args)")
            } catch {}
        }
    }

    func testVMsAreMadeListedAndRemoved() async throws {
        let vm = try await made("web")
        let list = try object(try await call("list_vms"))
        let vms = try XCTUnwrap(list["vms"] as? [[String: Any]])
        XCTAssertEqual(vms.map { $0["name"] as? String }, ["web"])
        XCTAssertEqual(vms.first?["cpus"] as? Int, 2)
        XCTAssertEqual(vms.first?["state"] as? String, "Stopped")

        try await call("start_vm", ["name": .string("web")])
        await assertEventually { vm.state == .ready }
        try await call("delete_vm", ["name": .string("web")])
        XCTAssertNil(fixture.manager.existing("web"))
    }

    /// The app's checks apply: limits, names, unknown distros.
    func testTheAppsChecksApply() async throws {
        do {
            try await call("create_vm", ["name": .string("big"), "cpus": .number(64)])
            XCTFail("over the host's limit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("CPU"), error.localizedDescription)
        }
        do {
            try await call("create_vm", ["name": .string("Bad Name")])
            XCTFail("a bad name")
        } catch {}
        do {
            try await call("create_vm", ["name": .string("odd"), "distro": .string("plan9")])
            XCTFail("an unknown distro")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This Monad does not know the distribution plan9.")
        }
        do {
            try await call("start_vm", ["name": .string("ghost")])
            XCTFail("no such VM")
        } catch {}
    }

    /// Settings through `update`: forwards, firewall, bridges, host
    /// commands, shares; the share rules hold (Monad's folder never).
    func testSettingsChangeThroughTheVMsUpdate() async throws {
        let vm = try await made("web")
        try await call("add_forward", ["name": .string("web"), "kind": .string("local"),
                                       "host_port": .number(8080), "guest_port": .number(80)])
        XCTAssertEqual(vm.config.forwards.map(\.kind), [.local])
        do {
            try await call("add_forward", ["name": .string("web"), "kind": .string("remote"),
                                           "host_port": .number(5432), "guest_port": .number(5432)])
            XCTFail("into the Mac is add_mac_forward")
        } catch {
            XCTAssertEqual(error.localizedDescription, "kind is local or socks or unixLocal.")
        }
        try await call("add_mac_forward", ["name": .string("web"), "kind": .string("remote"),
                                           "host_port": .number(5432), "guest_port": .number(5432)])
        XCTAssertEqual(vm.config.forwards.map(\.kind), [.local, .remote])
        try await call("remove_forward", ["name": .string("web"), "index": .number(0)])
        XCTAssertEqual(vm.config.forwards.map(\.kind), [.remote])

        try await call("block_destination", ["name": .string("web"), "target": .string("ads.example"), "ports": .string("443")])
        try await call("allow_destination", ["name": .string("web"), "target": .string("github.com"), "proto": .string("tcp")])
        XCTAssertEqual(vm.config.firewall.rules.map(\.target), ["github.com", "ads.example"])
        XCTAssertEqual(vm.config.firewall.rules.last?.ports, 443...443)
        try await call("remove_firewall_rule", ["name": .string("web"), "index": .number(0)])
        XCTAssertEqual(vm.config.firewall.rules.map(\.target), ["ads.example"])

        let src = tmp.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try await call("add_share", ["name": .string("web"), "host_path": .string(src.path), "guest_path": .string("/home/dev/src")])
        XCTAssertEqual(vm.config.sharing.shares.first?.readOnly, true, "read-only unless said")
        XCTAssertTrue(vm.config.sharing.runtimeEnabled)
        do {
            try await call("add_share", ["name": .string("web"), "host_path": .string("/Users/dev/.monad"),
                                         "guest_path": .string("/mnt/m")])
            XCTFail("Monad's own folder")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Monad's own folder"), error.localizedDescription)
        }

        try await call("add_bridge", ["name": .string("web"), "bridge": .string("cat"),
                                      "command": .array([.string("/bin/cat")]), "guest_port": .number(9000)])
        XCTAssertEqual(vm.config.bridges.map(\.name), ["cat"])
        try await call("add_host_command", [
            "name": .string("web"), "command": .string("lister"), "program": .string("/bin/ls"),
            "arguments": .array([.object(["name": .string("flag"), "pattern": .string("^-[la]$")])]),
            "working_directory": .string(src.path), "guest_port": .number(9100)])
        XCTAssertEqual(vm.config.hostCommands.first?.arguments.first?.pattern, "^-[la]$")
        do {
            try await call("add_host_command", [
                "name": .string("web"), "command": .string("loose"), "program": .string("/bin/ls"),
                "working_directory": .string("/"), "guest_port": .number(9101)])
            XCTFail("outside the shares")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("inside a folder this VM shares"), error.localizedDescription)
        }
        try await call("remove_host_command", ["name": .string("web"), "command": .string("lister")])
        try await call("remove_bridge", ["name": .string("web"), "bridge": .string("cat")])
        try await call("remove_share", ["name": .string("web"), "host_path": .string(src.path)])
        XCTAssertEqual(vm.config.hostCommands, [])
        XCTAssertEqual(vm.config.bridges, [])
        XCTAssertEqual(vm.config.sharing.shares, [])
    }

    /// exec, read_file and write_file go over the VM's ssh; a stopped VM
    /// says so.
    func testCommandsAndFilesInARunningVM() async throws {
        let vm = try await made("web")
        do {
            try await call("exec", ["name": .string("web"), "command": .string("uname -a")])
            XCTFail("not running")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Start it first"), error.localizedDescription)
        }
        fixture.runner.setHandler { call in
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            switch call.arguments.last {
            case "uname -a": return .ok("Linux web 6.0 aarch64\n")
            case "false": return .init(status: 1, stdout: Data(), stderr: Data("nope\n".utf8))
            case "head -c 1048577 -- '/etc/hostname'": return .ok("web\n")
            case "cat > '/tmp/it'\\''s'": return .ok()
            default: return .ok()
            }
        }
        vm.start()
        await assertEventually { vm.state == .ready }
        var r = try await call("exec", ["name": .string("web"), "command": .string("uname -a")])
        XCTAssertFalse(r.isError)
        XCTAssertEqual(try object(r)["stdout"] as? String, "Linux web 6.0 aarch64\n")
        XCTAssertEqual(try object(r)["status"] as? Int, 0)
        r = try await call("exec", ["name": .string("web"), "command": .string("false")])
        XCTAssertTrue(r.isError, "a failing command is an error result, with its output")
        XCTAssertEqual(try object(r)["stderr"] as? String, "nope\n")

        r = try await call("read_file", ["name": .string("web"), "path": .string("/etc/hostname")])
        XCTAssertEqual(r.text, "web\n")
        r = try await call("write_file", ["name": .string("web"), "path": .string("/tmp/it's"), "content": .string("hello")])
        XCTAssertEqual(r.text, "Wrote 5 bytes to /tmp/it's.")
        let write = try XCTUnwrap(fixture.runner.calls.last { $0.arguments.last == "cat > '/tmp/it'\\''s'" })
        XCTAssertEqual(write.stdin, Data("hello".utf8), "the content goes as input, the path quoted")
        do {
            try await call("read_file", ["name": .string("web"), "path": .string("a\nb")])
            XCTFail("a control character")
        } catch {}
    }

    /// For MCPAccessTests: a read tool and a host command's tool.
    static let sampleTools: [MCPTool] = ["list_vms", "host_make"].map { name in
        MCPTool(name: name, description: "x", schema: .object(["type": .string("object")]), risk: .read) { _ in MCPResult(text: "") }
    }

    /// An orchestrator's VMs: its children, on its network, behind its
    /// firewall, with nothing reaching the Mac, within its limits; it lists
    /// only itself and them.
    func testAnOrchestratorMakesChildrenWithinItsLimits() async throws {
        let boss = try await made("boss")
        var c = boss.config
        c.agents = AgentAccess(role: .orchestrator, maxChildren: 2, childCPUs: 3, childMemoryGiB: 4)
        c.firewall.rules = [FirewallRule(action: .allow, proto: .tcp, target: "github.com")]
        try boss.update(c)
        _ = try await made("other")
        func create(_ name: String, cpus: Int = 1) async throws -> MCPResult {
            try await tool("create_vm").run(MCPCall(caller: .vm("boss"), arguments: [
                "name": .string(name), "cpus": .number(Double(cpus)), "memory_gib": .number(2), "disk_gib": .number(10),
                "start": .bool(false)]))
        }
        _ = try await create("kid1", cpus: 2)
        let kid = try XCTUnwrap(fixture.manager.existing("kid1"))
        XCTAssertEqual(kid.config.parent, "boss")
        XCTAssertEqual(kid.config.firewall, c.firewall, "no looser than its parent's")
        XCTAssertEqual(kid.config.networks.map(\.network), c.networks.map(\.network))
        XCTAssertNil(kid.config.agents)
        do {
            _ = try await create("kid2", cpus: 2)
            XCTFail("3 CPUs together")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Its VMs may use 3 CPUs together; 2 are taken.")
        }
        _ = try await create("kid2", cpus: 1)
        do {
            _ = try await create("kid3")
            XCTFail("2 children at most")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This VM has made 2 VMs already, the most it may (2). Delete one first.")
        }
        let listed = try object(try await tool("list_vms").run(MCPCall(caller: .vm("boss"), arguments: [:])))
        XCTAssertEqual(Set((listed["vms"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []),
                       ["boss", "kid1", "kid2"], "not the other VMs")
    }

    /// A host-commands VM gets each of its host commands as a tool (the
    /// values by name, in order), and the run's output, status and folder.
    func testHostCommandsAreToolsForTheirVM() async throws {
        let echo = EchoCommands()
        fixture = try ManagerFixture { $0.hostCommandServer = { c, _, _ in echo.make(c) } }
        service = HostService(manager: fixture.manager, limits: .init(maxCPUs: 8, maxMemoryGiB: 16),
                              agents: tmp.url.appendingPathComponent("agents"))
        tools = MonadTools(service: service, distros: { [store] in store! })
        let src = tmp.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        var c = InstanceConfig.defaults(name: "runner")
        c.cpus = 2; c.memoryGiB = 2; c.diskGiB = 10
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [SharedFolder(hostPath: src.path, guestPath: "/home/dev/src", readOnly: true, confirmed: true)])
        c.hostCommands = [HostCommand(name: "make-it", summary: "Make.", program: "/usr/bin/make",
                                      arguments: [.init(name: "target", pattern: "^(a|b)$"), .init(name: "flag", pattern: "^-k$", required: false)],
                                      workingDirectory: src.path, guestPort: 9100)]
        c.agents = AgentAccess(role: .hostCommands)
        let vm = try fixture.manager.create(c)
        await assertEventually { vm.state == .stopped }
        vm.start()
        await assertEventually { vm.state == .ready }

        let list = tools.hostTools(for: .vm("runner"))
        XCTAssertEqual(list.map(\.name), ["host_make-it", "run_wait", "run_status", "list_runs"])
        XCTAssertEqual(tools.hostTools(for: .mac).map(\.name), [], "the Mac has no host command tools")
        let make = list[0]
        XCTAssertEqual(make.schema.object?["required"], .array([.string("target")]))
        let r = try await make.run(MCPCall(caller: .vm("runner"), arguments: ["target": .string("a")]))
        let json = try object(r)
        XCTAssertEqual(json["output"] as? String, "ran a\n")
        XCTAssertEqual(json["status"] as? Int, 0)
        XCTAssertEqual(json["state"] as? String, "ended")
        XCTAssertEqual(json["folder"] as? String, "/home/dev/.monad/exchange/runs/x")
        XCTAssertEqual(echo.values, [["a"]])
        do {
            _ = try await make.run(MCPCall(caller: .vm("runner"), arguments: ["flag": .string("-k")]))
            XCTFail("values go in order")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Give target too: values go in order.")
        }
        let runs = try object(try await list[3].run(MCPCall(caller: .vm("runner"), arguments: [:])))
        XCTAssertEqual((runs["runs"] as? [[String: Any]])?.count, 1)
    }

    /// A distro added by its image's link, as the form does it.
    func testADistroIsAddedByItsLink() async throws {
        let r = try await call("add_distro", ["link": .string("https://d.example/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2"),
                                              "package_manager": .string("dnf")])
        XCTAssertEqual(r.text, "Added AlmaLinux (almalinux), release 10. Its image is used as it is (no checksum file next to it).")
        XCTAssertNotNil(store.catalog.distro("almalinux"))
        let list = try object(try await call("list_distros"))
        let ids = (list["distros"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertTrue(ids.contains("almalinux"))
        try await call("remove_distro", ["id": .string("almalinux")])
        XCTAssertNil(store.catalog.distro("almalinux"))
        do {
            try await call("add_distro", ["link": .string("/tmp/local.qcow2")])
            XCTFail("a file on the Mac is the form's, not an agent's")
        } catch {}
    }
}

/// Host command servers that "run" at once: output, then exit 0.
final class EchoCommands: @unchecked Sendable {
    private(set) var values: [[String]] = []

    private final class Server: HostCommandServing {
        let command: HostCommand
        unowned let owner: EchoCommands
        init(_ command: HostCommand, owner: EchoCommands) {
            self.command = command
            self.owner = owner
        }
        func start() throws {}
        func stop() {}
        func submit(_ values: [String], sink: @escaping @Sendable (HostCommandServer.Event) -> Void) throws {
            _ = try command.arguments(for: values)
            owner.values.append(values)
            sink(.started(token: "t", folder: "/home/dev/.monad/exchange/runs/x"))
            sink(.output(Data("ran \(values.joined(separator: " "))\n".utf8)))
            sink(.exit(status: 0, timedOut: false, folder: "/home/dev/.monad/exchange/runs/x"))
        }
    }

    func make(_ command: HostCommand) -> HostCommandServing { Server(command, owner: self) }
}
