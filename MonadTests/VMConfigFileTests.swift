//
//  VMConfigFileTests.swift — a VM's settings as a file: exported as saved
//  (instance.json), imported as a new VM on this Mac. An imported file is
//  untrusted: what reaches into the Mac stays out unless the user keeps
//  it, and every field is checked as on create. docs/CONFIG.md documents
//  every field, and its example is a VM this Monad makes.
//

import XCTest
@testable import Monad

final class VMConfigFileTests: XCTestCase {
    private let places = SharePolicy.Places(home: "/Users/dev", monad: "/Users/dev/.monad")

    private func mac(taken: Set<String> = [], networks: Set<String> = ["default", "lab"]) -> VMConfigFile.Mac {
        VMConfigFile.Mac(takenNames: taken, networks: networks, distros: ["ubuntu", "debian"], maxCPUs: 8,
                         maxMemoryGiB: 16, places: places)
    }

    /// A VM with everything set, Mac access included.
    private func full() -> InstanceConfig {
        var c = InstanceConfig.defaults(name: "web")
        c.distro = "ubuntu"
        c.release = "24.04"
        c.image = "Ubuntu 24.04 (20260901)"
        c.user = "dev"
        c.cpus = 4
        c.memoryGiB = 8
        c.memoryTargetGiB = 6
        c.diskGiB = 40
        c.networks = [NetworkAttachment(network: "lab", macAddress: "52:54:00:12:34:56")]
        c.firewall = VMFirewall(allowlist: true, allowLAN: true, rules: [
            FirewallRule(action: .allow, proto: .tcp, target: "github.com", ports: 443...443)])
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [
            SharedFolder(hostPath: "/Users/dev/src", guestPath: "/home/dev/src", readOnly: false),
            SharedFolder(hostPath: "/Users/dev", guestPath: "/mnt/home", readOnly: true, confirmed: true),
        ])
        c.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80),
                      ForwardRule(kind: .remote, hostPort: 5432, guestPort: 5432)]
        c.bridges = [CommandBridge(name: "mcp", command: ["/usr/bin/xcrun", "mcpbridge"], guestPort: 9001)]
        c.hostCommands = [buildCommand(in: "/Users/dev/src/app")]
        c.profiles = ["node"]
        c.theme = "monad-dark"
        c.startAtLaunch = true
        c.inlineImages = true
        return c
    }

    /// Export: the VM's settings as saved, read back as the same VM.
    func testAnExportIsTheVMsSettingsAsSaved() throws {
        let c = full()
        let data = try VMConfigFile.export(c)
        XCTAssertEqual(data, try c.encoded())
        XCTAssertEqual(try InstanceConfig.decode(data), c)
        XCTAssertEqual(VMConfigFile.fileName(for: c), "web.monad.json")
    }

    /// Import makes a new VM on this Mac: made now, from a fresh image, its
    /// own network addresses, never ephemeral; a taken name gets a number.
    func testAnImportIsANewVM() throws {
        var c = full()
        c.ephemeral = true
        c.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let imported = try VMConfigFile.read(try VMConfigFile.export(c), on: mac(taken: ["web", "web-2"]))
        let made = imported.config(named: imported.config.name, keepingMacAccess: false)
        XCTAssertEqual(made.name, "web-3")
        XCTAssertFalse(made.ephemeral)
        XCTAssertEqual(made.image, "", "set when the disk is made")
        XCTAssertGreaterThan(made.createdAt, c.createdAt)
        XCTAssertEqual(made.networks, [NetworkAttachment(network: "lab", macAddress: nil)])
        XCTAssertEqual([made.distro, made.release, made.user], ["ubuntu", "24.04", "dev"])
        XCTAssertEqual([made.cpus, made.memoryGiB, made.memoryTargetGiB, made.diskGiB], [4, 8, 6, 40])
        XCTAssertEqual(made.forwards, [c.forwards[0]], "forwards from the Mac into the VM stay")
        XCTAssertEqual(made.profiles, ["node"])
        XCTAssertEqual(made.theme, "monad-dark")
        XCTAssertTrue(made.startAtLaunch)
        XCTAssertTrue(imported.notes.contains { $0.contains("web-3") }, "\(imported.notes)")
        XCTAssertTrue(imported.notes.contains { $0.contains("MAC") }, "\(imported.notes)")
        XCTAssertNoThrow(try made.validate(maxCPUs: 8, maxMemoryGiB: 16))
    }

    /// What reaches into this Mac (shared folders, bridges, forwards into
    /// the Mac, the Mac and its network reachable, images it sends decoded on
    /// the Mac) stays out unless the user keeps it. A folder that needs the
    /// user's word is never brought in: the VM's settings ask for it.
    func testWhatReachesIntoTheMacStaysOutUnlessKept() throws {
        let c = full()
        let imported = try VMConfigFile.read(try VMConfigFile.export(c), on: mac())
        let access = imported.macAccess
        XCTAssertEqual(access.shares, [c.sharing.shares[0]], "the home folder needs the user's word")
        XCTAssertEqual(access.bridges, c.bridges)
        XCTAssertEqual(access.hostCommands, c.hostCommands)
        XCTAssertEqual(access.forwards, [c.forwards[1]])
        XCTAssertTrue(access.allowLAN)
        XCTAssertTrue(access.images)
        XCTAssertEqual(access.lines.count, 6, "\(access.lines)")
        XCTAssertTrue(imported.notes.contains { $0.contains("/Users/dev") && $0.contains("settings") }, "\(imported.notes)")

        let without = imported.config(named: "web", keepingMacAccess: false)
        XCTAssertEqual(without.sharing.shares, [])
        XCTAssertEqual(without.bridges, [])
        XCTAssertEqual(without.hostCommands, [], "a Mac command the VM varies needs the user's word too")
        XCTAssertFalse(without.forwards.contains(where: \.reachesIntoHost))
        XCTAssertFalse(without.firewall.allowLAN)
        XCTAssertFalse(without.inlineImages)
        XCTAssertTrue(without.firewall.allowlist, "the rest of the firewall stays")
        XCTAssertEqual(without.firewall.rules, c.firewall.rules)

        let with = imported.config(named: "web", keepingMacAccess: true)
        XCTAssertEqual(with.sharing.shares, [c.sharing.shares[0]])
        XCTAssertTrue(with.sharing.runtimeEnabled)
        XCTAssertEqual(with.bridges, c.bridges)
        XCTAssertEqual(with.hostCommands, c.hostCommands)
        XCTAssertEqual(with.forwards, c.forwards)
        XCTAssertTrue(with.firewall.allowLAN)
        XCTAssertTrue(with.inlineImages)
        XCTAssertNoThrow(try with.validate(maxCPUs: 8, maxMemoryGiB: 16))

        var plain = InstanceConfig.defaults(name: "plain")
        plain.distro = "debian"
        XCTAssertTrue(try VMConfigFile.read(try VMConfigFile.export(plain), on: mac()).macAccess.isEmpty)
    }

    /// A file's allow rules by address open the Mac and its network even
    /// without allowLAN (an address the user typed may): they are set aside
    /// with the rest of the Mac's access, back in their place when kept.
    /// Deny rules and rules by name stay.
    func testAllowRulesByAddressAreSetAside() throws {
        var c = InstanceConfig.defaults(name: "lab")
        c.distro = "debian"
        c.firewall.rules = [FirewallRule(action: .allow, proto: .any, target: "192.168.0.0/16"),
                            FirewallRule(action: .deny, proto: .any, target: "1.1.1.1"),
                            FirewallRule(action: .allow, proto: .tcp, target: "10.0.0.5", ports: 22...22),
                            FirewallRule(action: .allow, proto: .tcp, target: "github.com", ports: 443...443)]
        let imported = try VMConfigFile.read(try VMConfigFile.export(c), on: mac())
        XCTAssertEqual(imported.macAccess.firewallRules, [c.firewall.rules[0], c.firewall.rules[2]])
        XCTAssertEqual(imported.macAccess.lines, ["The firewall allows the VM 192.168.0.0/16",
                                                  "The firewall allows the VM 10.0.0.5, TCP port 22"])
        XCTAssertEqual(imported.config(named: "lab", keepingMacAccess: false).firewall.rules,
                       [c.firewall.rules[1], c.firewall.rules[3]])
        XCTAssertEqual(imported.config(named: "lab", keepingMacAccess: true).firewall.rules, c.firewall.rules,
                       "back in their order")
    }

    /// An auto-fill answer in a file is asked again: it types the VM's
    /// password into what the guest calls a prompt.
    func testAnAnsweredAutoFillIsAskedAgain() throws {
        var c = InstanceConfig.defaults(name: "desk")
        c.distro = "macos"
        c.release = nil
        c.guestOS = .macos
        c.cpus = 4
        c.memoryGiB = 4
        c.diskGiB = 64
        c.desktopAutofill = true
        let on = VMConfigFile.Mac(takenNames: [], networks: ["default"], distros: ["macos"], maxCPUs: 8, maxMemoryGiB: 16,
                                  places: places)
        let imported = try VMConfigFile.read(try VMConfigFile.export(c), on: on)
        XCTAssertNil(imported.config(named: "desk", keepingMacAccess: true).desktopAutofill)
        XCTAssertTrue(imported.notes.contains { $0.localizedCaseInsensitiveContains("auto-fill") }, "\(imported.notes)")
    }

    /// A file from another Mac fits this one: CPUs and memory within what
    /// this Mac gives, a network it does not have becomes "default", a Lima
    /// VM's file makes a VM from a fresh image. Each change is said.
    func testAFileFromAnotherMacFitsThisOne() throws {
        var c = full()
        c.cpus = 32
        c.memoryGiB = 64
        c.memoryTargetGiB = 48
        c.networks = [NetworkAttachment(network: "elsewhere", macAddress: nil)]
        c.attached = AttachedDisk(lima: "dev", dir: "/Users/dev/.lima/dev")
        c.diskGiB = 5
        let imported = try VMConfigFile.read(try VMConfigFile.export(c), on: mac())
        let made = imported.config(named: "web", keepingMacAccess: false)
        XCTAssertEqual(made.cpus, 8)
        XCTAssertEqual(made.memoryGiB, 16)
        XCTAssertEqual(made.memoryTargetGiB, 16)
        XCTAssertEqual(made.networks, [NetworkAttachment(network: NetworkDefinition.defaultName, macAddress: nil)])
        XCTAssertNil(made.attached)
        XCTAssertNil(made.copiedFrom)
        XCTAssertEqual(made.diskGiB, 10, "the smallest disk Monad makes")
        for word in ["CPUs", "memory", "elsewhere", "Lima"] {
            XCTAssertTrue(imported.notes.contains { $0.contains(word) }, "\(word) in \(imported.notes)")
        }
        XCTAssertNoThrow(try made.validate(maxCPUs: 8, maxMemoryGiB: 16))
    }

    /// A file written by hand or a script needs only its version, a name
    /// and a distribution: everything else is what the New VM sheet starts
    /// with, and the safe choice where there is one (a shared folder is
    /// read-only, a forward listens on the Mac's loopback only).
    func testAShortFileMakesAVM() throws {
        let text = #"""
        {"version": 2, "name": "web", "distro": "debian", "release": "13", "cpus": 2,
         "forwards": [{"kind": "local", "hostPort": 8080, "guestPort": 80}],
         "sharing": {"shares": [{"hostPath": "/Users/dev/src", "guestPath": "/home/dev/src"}]},
         "bridges": [{"name": "cat", "command": ["/bin/cat"], "guestPort": 9100}]}
        """#
        let imported = try VMConfigFile.read(Data(text.utf8), on: mac())
        let c = imported.config(named: "web", keepingMacAccess: true)
        XCTAssertEqual([c.distro, c.release], ["debian", "13"])
        XCTAssertEqual(c.cpus, 2)
        XCTAssertEqual(c.memoryGiB, InstanceConfig.defaults(name: "x").memoryGiB)
        XCTAssertEqual(c.diskGiB, InstanceConfig.defaults(name: "x").diskGiB)
        XCTAssertEqual(c.user, InstanceConfig.guestUserName())
        XCTAssertEqual(c.networks, [NetworkAttachment(network: NetworkDefinition.defaultName, macAddress: nil)])
        XCTAssertEqual(c.autoForward, AutoForwardSettings())
        XCTAssertEqual(c.firewall, VMFirewall())
        XCTAssertEqual(c.profiles, [])
        XCTAssertFalse(c.ephemeral)
        XCTAssertEqual(c.forwards.count, 1)
        XCTAssertEqual(c.forwards.first?.hostAddress, "127.0.0.1")
        XCTAssertEqual(c.forwards.first?.enabled, true)
        XCTAssertEqual(c.sharing.shares.first?.readOnly, true, "read-only unless the file says otherwise")
        XCTAssertTrue(c.sharing.runtimeEnabled)
        XCTAssertEqual(c.bridges.first?.enabled, true)
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16))

        XCTAssertThrowsError(try VMConfigFile.read(Data(#"{"version": 2, "distro": "debian"}"#.utf8), on: mac()),
                             "a name is needed")
        XCTAssertThrowsError(try VMConfigFile.read(Data(#"{"version": 2, "name": "web"}"#.utf8), on: mac()),
                             "a distribution is needed")
    }

    /// Files that are not a VM this Monad can make are refused, saying why.
    func testBadFilesAreRefused() throws {
        func refusal(_ data: Data) -> String {
            do {
                _ = try VMConfigFile.read(data, on: mac())
                return ""
            } catch {
                return error.localizedDescription
            }
        }
        XCTAssertTrue(refusal(Data(repeating: 0x20, count: VMConfigFile.maxBytes + 1)).contains("too large"))
        XCTAssertTrue(refusal(Data("not json".utf8)).contains("not a Monad VM"))
        XCTAssertTrue(refusal(Data(#"{"name":"web"}"#.utf8)).contains("not a Monad VM"))

        var newer = try JSONSerialization.jsonObject(with: try VMConfigFile.export(full())) as! [String: Any]
        newer["version"] = 99
        XCTAssertTrue(refusal(try JSONSerialization.data(withJSONObject: newer)).contains("newer Monad"))

        var unknown = full()
        unknown.distro = "plan9"
        XCTAssertTrue(refusal(try VMConfigFile.export(unknown)).contains("plan9"))

        var root = full()
        root.user = "root"
        XCTAssertTrue(refusal(try VMConfigFile.export(root)).contains("root"), "checked as on create")

        var badBridge = full()
        badBridge.bridges = [CommandBridge(name: "sh", command: ["sh", "-c", "id"], guestPort: 9001)]
        XCTAssertFalse(refusal(try VMConfigFile.export(badBridge)).isEmpty, "a bad bridge is a bad file")

        var badName = full()
        badName.name = "my vm"
        let named = try VMConfigFile.read(try VMConfigFile.export(badName), on: mac())
        XCTAssertTrue(InstanceConfig.isValidName(named.config.name), "a name this Monad takes is suggested")
    }

    /// The import sheet's name: one Monad takes, not in use in any case.
    func testTheImportSheetSaysWhatIsWrongWithAName() {
        let taken: Set<String> = ["web"]
        XCTAssertNil(VMConfigFile.nameProblem("db", taken: taken))
        XCTAssertEqual(VMConfigFile.nameProblem("Web", taken: taken), "A VM named “Web” exists.")
        XCTAssertEqual(VMConfigFile.nameProblem("my vm", taken: taken), "Use letters, digits and dashes (at most 32).")
        XCTAssertEqual(VMConfigFile.nameProblem("", taken: taken), "Use letters, digits and dashes (at most 32).")
    }

    // MARK: Editing on the Configuration page

    /// The VM's settings with a change made to their JSON.
    private func edited(_ c: InstanceConfig, _ change: (inout [String: Any]) -> Void = { _ in }) throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: c.encoded()) as? [String: Any])
        change(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The settings as saved check out and change nothing.
    func testTheSavedSettingsCheckOutAndChangeNothing() throws {
        let c = full()
        let check = VMConfigFile.check(String(decoding: try c.encoded(), as: UTF8.self), against: c, on: mac())
        XCTAssertEqual(check.problems, [])
        XCTAssertEqual(check.changes, [])
        XCTAssertFalse(check.canApply, "nothing to apply")
    }

    /// Broken JSON is one problem, saying where.
    func testBrokenJSONSaysWhere() {
        let check = VMConfigFile.check("{\n  \"cpus\": 4,\n  \"name\" \"web\"\n}", against: full(), on: mac())
        XCTAssertFalse(check.canApply)
        XCTAssertEqual(check.problems.count, 1, "\(check.problems)")
        XCTAssertTrue(check.problems.first?.message.contains("line 3") ?? false, "\(check.problems)")
        XCTAssertFalse(VMConfigFile.check("[1, 2]", against: full(), on: mac()).problems.isEmpty, "not an object")
    }

    /// A key Monad does not know is named where it is, with the one meant.
    func testUnknownKeysAreNamedWithTheOneMeant() throws {
        let c = full()
        let check = VMConfigFile.check(try edited(c) { o in
            o["cpu"] = 8
            var forwards = o["forwards"] as? [[String: Any]] ?? []
            forwards[0]["hostport"] = 9
            o["forwards"] = forwards
            o["colour"] = "red"
        }, against: c, on: mac())
        XCTAssertFalse(check.canApply)
        XCTAssertTrue(check.problems.contains { $0.path == "cpu" && $0.message.contains("“cpus”") }, "\(check.problems)")
        XCTAssertTrue(check.problems.contains { $0.path == "forwards[0].hostport" && $0.message.contains("“hostPort”") },
                      "\(check.problems)")
        XCTAssertTrue(check.problems.contains { $0.path == "colour" }, "\(check.problems)")
    }

    /// The key check knows every key a VM's settings can hold.
    func testTheKeyCheckKnowsEveryKey() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: everything().encoded()) as? [String: Any])
        XCTAssertEqual(VMConfigFile.unknownKeys(in: object), [])
        var mac = everything()
        mac.guestOS = .macos
        let macObject = try XCTUnwrap(JSONSerialization.jsonObject(with: mac.encoded()) as? [String: Any])
        XCTAssertNotNil(macObject["guestOS"])
        XCTAssertEqual(VMConfigFile.unknownKeys(in: macObject), [], "a macOS VM's settings")
    }

    /// Types and values are checked as on save, each named where it is.
    func testTypesAndValuesAreCheckedWhereTheyAre() throws {
        let c = full()
        func problems(_ change: (inout [String: Any]) -> Void) throws -> [VMConfigFile.Problem] {
            VMConfigFile.check(try edited(c, change), against: c, on: mac()).problems
        }
        let type = try problems { $0["cpus"] = "four" }
        XCTAssertTrue(type.contains { $0.path == "cpus" && $0.message.contains("number") }, "\(type)")
        let kind = try problems { o in
            var forwards = o["forwards"] as? [[String: Any]] ?? []
            forwards[0]["kind"] = "sideways"
            o["forwards"] = forwards
        }
        XCTAssertTrue(kind.contains { $0.path == "forwards[0].kind" }, "\(kind)")
        let range = try problems { $0["cpus"] = 99 }
        XCTAssertTrue(range.contains { $0.path == "cpus" && $0.message.contains("99 CPUs") }, "\(range)")
        let missing = try problems { $0.removeValue(forKey: "version") }
        XCTAssertTrue(missing.contains { $0.path == "version" }, "\(missing)")
        let refused = try problems { o in
            var sharing = o["sharing"] as? [String: Any] ?? [:]
            sharing["shares"] = [["hostPath": "/Users/dev/.monad/instances", "guestPath": "/mnt/m", "readOnly": true]]
            o["sharing"] = sharing
        }
        XCTAssertTrue(refused.contains { $0.path == "sharing.shares[0].hostPath" }, "Monad's own folder: \(refused)")
    }

    /// What was set when the VM was made cannot change here.
    func testWhatIsFixedCannotChange() throws {
        let c = full()
        let check = VMConfigFile.check(try edited(c) { o in
            o["name"] = "other"
            o["diskGiB"] = 99
            o["guestOS"] = "macos"
        }, against: c, on: mac())
        XCTAssertFalse(check.canApply)
        XCTAssertTrue(check.problems.contains { $0.path == "name" }, "\(check.problems)")
        XCTAssertTrue(check.problems.contains { $0.path == "diskGiB" }, "\(check.problems)")
        XCTAssertTrue(check.problems.contains { $0.path == "guestOS" }, "\(check.problems)")
    }

    /// A valid edit says what it changes and what it newly lets reach into
    /// the Mac (to be confirmed); a new folder that needs the user's word
    /// is confirmed by that.
    /// An edit that adds an allow rule by address reaches into the Mac (it
    /// may open the Mac's network without allowLAN): confirmed like the rest.
    func testANewAllowRuleByAddressIsConfirmed() throws {
        var c = full()
        c.firewall.allowLAN = false
        let check = VMConfigFile.check(try edited(c) { o in
            var firewall = o["firewall"] as? [String: Any] ?? [:]
            var rules = firewall["rules"] as? [[String: Any]] ?? []
            rules.append(["action": "allow", "proto": "any", "target": "192.168.0.0/16"])
            rules.append(["action": "deny", "proto": "any", "target": "10.0.0.1"])
            firewall["rules"] = rules
            o["firewall"] = firewall
        }, against: c, on: mac())
        XCTAssertEqual(check.problems, [])
        XCTAssertEqual(check.reachesIntoMac, ["The firewall allows the VM 192.168.0.0/16"], "the deny needs no word")
    }

    func testAValidEditSaysWhatChangesAndWhatReachesIntoTheMac() throws {
        var c = full()
        c.bridges = []
        c.firewall.allowLAN = false
        c.inlineImages = false
        let check = VMConfigFile.check(try edited(c) { o in
            o["cpus"] = 2
            o["bridges"] = [["name": "cat", "command": ["/bin/cat"], "guestPort": 9100]]
            var firewall = o["firewall"] as? [String: Any] ?? [:]
            firewall["allowLAN"] = true
            o["firewall"] = firewall
            var sharing = o["sharing"] as? [String: Any] ?? [:]
            var shares = sharing["shares"] as? [[String: Any]] ?? []
            shares.append(["hostPath": "/Users/dev/Library/Logs", "guestPath": "/mnt/logs"])
            sharing["shares"] = shares
            o["sharing"] = sharing
        }, against: c, on: mac())
        XCTAssertEqual(check.problems, [])
        XCTAssertTrue(check.canApply)
        XCTAssertEqual(check.config?.cpus, 2)
        XCTAssertEqual(Set(check.changes), ["CPUs", "bridges", "firewall", "shared folders"])
        XCTAssertEqual(check.reachesIntoMac.count, 3, "bridge, the Mac's network, the new folder: \(check.reachesIntoMac)")
        XCTAssertEqual(check.config?.sharing.shares.last?.confirmed, true, "confirmed with the rest")
        XCTAssertEqual(check.config?.sharing.shares.last?.readOnly, true, "read-only unless said")
    }

    /// A host command whose pattern is loosened (or that is new) reaches
    /// into the Mac anew and is confirmed; turning one off or on is not.
    func testAChangedHostCommandIsConfirmed() throws {
        let c = full()
        let looser = VMConfigFile.check(try edited(c) { o in
            var commands = o["hostCommands"] as? [[String: Any]] ?? []
            var args = commands[0]["arguments"] as? [[String: Any]] ?? []
            args[0]["pattern"] = "^.*$"
            commands[0]["arguments"] = args
            o["hostCommands"] = commands
        }, against: c, on: mac())
        XCTAssertEqual(looser.problems, [])
        XCTAssertEqual(looser.changes, ["host commands"])
        XCTAssertEqual(looser.reachesIntoMac.count, 1, "\(looser.reachesIntoMac)")
        XCTAssertTrue(looser.reachesIntoMac[0].contains("^.*$"))
        let off = VMConfigFile.check(try edited(c) { o in
            var commands = o["hostCommands"] as? [[String: Any]] ?? []
            commands[0]["enabled"] = false
            o["hostCommands"] = commands
        }, against: c, on: mac())
        XCTAssertEqual(off.reachesIntoMac, [])
    }

    /// A problem is found in the text: the key along its path (the second
    /// forward's "kind" for forwards[1].kind), or the line a JSON error names.
    func testAProblemIsFoundInTheText() throws {
        let text = try edited(full())
        let ns = text as NSString
        let kind = try XCTUnwrap(VMConfigFile.range(of: VMConfigFile.Problem(path: "forwards[1].kind", message: ""), in: text))
        XCTAssertTrue(ns.substring(from: kind.location).hasPrefix("\"kind\" : \"remote\""), ns.substring(from: kind.location))
        let cpus = try XCTUnwrap(VMConfigFile.range(of: VMConfigFile.Problem(path: "cpus", message: ""), in: text))
        XCTAssertEqual(ns.substring(with: cpus), "\"cpus\"")

        let broken = "{\n  \"cpus\": 4,\n  \"name\" \"web\"\n}"
        let check = VMConfigFile.check(broken, against: full(), on: mac())
        let line = try XCTUnwrap(VMConfigFile.range(of: try XCTUnwrap(check.problems.first), in: broken))
        XCTAssertEqual((broken as NSString).substring(with: line), "  \"name\" \"web\"")
        XCTAssertNil(VMConfigFile.range(of: VMConfigFile.Problem(path: "", message: "no place"), in: text))
    }

    /// Format lays out JSON the way instance.json is, without changing it.
    func testFormatLaysOutJSON() throws {
        let laid = try XCTUnwrap(VMConfigFile.format("{\"b\":1,\"a\":[1,2]}"))
        XCTAssertTrue(laid.hasPrefix("{\n  \"a\""), laid)
        XCTAssertEqual(VMConfigFile.format(laid), laid)
        XCTAssertNil(VMConfigFile.format("{nope"))
    }

    // MARK: docs/CONFIG.md

    private var configDoc: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("docs/CONFIG.md"), encoding: .utf8)
        }
    }

    /// Every key a VM's settings can hold is documented.
    /// Every key a VM's settings can hold, each set.
    private func everything() -> InstanceConfig {
        var c = full()
        c.networks[0].macAddress = "52:54:00:12:34:56"
        c.attached = AttachedDisk(lima: "dev", dir: "/Users/dev/.lima/dev", home: "/home/dev.linux")
        c.copiedFrom = c.attached
        c.forwards.append(ForwardRule(kind: .unixLocal, hostSocket: "/tmp/a.sock", guestSocket: "/run/a.sock"))
        c.bridges.append(CommandBridge(name: "s", command: ["/bin/cat"], guestSocket: "/run/cat.sock"))
        c.hostCommands[0].fixedArguments = ["-s"]
        c.agents = AgentAccess(role: .orchestrator, childCPUs: 2, childMemoryGiB: 2)
        c.parent = "boss"
        c.firewall.monitor = true
        c.firewall.tags = ["dev"]
        c.autoForward.ignoredPorts = [3000]
        return c
    }

    func testEveryFieldIsDocumented() throws {
        let c = everything()
        var keys = Set<String>()
        func collect(_ value: Any) {
            if let d = value as? [String: Any] {
                for (k, v) in d {
                    keys.insert(k)
                    collect(v)
                }
            } else if let a = value as? [Any] {
                a.forEach(collect)
            }
        }
        collect(try JSONSerialization.jsonObject(with: try c.encoded()))
        XCTAssertGreaterThan(keys.count, 40, "\(keys.sorted())")
        let doc = try configDoc
        for key in keys.sorted() {
            XCTAssertTrue(doc.contains("`\(key)`"), "docs/CONFIG.md does not document `\(key)`")
        }
    }

    /// The documented example is a VM this Monad makes.
    func testTheDocumentedExampleIsAVM() throws {
        let doc = try configDoc
        let start = try XCTUnwrap(doc.range(of: "```json\n"), "an example in docs/CONFIG.md")
        let end = try XCTUnwrap(doc.range(of: "\n```", range: start.upperBound..<doc.endIndex))
        let example = Data(doc[start.upperBound..<end.lowerBound].utf8)
        let imported = try VMConfigFile.read(example, on: mac())
        XCTAssertNoThrow(try imported.config(named: imported.config.name, keepingMacAccess: true)
            .validate(maxCPUs: 8, maxMemoryGiB: 16))
    }
}
