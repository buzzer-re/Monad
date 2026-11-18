//
//  VMSettingsDraftTests.swift — editing a VM's settings in its detail
//  window: a draft over the saved config, validated before it is sent, with
//  a preview of what only a restart applies.
//

import XCTest
@testable import Monad

final class VMSettingsDraftTests: XCTestCase {
    private let saved: InstanceConfig = {
        var c = InstanceConfig.defaults(name: "dev")
        c.distro = "ubuntu"
        c.user = "dev"
        c.cpus = 2
        c.memoryGiB = 4
        c.networks = [NetworkAttachment(network: NetworkAttachment.defaultNAT, macAddress: "52:54:00:00:00:01")]
        return c
    }()

    private func build(_ d: VMSettingsDraft) throws -> InstanceConfig {
        try d.build(maxCPUs: 8, maxMemoryGiB: 16)
    }

    func testStartsCleanFromTheSavedConfig() throws {
        let d = VMSettingsDraft(saved)
        XCTAssertFalse(d.isDirty)
        XCTAssertEqual(try build(d), saved)
        XCTAssertEqual(d.appliesAfterRestart, [])
    }

    func testEditsAndTheRestartPreview() throws {
        var d = VMSettingsDraft(saved)
        d.config.cpus = 4
        d.config.forwards = [ForwardRule(kind: .socks, hostPort: 1080)]
        XCTAssertTrue(d.isDirty)
        XCTAssertEqual(d.appliesAfterRestart, ["CPUs"], "forwards apply at once")
        XCTAssertEqual(try build(d).cpus, 4)
    }

    func testNetworkToggleKeepsTheMACAddress() throws {
        var d = VMSettingsDraft(saved)
        d.networkEnabled = false
        XCTAssertEqual(try build(d).networks, [])
        d.networkEnabled = true
        XCTAssertEqual(try build(d).networks, saved.networks)

        var offline = saved
        offline.networks = []
        var o = VMSettingsDraft(offline)
        o.networkEnabled = true
        XCTAssertEqual(try build(o).networks, [NetworkAttachment(network: NetworkDefinition.defaultName, macAddress: nil)])
    }

    func testTheNetworkIsChosenByName() throws {
        var d = VMSettingsDraft(saved)
        XCTAssertEqual(d.networkName, NetworkAttachment.defaultNAT) // this VM predates Monad networks
        d.networkName = "lab"
        XCTAssertEqual(try build(d).networks, [NetworkAttachment(network: "lab", macAddress: "52:54:00:00:00:01")],
                       "the VM keeps its MAC")
        d.networkName = nil
        XCTAssertTrue(try build(d).networks.isEmpty)
        d.networkName = "default"
        XCTAssertEqual(try build(d).networks.first?.macAddress, "52:54:00:00:00:01")
        XCTAssertTrue(d.appliesAfterRestart.contains("network"))
    }

    // MARK: Firewall

    func testTheFirewallIsEditedWithPortsAsText() throws {
        var d = VMSettingsDraft(saved)
        XCTAssertEqual(d.firewallRules.rules, [])
        d.config.firewall.allowLAN = true
        d.config.firewall.tags = ["web"]
        d.firewallRules.add()
        d.firewallRules.update(0) { $0.target = "*.github.com" }
        d.firewallRules.setPorts(0, "443")
        XCTAssertTrue(d.isDirty)
        XCTAssertEqual(d.appliesAfterRestart, [], "a firewall applies at once")
        let c = try build(d)
        XCTAssertEqual(c.firewall, VMFirewall(allowLAN: true, rules: [
            FirewallRule(action: .allow, proto: .tcp, target: "*.github.com", ports: 443...443),
        ], tags: ["web"]))
        d.saved(c)
        XCTAssertFalse(d.isDirty)
        XCTAssertEqual(d.firewallRules.portsTexts, ["443"])
        d.firewallRules.setPorts(0, "444")
        XCTAssertTrue(d.isDirty, "a typed port counts as an edit")
        d.firewallRules.setPorts(0, "nope")
        XCTAssertThrowsError(try build(d))
    }

    func testTooManyRulesWithTheTagsAreRefused() throws {
        var d = VMSettingsDraft(saved)
        let rule = FirewallRule(action: .deny, proto: .any, target: "1.2.3.4/32")
        for _ in 0..<40 {
            d.firewallRules.add()
            d.firewallRules.update(d.firewallRules.rules.count - 1) { $0 = rule }
        }
        d.config.firewall.tags = ["big"]
        let big = FirewallTag(name: "big", rules: Array(repeating: rule, count: 40))
        XCTAssertThrowsError(try d.build(maxCPUs: 8, maxMemoryGiB: 16, tags: [big]))
        XCTAssertNoThrow(try d.build(maxCPUs: 8, maxMemoryGiB: 16, tags: []))
    }

    func testProfilesAreToggledInOrder() {
        var d = VMSettingsDraft(saved)
        d.setProfile("server", on: true)
        d.setProfile("agentic", on: true)
        d.setProfile("server", on: true)
        XCTAssertEqual(d.config.profiles, ["server", "agentic"])
        d.setProfile("server", on: false)
        XCTAssertEqual(d.config.profiles, ["agentic"])
        XCTAssertEqual(d.appliesAfterRestart, [], "profiles run while the VM runs")
    }

    func testInvalidEditsAreRefusedBeforeSending() {
        var d = VMSettingsDraft(saved)
        d.config.cpus = 99
        XCTAssertThrowsError(try build(d))
        d = VMSettingsDraft(saved)
        d.config.memoryTargetGiB = 8
        XCTAssertThrowsError(try build(d))
    }

    /// Adding a forward into the Mac asks once, naming what the VM will reach.
    func testAForwardIntoTheMacIsConfirmed() {
        XCTAssertEqual(VMSettingsDraft.confirmation(for: ForwardRule(kind: .remote, hostPort: 8080, guestPort: 8080)),
                       "The VM will be able to connect to port 8080 on this Mac.")
        XCTAssertEqual(VMSettingsDraft.confirmation(for: ForwardRule(kind: .unixRemote, hostSocket: "/Users/x/agent.sock",
                                                                     guestSocket: "/run/agent.sock")),
                       "The VM will be able to connect to /Users/x/agent.sock on this Mac.")
        XCTAssertNil(VMSettingsDraft.confirmation(for: ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)))
        XCTAssertNil(VMSettingsDraft.confirmation(for: ForwardRule(kind: .socks, hostPort: 1080)))
    }

    func testAddedFolderIsReadOnlyInTheUsersHome() throws {
        var d = VMSettingsDraft(saved)
        d.addShare(hostPath: "/Users/x/src")
        let c = try build(d)
        XCTAssertTrue(c.sharing.runtimeEnabled, "adding a folder turns sharing on")
        XCTAssertEqual(c.sharing.shares, [SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true)])
        XCTAssertEqual(d.appliesAfterRestart, ["folder sharing"])
    }

    /// A writable share says what the VM can do with it; a read-only one says nothing.
    func testAWritableFolderSaysTheVMCanReplaceItsFiles() {
        var share = SharedFolder(hostPath: "/Users/x/src", guestPath: "/home/dev/src", readOnly: true)
        XCTAssertNil(VMSettingsDraft.note(for: share))
        share.readOnly = false
        XCTAssertEqual(VMSettingsDraft.note(for: share),
                       "The VM can change and replace files here, including with links that Mac programs will follow.")
        XCTAssertFalse(VMSettingsDraft.note(for: share)?.contains(";") ?? true)
    }

    /// Removing a Lima VM from Monad leaves the Lima VM and its disk alone,
    /// and the window says so.
    func testRemovingALimaVMFromMonadKeepsIt() {
        XCTAssertEqual(VMSettingsDraft.removal(for: saved),
                       .init(menu: "Delete…", title: "Delete “\(saved.name)”?", button: "Delete VM and Disk",
                             message: "The VM is stopped and its disk and keys are permanently removed."))
        var lima = saved
        lima.attached = AttachedDisk(lima: "default", dir: "/Users/x/.lima/default")
        XCTAssertEqual(VMSettingsDraft.removal(for: lima),
                       .init(menu: "Remove from Monad…", title: "Remove “\(saved.name)” from Monad?", button: "Remove from Monad",
                             message: "The VM is stopped and Monad forgets it. The Lima VM “default” and its disk stay as they are."))
        XCTAssertNil(VMSettingsDraft.limaNotes(for: saved))
        let notes = VMSettingsDraft.limaNotes(for: lima)
        XCTAssertEqual(notes?.shared, "Shared with the Lima VM “default”. Monad boots its disk where it is, and Lima can use it again whenever Monad does not run it.")
        XCTAssertEqual(notes?.warning, "Do not start “default” in Lima while Monad runs it. Both would write to the same disk.")
        XCTAssertFalse([notes?.shared, notes?.warning].compactMap { $0 }.joined().contains(";"))
    }

    /// A copy of a Lima VM is Monad's own: its window says where it came
    /// from, and deleting it deletes its disk (Lima's stays).
    func testACopyOfALimaVMIsMonadsOwn() {
        var copy = saved
        copy.copiedFrom = AttachedDisk(lima: "default", dir: "/Users/x/.lima/default")
        XCTAssertNil(VMSettingsDraft.limaNotes(for: copy))
        XCTAssertEqual(VMSettingsDraft.copyNote(for: copy),
                       "Copied from the Lima VM “default”. This VM has a disk of its own: changes do not reach Lima, and Lima's do not reach it.")
        XCTAssertNil(VMSettingsDraft.copyNote(for: saved))
        XCTAssertEqual(VMSettingsDraft.removal(for: copy), VMSettingsDraft.removal(for: saved), "its disk is Monad's")
    }

    /// A bridge from what is typed: the program by name or full path (found
    /// on the PATH, it must run), arguments separated by spaces; adding one
    /// asks first, saying what the VM can then do, and applies live.
    func testABridgeIsAddedFromWhatIsTyped() {
        let runs: (String) -> Bool = { $0 == "/usr/bin/xcrun" }
        XCTAssertEqual(VMSettingsDraft.resolveProgram("xcrun", path: "/opt/homebrew/bin:/usr/bin", isExecutable: runs), "/usr/bin/xcrun")
        XCTAssertEqual(VMSettingsDraft.resolveProgram("/usr/bin/xcrun", path: "", isExecutable: runs), "/usr/bin/xcrun")
        XCTAssertNil(VMSettingsDraft.resolveProgram("nope", path: "/usr/bin", isExecutable: runs))
        XCTAssertNil(VMSettingsDraft.resolveProgram("./xcrun", path: "/usr/bin", isExecutable: { _ in true }), "a relative path")
        XCTAssertNil(VMSettingsDraft.resolveProgram("  ", path: "/usr/bin", isExecutable: { _ in true }))
        XCTAssertEqual(VMSettingsDraft.arguments("  mcpbridge   --stdio "), ["mcpbridge", "--stdio"])
        XCTAssertEqual(VMSettingsDraft.arguments(""), [])

        let bridge = CommandBridge(name: "Xcode MCP", command: ["/usr/bin/xcrun", "mcpbridge"], guestPort: 9000)
        XCTAssertEqual(VMSettingsDraft.confirmation(for: bridge),
                       "The VM will be able to run “/usr/bin/xcrun mcpbridge” on this Mac, as you. Each connection to 127.0.0.1:9000 in the VM runs it once, with what the VM sends as its input.")
        XCTAssertFalse(VMSettingsDraft.confirmation(for: bridge).contains(";"))
        var d = VMSettingsDraft(saved)
        d.addBridge(bridge)
        XCTAssertEqual(d.config.bridges, [bridge])
        XCTAssertEqual(d.appliesAfterRestart, [], "bridges change live")
    }

    /// A bridge's state while the VM runs is that of its remote forward.
    func testABridgesStateIsItsForward() {
        let paths = InstancePaths(name: "dev", root: URL(fileURLWithPath: "/Users/x/.monad/instances"))
        let bridge = CommandBridge(name: "cat", command: ["/bin/cat"], guestPort: 9000)
        let spec = bridge.spec(in: paths)
        XCTAssertNil(VMSettingsDraft.status(of: bridge, in: [], paths: paths), "not serving")
        let active = ForwardStatus(flag: spec.flag, spec: spec.value, origin: .bridge, state: .active)
        XCTAssertEqual(VMSettingsDraft.status(of: bridge, in: [active], paths: paths), .active)
        let failed = ForwardStatus(flag: spec.flag, spec: spec.value, origin: .bridge, state: .failed("port taken"))
        XCTAssertEqual(VMSettingsDraft.status(of: bridge, in: [failed], paths: paths), .failed("port taken"))
        let other = ForwardStatus(flag: spec.flag, spec: spec.value, origin: .configured, state: .active)
        XCTAssertNil(VMSettingsDraft.status(of: bridge, in: [other], paths: paths), "only its own")
    }

    /// A Lima VM's user lives in /home/<user>.linux: a new folder goes there.
    func testAFolderAddedToALimaVMGoesInItsUsersHome() throws {
        var lima = saved
        lima.attached = AttachedDisk(lima: "default", dir: "/Users/x/.lima/default", home: "/home/dev.linux")
        var d = VMSettingsDraft(lima)
        d.addShare(hostPath: "/Users/x/src")
        XCTAssertEqual(d.config.sharing.shares.first?.guestPath, "/home/dev.linux/src")
        lima.attached = AttachedDisk(lima: "default", dir: "/Users/x/.lima/default")
        XCTAssertEqual(lima.home, "/home/dev.linux", "Lima's default when its list said nothing")
        XCTAssertEqual(saved.home, "/home/dev")
    }

    func testFoldersOutsideTheHomeFolderNeedConfirmation() {
        XCTAssertTrue(VMSettingsDraft.confirmShareText.contains("visible folders"),
                      "a home folder share says what the VM gets: \(VMSettingsDraft.confirmShareText)")
        XCTAssertFalse(VMSettingsDraft.needsConfirmation(share: "/Users/x/src", home: "/Users/x"))
        XCTAssertTrue(VMSettingsDraft.needsConfirmation(share: "/Users/x", home: "/Users/x"), "the whole home folder")
        XCTAssertTrue(VMSettingsDraft.needsConfirmation(share: "/Users/x/", home: "/Users/x"))
        XCTAssertTrue(VMSettingsDraft.needsConfirmation(share: "/Users/xy/src", home: "/Users/x"))
        XCTAssertTrue(VMSettingsDraft.needsConfirmation(share: "/etc", home: "/Users/x"))
        XCTAssertTrue(VMSettingsDraft.needsConfirmation(share: "/Users/x/../y", home: "/Users/x"))
    }

    func testSymlinksAreJudgedByWhereTheyLead() throws {
        let home = TempDir()
        let link = home.url.appendingPathComponent("etc-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
        let inside = home.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        XCTAssertTrue(VMSettingsDraft.needsConfirmation(share: link.path, home: home.url.path))
        XCTAssertFalse(VMSettingsDraft.needsConfirmation(share: inside.path, home: home.url.path))
    }

    func testIgnoredPortsAreTypedAsAList() throws {
        var d = VMSettingsDraft(saved)
        XCTAssertEqual(d.ignoredPortsText, "")
        d.ignoredPortsText = "5432, 6379 8080"
        XCTAssertTrue(d.isDirty)
        XCTAssertEqual(try build(d).autoForward.ignoredPorts, [5432, 6379, 8080])
        d.ignoredPortsText = "5432, redis"
        XCTAssertThrowsError(try build(d))
        XCTAssertEqual(VMSettingsDraft(try build({ var x = d; x.ignoredPortsText = "22,80"; return x }())).ignoredPortsText,
                       "22, 80")
    }

    func testHostChangesReplaceACleanDraftOnly() {
        var d = VMSettingsDraft(saved)
        var newer = saved
        newer.networks[0].macAddress = "52:54:00:00:00:02"
        d.refresh(from: newer)
        XCTAssertEqual(d.config, newer)
        XCTAssertFalse(d.isDirty)

        d.config.cpus = 6
        var newest = newer
        newest.memoryTargetGiB = 2
        d.refresh(from: newest)
        XCTAssertEqual(d.config.cpus, 6, "unsaved edits are kept")
        XCTAssertNil(d.config.memoryTargetGiB)
    }

    /// Each rule in words: whose port it is, and where it is reached.
    func testForwardsSayWhoseTheyAreAndWhereTheyAreReached() {
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .remote, hostPort: 8000, guestPort: 8000)),
                       "Mac port 8000, in the VM at 127.0.0.1:8000")
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)),
                       "VM port 80, on the Mac at 127.0.0.1:8080")
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .socks, hostPort: 1080)),
                       "SOCKS proxy on the Mac at 127.0.0.1:1080")
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .unixLocal, hostSocket: "/tmp/d.sock",
                                                            guestSocket: "/run/docker.sock")),
                       "VM socket /run/docker.sock, on the Mac at /tmp/d.sock")
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .unixRemote, hostSocket: "/tmp/a.sock",
                                                            guestSocket: "/run/a.sock")),
                       "Mac socket /tmp/a.sock, in the VM at /run/a.sock")
    }

    /// The usual forward: a program on the Mac (a web server, a tool's
    /// MCP port) used from the VM, at the same port unless told otherwise.
    func testAMacPortIsForwardedIntoTheVM() throws {
        let same = try XCTUnwrap(VMSettingsDraft.portForward(macPort: "8000", vmPort: "", intoVM: true))
        XCTAssertEqual([same.kind], [.remote])
        XCTAssertEqual(same.hostPort, 8000)
        XCTAssertEqual(same.guestPort, 8000, "the same port in the VM")
        let other = try XCTUnwrap(VMSettingsDraft.portForward(macPort: "24643", vmPort: " 9100 ", intoVM: true))
        XCTAssertEqual(other.guestPort, 9100)
        let fromVM = try XCTUnwrap(VMSettingsDraft.portForward(macPort: "8080", vmPort: "80", intoVM: false))
        XCTAssertEqual([fromVM.kind], [.local])
        XCTAssertEqual(fromVM.hostPort, 8080)
        XCTAssertEqual(fromVM.guestPort, 80)
        XCTAssertNil(VMSettingsDraft.portForward(macPort: "", vmPort: "80", intoVM: true), "the Mac port is needed")
        XCTAssertNil(VMSettingsDraft.portForward(macPort: "web", vmPort: "", intoVM: true))
        XCTAssertNotNil(VMSettingsDraft.confirmation(for: same), "the VM reaching into the Mac is asked first")
    }

    /// A VM port listens on the Mac's loopback unless another address is
    /// typed, which has to be an IP address; any but the loopback lets
    /// other computers in, which is said and asked.
    func testAVMPortCanListenOnAnyMacAddress() throws {
        let mine = try XCTUnwrap(VMSettingsDraft.portForward(macPort: "8080", vmPort: "80", intoVM: false, address: " "))
        XCTAssertEqual(mine.hostAddress, "127.0.0.1")
        XCTAssertNil(VMSettingsDraft.confirmation(for: mine))
        let open = try XCTUnwrap(VMSettingsDraft.portForward(macPort: "8080", vmPort: "80", intoVM: false, address: " 0.0.0.0 "))
        XCTAssertEqual(open.hostAddress, "0.0.0.0")
        XCTAssertEqual(VMSettingsDraft.describe(open), "VM port 80, on the Mac at 0.0.0.0:8080, open to other computers")
        XCTAssertEqual(VMSettingsDraft.confirmationTitle(for: open), "Open this port to other computers?")
        XCTAssertEqual(VMSettingsDraft.confirmation(for: open),
                       "Computers that reach this Mac at 0.0.0.0 will be able to connect to port 80 in the VM, through port 8080.")
        XCTAssertNil(VMSettingsDraft.portForward(macPort: "8080", vmPort: "80", intoVM: false, address: "my-mac.local"),
                     "an IP address")
        XCTAssertEqual(VMSettingsDraft.portForward(macPort: "8000", vmPort: "", intoVM: true, address: "0.0.0.0")?.hostAddress,
                       "127.0.0.1", "a forward into the Mac connects to its loopback")

        let proxy = try XCTUnwrap(VMSettingsDraft.socksForward(macPort: "1080", address: "192.168.1.20"))
        XCTAssertEqual([proxy.kind], [.socks])
        XCTAssertEqual(VMSettingsDraft.confirmation(for: proxy),
                       "Computers that reach this Mac at 192.168.1.20 will be able to use port 1080 as a proxy that leaves from the VM.")
        XCTAssertEqual(VMSettingsDraft.socksForward(macPort: "1080", address: "")?.hostAddress, "127.0.0.1")
        XCTAssertNil(VMSettingsDraft.socksForward(macPort: "proxy", address: ""))
        XCTAssertEqual(VMSettingsDraft.confirmationTitle(for: ForwardRule(kind: .remote, hostPort: 80, guestPort: 80)),
                       "Let the VM reach this Mac?")
    }

    /// A forward made the wrong way round (the Mac port already taken by
    /// the very program it was meant to reach) turns around in place.
    func testAForwardTurnsAround() {
        let wrong = ForwardRule(kind: .local, hostPort: 8000, guestPort: 8000)
        let turned = VMSettingsDraft.turnedAround(wrong)
        XCTAssertEqual(turned.id, wrong.id)
        XCTAssertEqual([turned.kind], [.remote])
        XCTAssertEqual(turned.hostPort, 8000)
        XCTAssertEqual(turned.guestPort, 8000)
        XCTAssertEqual([VMSettingsDraft.turnedAround(turned).kind], [.local])
        let open = ForwardRule(kind: .local, hostAddress: "0.0.0.0", hostPort: 8000, guestPort: 8000)
        XCTAssertEqual(VMSettingsDraft.turnedAround(open).hostAddress, "127.0.0.1", "into the Mac at its loopback")
        let socks = ForwardRule(kind: .socks, hostPort: 1080)
        XCTAssertEqual(VMSettingsDraft.turnedAround(socks), socks, "nothing to turn")
    }

    func testForwardStatusIsFoundForARule() {
        let rule = ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)
        let statuses = [ForwardStatus(flag: "-L", spec: "127.0.0.1:8080:127.0.0.1:80", origin: .configured, state: .active)]
        XCTAssertEqual(VMSettingsDraft.status(of: rule, in: statuses)?.state, .active)
        XCTAssertNil(VMSettingsDraft.status(of: ForwardRule(kind: .socks, hostPort: 1080), in: statuses))
    }

    // MARK: Forwards through SSH hosts

    private func sshForward(_ direction: SSHForward.Direction, guest: Int, host: String = "127.0.0.1", remote: Int) -> SSHForward {
        SSHForward(sshHost: "box", direction: direction, guestPort: guest, remoteHost: host, remotePort: remote)
    }

    /// As typed in the Add Forward sheet: nothing until it can be one.
    func testAForwardThroughAnSSHHostIsMadeFromWhatIsTyped() throws {
        func typed(_ direction: SSHForward.Direction, vm: String, host: String, remote: String) -> SSHForward? {
            VMSettingsDraft.sshForward(host: "box", direction: direction, vmPort: vm, remoteHost: host, remotePort: remote)
        }
        let same = try XCTUnwrap(typed(.intoVM, vm: "", host: "", remote: " 5432 "))
        XCTAssertTrue(same.sameRoute(sshForward(.intoVM, guest: 5432, remote: 5432)), "the same port, the server's loopback")
        let other = try XCTUnwrap(typed(.intoVM, vm: "15432", host: " db.internal ", remote: "5432"))
        XCTAssertTrue(other.sameRoute(sshForward(.intoVM, guest: 15432, host: "db.internal", remote: 5432)))
        let onto = try XCTUnwrap(typed(.ontoHost, vm: "8000", host: "", remote: "18000"))
        XCTAssertTrue(onto.sameRoute(sshForward(.ontoHost, guest: 8000, remote: 18000)))
        XCTAssertNil(typed(.ontoHost, vm: "", host: "", remote: "18000"), "which VM port?")
        XCTAssertNil(typed(.intoVM, vm: "", host: "", remote: ""))
        XCTAssertNil(typed(.intoVM, vm: "", host: "", remote: "80"), "the VM cannot listen below 1024")
        XCTAssertNil(typed(.intoVM, vm: "8080", host: "db:5432", remote: "80"))
        XCTAssertNil(typed(.ontoHost, vm: "8000", host: "example.com", remote: "8000"), "the server listens on an address")
    }

    /// Always confirmed, in words that say who reaches what.
    func testAForwardThroughAnSSHHostSaysWhoReachesWhat() {
        let db = sshForward(.intoVM, guest: 15432, host: "db.internal", remote: 5432)
        XCTAssertEqual(VMSettingsDraft.describe(db), "db.internal:5432 through the SSH host box, in the VM at 127.0.0.1:15432")
        XCTAssertEqual(VMSettingsDraft.confirmation(for: db),
                       "The VM will be able to connect to db.internal:5432 as the SSH host “box” reaches it, "
                       + "signed in as you there, past the VM's firewall.")
        let web = sshForward(.ontoHost, guest: 8000, host: "::", remote: 18000)
        XCTAssertEqual(VMSettingsDraft.describe(web), "VM port 8000, on the SSH host box at [::]:18000")
        XCTAssertEqual(VMSettingsDraft.confirmation(for: web),
                       "Whoever reaches [::]:18000 on the SSH host “box” will be able to connect to port 8000 in the VM.")
    }

    /// Its state is both halves': the VM's master's, then the SSH host's.
    func testAForwardThroughAnSSHHostIsUpWhenBothHalvesAre() {
        let paths = InstancePaths(name: "dev", root: URL(fileURLWithPath: "/Users/x/.monad/instances"))
        let f = sshForward(.intoVM, guest: 15432, host: "db.internal", remote: 5432)
        let near = f.vmSpec(in: paths), far = f.hostSpec(in: paths)
        func status(_ spec: SSHMux.Spec, _ state: ForwardStatus.State) -> ForwardStatus {
            ForwardStatus(flag: spec.flag, spec: spec.value, origin: .bridge, state: state)
        }
        func host(_ forwards: [ForwardStatus]?) -> SSHHostSnapshot {
            SSHHostSnapshot(config: SSHHost(name: "box", host: "example.com", user: "dev", auth: .key), hasPassword: false,
                            forwards: forwards)
        }
        func state(vm: [ForwardStatus], hosts: [SSHHostSnapshot]) -> ForwardStatus.State? {
            VMSettingsDraft.status(of: f, in: vm, hosts: hosts, paths: paths)
        }
        XCTAssertNil(state(vm: [], hosts: [host(nil)]), "not set up: the VM does not run it")
        XCTAssertEqual(state(vm: [status(near, .active)], hosts: [host([status(far, .active)])]), .active)
        XCTAssertEqual(state(vm: [status(near, .failed("remote port forwarding failed"))], hosts: [host([status(far, .active)])]),
                       .failed("remote port forwarding failed"))
        XCTAssertEqual(state(vm: [status(near, .active)], hosts: [host([status(far, .failed("Permission denied"))])]),
                       .failed("Permission denied"))
        XCTAssertEqual(state(vm: [status(near, .active)], hosts: [host(nil)]), .failed("Not set up yet."))
        XCTAssertEqual(state(vm: [status(near, .active)], hosts: []), .failed("There is no SSH host named box."))
    }

    func testRestartIsOfferedOnlyWhenARunningVMNeedsIt() {
        XCTAssertNil(VMSettingsDraft.restartPrompt(vm: "dev", pending: [], isRunning: true))
        XCTAssertNil(VMSettingsDraft.restartPrompt(vm: "dev", pending: ["CPUs"], isRunning: false))
        let one = VMSettingsDraft.restartPrompt(vm: "dev", pending: ["CPUs"], isRunning: true)
        XCTAssertEqual(one?.title, "Restart “dev” now?")
        XCTAssertEqual(one?.message, "The new CPUs setting is applied when the VM restarts. Programs running in the VM will be stopped.")
        let two = VMSettingsDraft.restartPrompt(vm: "dev", pending: ["CPUs", "memory", "network"], isRunning: true)
        XCTAssertEqual(two?.message,
                       "The new CPUs, memory and network settings are applied when the VM restarts. Programs running in the VM will be stopped.")
    }

    /// Checking Disable SIP says what happens: the VM goes to recovery by
    /// itself, changes it there and restarts, in a few minutes.
    func testDisablingSIPSaysWhatWillHappen() {
        let later = VMSettingsDraft.disableSIPConfirmation(vm: "mac", newVM: false)
        XCTAssertEqual(later.title, "Disable System Integrity Protection?")
        XCTAssertEqual(later.message, "At its next start, “mac” starts in macOS recovery by itself, turns System Integrity "
            + "Protection off there, and restarts into macOS. It takes a few minutes, and you don't need to do anything. "
            + "Turning it back on later needs the internet in the VM.")
        let new = VMSettingsDraft.disableSIPConfirmation(vm: "mac", newVM: true)
        XCTAssertTrue(new.message.hasPrefix("Once “mac” is made, it starts in macOS recovery by itself"), new.message)
        // The page says how SIP was found.
        XCTAssertEqual(VMSettingsDraft.sipFound(MacSecurityReport(sip: "enabled")), "On, as found when the VM last started.")
        XCTAssertEqual(VMSettingsDraft.sipFound(MacSecurityReport(sip: "disabled")), "Off, as found when the VM last started.")
        XCTAssertEqual(VMSettingsDraft.sipFound(MacSecurityReport(sip: "unknown (Custom Configuration)")),
                       "macOS says: unknown (Custom Configuration).")
        XCTAssertEqual(VMSettingsDraft.sipFound(nil), "Not known yet: it is read each time the VM starts.")
        XCTAssertEqual(VMSettingsDraft.sipFound(MacSecurityReport(sip: "")),
                       "macOS answered something Monad does not understand.", "an odd answer is not quoted")
        // The tag in the list: what the VM said at its last start, never the setting alone.
        XCTAssertEqual(VMSettingsDraft.sipTag(MacSecurityReport(sip: "enabled")), "SIP: On")
        XCTAssertEqual(VMSettingsDraft.sipTag(MacSecurityReport(sip: "disabled")), "SIP: Off")
        XCTAssertNil(VMSettingsDraft.sipTag(MacSecurityReport(sip: "unknown (Custom Configuration)")))
        XCTAssertNil(VMSettingsDraft.sipTag(nil))
    }

    func testSavingMakesTheDraftClean() throws {
        var d = VMSettingsDraft(saved)
        d.config.cpus = 3
        d.saved(try build(d))
        XCTAssertFalse(d.isDirty)
        XCTAssertEqual(d.appliesAfterRestart, [])
    }

    // MARK: An SSH host's own forwards, and servers by name

    /// An SSH host's own forwards are a VM's rules with the server in the
    /// VM's place: said in the same words, about the server.
    func testAForwardOfAServerIsSaidAboutTheServer() {
        let onto = ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)
        let into = ForwardRule(kind: .remote, hostPort: 5432, guestPort: 15432)
        XCTAssertEqual(VMSettingsDraft.describe(onto), "VM port 80, on the Mac at 127.0.0.1:8080")
        XCTAssertEqual(VMSettingsDraft.describe(onto, side: .server), "Server port 80, on the Mac at 127.0.0.1:8080")
        XCTAssertEqual(VMSettingsDraft.describe(into, side: .server), "Mac port 5432, on the server at 127.0.0.1:15432")
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .socks, hostPort: 1080), side: .server),
                       "SOCKS proxy on the Mac at 127.0.0.1:1080")
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .unixLocal, hostSocket: "/Users/dev/d.sock",
                                                            guestSocket: "/run/docker.sock"), side: .server),
                       "Server socket /run/docker.sock, on the Mac at /Users/dev/d.sock")
        XCTAssertEqual(VMSettingsDraft.describe(ForwardRule(kind: .unixRemote, hostSocket: "/Users/dev/a.sock",
                                                            guestSocket: "/tmp/a.sock"), side: .server),
                       "Mac socket /Users/dev/a.sock, on the server at /tmp/a.sock")

        // What is asked first: a server reaching into the Mac lets in whoever is on that server.
        XCTAssertEqual(VMSettingsDraft.confirmationTitle(for: into, side: .server), "Let the server reach this Mac?")
        XCTAssertEqual(VMSettingsDraft.confirmation(for: into, side: .server),
                       "Whoever is on the server will be able to connect to port 5432 on this Mac.")
        XCTAssertEqual(VMSettingsDraft.confirmation(for: into), "The VM will be able to connect to port 5432 on this Mac.")
        XCTAssertNil(VMSettingsDraft.confirmation(for: onto, side: .server))
        let open = ForwardRule(kind: .local, hostAddress: "0.0.0.0", hostPort: 8080, guestPort: 80)
        XCTAssertEqual(VMSettingsDraft.confirmation(for: open, side: .server),
                       "Computers that reach this Mac at 0.0.0.0 will be able to connect to port 80 on the server, through port 8080.")
    }

    /// In a VM's forward through an SSH host, what the server reaches can be
    /// picked: the server itself, or another SSH host by name (its address
    /// is not typed again).
    func testWhatAServerReachesCanBePickedFromTheSSHHosts() {
        let hosts = [SSHHost(name: "db", host: "10.0.0.5", user: "dev", auth: .key),
                     SSHHost(name: "bastion", host: "example.com", user: "dev", auth: .key),
                     SSHHost(name: "api", host: "api.internal", port: 2222, user: "ops", auth: .password)]
        XCTAssertEqual(VMSettingsDraft.reachChoices(through: "bastion", hosts: hosts), [
            VMSettingsDraft.ReachChoice(title: "The server itself (127.0.0.1)", address: "127.0.0.1"),
            VMSettingsDraft.ReachChoice(title: "api (api.internal)", address: "api.internal"),
            VMSettingsDraft.ReachChoice(title: "db (10.0.0.5)", address: "10.0.0.5"),
        ])
        XCTAssertEqual(VMSettingsDraft.reachChoices(through: "bastion", hosts: []).map(\.address), ["127.0.0.1"])
    }

    /// A display with nothing set up to show on it shows nothing: turning
    /// Display on adds the App windows profile, says so, and takes it back
    /// when Display is turned off again without it having been wanted.
    func testTurningDisplayOnAddsWhatShowsOnIt() {
        var profiles = ["agentic"]
        var added = VMSettingsDraft.displayChanged(to: true, profiles: &profiles, offered: ["agentic", "app-windows", "desktop"], addedBefore: false)
        XCTAssertTrue(added)
        XCTAssertEqual(profiles, ["agentic", "app-windows"])
        XCTAssertEqual(VMSettingsDraft.displayNote(display: true, profiles: profiles, added: added), VMSettingsDraft.displayProfileAdded)
        // Off again: what was added for it goes; what the user chose stays.
        added = VMSettingsDraft.displayChanged(to: false, profiles: &profiles, offered: ["agentic", "app-windows", "desktop"], addedBefore: true)
        XCTAssertFalse(added)
        XCTAssertEqual(profiles, ["agentic"])
        XCTAssertNil(VMSettingsDraft.displayNote(display: false, profiles: profiles, added: false))

        // The user has chosen what shows on it already: nothing is added, and nothing said.
        for chosen in ["desktop", "app-windows"] {
            profiles = [chosen]
            XCTAssertFalse(VMSettingsDraft.displayChanged(to: true, profiles: &profiles, offered: ["app-windows", "desktop"], addedBefore: false))
            XCTAssertEqual(profiles, [chosen])
            XCTAssertNil(VMSettingsDraft.displayNote(display: true, profiles: profiles, added: false))
            XCTAssertFalse(VMSettingsDraft.displayChanged(to: false, profiles: &profiles, offered: ["app-windows", "desktop"], addedBefore: false))
            XCTAssertEqual(profiles, [chosen], "the user's own choice is not taken back")
        }

        // A distribution the profile cannot be set up on (no apt): nothing to add, and that is said.
        profiles = []
        XCTAssertFalse(VMSettingsDraft.displayChanged(to: true, profiles: &profiles, offered: ["agentic"], addedBefore: false))
        XCTAssertEqual(profiles, [])
        XCTAssertEqual(VMSettingsDraft.displayNote(display: true, profiles: profiles, added: false), VMSettingsDraft.displayNeedsProfile)
        // The user unticked what was added: said as well.
        XCTAssertEqual(VMSettingsDraft.displayNote(display: true, profiles: ["agentic"], added: true), VMSettingsDraft.displayNeedsProfile)
        XCTAssertFalse(VMSettingsDraft.displayLacksProfile(display: false, profiles: []))
        XCTAssertTrue(VMSettingsDraft.displayLacksProfile(display: true, profiles: ["server"]))
    }
}
