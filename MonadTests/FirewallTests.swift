//
//  FirewallTests.swift — each VM's firewall: its switches and rules, the
//  reusable tags it can carry, what netd is told, and the tag store.
//

import XCTest
@testable import Monad

final class FirewallTests: XCTestCase {
    private typealias Rule = FirewallRule

    private let github = Rule(action: .allow, proto: .tcp, target: "*.github.com", ports: 443...443)
    private let pypi = Rule(action: .allow, proto: .any, target: "pypi.org")
    private let noDocs = Rule(action: .deny, proto: .udp, target: "203.0.113.0/24")

    // MARK: Model

    func testTheDefaultBlocksTheMacAndItsLANOnly() {
        let f = VMFirewall()
        XCTAssertFalse(f.allowLAN)
        XCTAssertFalse(f.allowlist)
        XCTAssertEqual(f.rules, [])
        XCTAssertEqual(f.tags, [])
        XCTAssertNoThrow(try f.validate())
    }

    func testVMsFromBeforeFirewallsGetTheDefault() throws {
        var c = InstanceConfig.defaults(name: "old")
        c.firewall = VMFirewall(allowlist: true, allowLAN: true, rules: [github], tags: ["dev"])
        let data = try c.encoded()
        XCTAssertEqual(try InstanceConfig.decode(data), c, "round trip")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["firewall"] = nil
        let old = try InstanceConfig.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.firewall, VMFirewall())
        // Written only when set: a VM without one keeps the same file.
        XCTAssertFalse(String(decoding: try old.encoded(), as: UTF8.self).contains("firewall"))
    }

    func testRulesAreValidated() {
        let bad = [
            Rule(action: .allow, proto: .any, target: "exa mple.com"),
            Rule(action: .allow, proto: .any, target: "*github.com"),
            Rule(action: .allow, proto: .any, target: "10.0.0.1/8"),
            Rule(action: .allow, proto: .any, target: "10.0.0.0/33"),
            Rule(action: .allow, proto: .tcp, target: "10.0.0.0/8", ports: 0...80),
            Rule(action: .allow, proto: .icmp, target: "10.0.0.0/8", ports: 1...80),
            Rule(action: .deny, proto: .any, target: ""),
        ]
        for rule in bad {
            XCTAssertThrowsError(try VMFirewall(rules: [rule]).validate(), rule.target)
            XCTAssertThrowsError(try FirewallTag(name: "t", rules: [rule]).validate(), rule.target)
        }
        let many = Array(repeating: Rule(action: .deny, proto: .any, target: "1.2.3.4/32"), count: Firewall.maxRules + 1)
        XCTAssertThrowsError(try VMFirewall(rules: many).validate())
        XCTAssertThrowsError(try FirewallTag(name: "t", rules: many).validate())
        XCTAssertNoThrow(try VMFirewall(rules: [Rule(action: .deny, proto: .udp, target: "0.0.0.0/0", ports: 1...65535),
                                               Rule(action: .allow, proto: .any, target: "localhost")]).validate())
    }

    func testTagNames() {
        for bad in ["", "dev tools", "-dev", "_dev", String(repeating: "a", count: 33), "a/b", "dév", "a.b"] {
            XCTAssertThrowsError(try FirewallTag(name: bad, rules: []).validate(), bad)
            XCTAssertThrowsError(try VMFirewall(tags: [bad]).validate(), bad)
        }
        XCTAssertThrowsError(try VMFirewall(tags: ["dev", "dev"]).validate(), "a tag once")
        XCTAssertThrowsError(try VMFirewall(tags: ["Dev", "dev"]).validate(), "names differ in more than case")
        XCTAssertNoThrow(try VMFirewall(tags: ["dev", "ci-2", "Web", "NO_ADS"]).validate())
        XCTAssertNoThrow(try FirewallTag(name: "Web-Dev_2", rules: []).validate())
    }

    /// A Mac's disk does not tell "Web" from "web": one tag, whatever the case.
    func testTagNamesDifferInMoreThanCase() throws {
        let store = tempStore()
        try store.save(FirewallTag(name: "Web", rules: [github]))
        XCTAssertEqual(try store.tag(named: "Web")?.rules, [github])
        XCTAssertNil(try store.tag(named: "web"), "a VM names its tags exactly")
        XCTAssertThrowsError(try store.save(FirewallTag(name: "web", rules: [])), "would replace Web")
        XCTAssertEqual(try store.all().map(\.name), ["Web"])
        try store.save(FirewallTag(name: "Web", rules: [pypi]))
        XCTAssertEqual(try store.tag(named: "Web")?.rules, [pypi])
    }

    // MARK: Tags

    func testATagsRulesComeAfterTheVMsOwn() {
        let f = VMFirewall(allowlist: true, allowLAN: false, rules: [noDocs], tags: ["web", "python"])
        let tags = [FirewallTag(name: "python", rules: [pypi]), FirewallTag(name: "web", rules: [github])]
        let r = Firewall.resolve(f, tags: tags)
        XCTAssertEqual(r, Firewall.Resolved(allowlist: true, allowLAN: false, monitor: false, rules: [noDocs, github, pypi]))
        XCTAssertNil(r.problem)
    }

    /// A VM's group works as a tag: the group's tag rules come after the
    /// VM's own and its tags'; a group with no tag adds nothing and is no
    /// problem; a group the VM also carries as a tag counts once.
    func testAGroupActsAsATag() throws {
        var c = InstanceConfig.defaults(name: "web")
        c.firewall = VMFirewall(rules: [noDocs], tags: ["python"])
        c.group = "coding"
        let tags = [FirewallTag(name: "python", rules: [pypi]), FirewallTag(name: "coding", rules: [github])]
        let f = c.effectiveFirewall
        XCTAssertEqual(f.group, "coding")
        XCTAssertEqual(Firewall.resolve(f, tags: tags).rules, [noDocs, pypi, github])
        let lone = Firewall.resolve(f, tags: [FirewallTag(name: "python", rules: [pypi])])
        XCTAssertEqual(lone.rules, [noDocs, pypi])
        XCTAssertNil(lone.problem, "a group without rules is not a missing tag")
        c.firewall.tags = ["coding"]
        XCTAssertEqual(Firewall.resolve(c.effectiveFirewall, tags: tags).rules, [noDocs, github], "once")
        let monitor = [FirewallTag(name: "coding", rules: [], monitor: true)]
        var x = InstanceConfig.defaults(name: "x")
        x.group = "coding"
        XCTAssertTrue(Firewall.resolve(x.effectiveFirewall, tags: monitor).monitor, "the group's monitor mode too")
        // The group is not written in the VM's firewall: it is the VM's.
        let data = try JSONEncoder().encode(f)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("coding"))
    }

    func testAMissingTagIsLeftOutAndSaidSo() {
        let f = VMFirewall(rules: [noDocs], tags: ["gone", "web"])
        let r = Firewall.resolve(f, tags: [FirewallTag(name: "web", rules: [github])])
        XCTAssertEqual(r.rules, [noDocs, github])
        XCTAssertEqual(r.problem, "The firewall tag “gone” does not exist.")
    }

    /// More rules than netd holds: nothing is let out rather than some rules
    /// silently left out.
    func testTooManyRulesBlockEverything() {
        let rules = Array(repeating: Rule(action: .allow, proto: .any, target: "1.2.3.4/32"), count: 40)
        let f = VMFirewall(allowLAN: true, rules: rules, tags: ["big"])
        let r = Firewall.resolve(f, tags: [FirewallTag(name: "big", rules: rules)])
        XCTAssertEqual(r.allowlist, true)
        XCTAssertEqual(r.allowLAN, false)
        XCTAssertEqual(r.rules, [])
        XCTAssertNotNil(r.problem)
        XCTAssertThrowsError(try Firewall.checkSize(f, tags: [FirewallTag(name: "big", rules: rules)]))
        XCTAssertNoThrow(try Firewall.checkSize(VMFirewall(rules: rules), tags: []))
    }

    // MARK: Where a firewall is in effect

    func testAFirewallIsInEffectOnMonadNATNetworksOnly() {
        let networks = [NetworkDefinition.builtInDefault,
                        NetworkDefinition(name: "lab", kind: .internal, subnet: "10.78.0.0/24")]
        func effect(_ network: String?) -> Firewall.Effect {
            var c = InstanceConfig.defaults(name: "box")
            c.networks = network.map { [NetworkAttachment(network: $0, macAddress: nil)] } ?? []
            return Firewall.effect(for: c, networks: networks)
        }
        XCTAssertEqual(effect("default"), .active)
        XCTAssertEqual(effect("nat"), .appleNAT)
        XCTAssertEqual(effect("apple-nat"), .appleNAT)
        XCTAssertEqual(effect(nil), .noNetwork)
        XCTAssertEqual(effect("lab"), .closedNetwork)
        XCTAssertEqual(effect("gone"), .unknownNetwork)
        for e in [Firewall.Effect.appleNAT, .noNetwork, .closedNetwork, .unknownNetwork] {
            XCTAssertFalse(e.explanation.isEmpty)
            XCTAssertFalse(e.explanation.contains(";"), e.explanation)
        }
        XCTAssertTrue(Firewall.Effect.appleNAT.explanation.contains("Apple"))
    }

    // MARK: netd

    func testNetdCommandsForAPort() {
        let r = Firewall.Resolved(allowlist: true, allowLAN: true, monitor: false, rules: [
            Rule(action: .allow, proto: .tcp, target: "192.168.1.50/32", ports: 5432...5432),
            Rule(action: .deny, proto: .any, target: "*.example.com"),
            Rule(action: .allow, proto: .icmp, target: "10.0.0.0/8"),
        ])
        XCTAssertEqual(Firewall.netdCommands(r, port: 7), [
            "firewall 7 allowlist=1 lan=1 monitor=0",
            "rule allow tcp 192.168.1.50/32 ports=5432-5432",
            "rule deny any *.example.com",
            "rule allow icmp 10.0.0.0/8",
            "commit",
        ])
        XCTAssertEqual(Firewall.netdCommands(Firewall.Resolved(allowlist: false, allowLAN: false, monitor: false, rules: []), port: 0),
                       ["firewall 0 allowlist=0 lan=0 monitor=0", "commit"])
    }

    /// A bare address is that address (netd reads a target without a
    /// prefix as a name, which an address never matches as one).
    func testABareAddressIsSentAsOneHost() {
        let r = Firewall.Resolved(allowlist: false, allowLAN: false, monitor: false, rules: [
            Rule(action: .deny, proto: .any, target: "1.1.1.1"),
            Rule(action: .deny, proto: .any, target: "one.one.one.one"),
        ])
        XCTAssertEqual(Firewall.netdCommands(r, port: 3), [
            "firewall 3 allowlist=0 lan=0 monitor=0",
            "rule deny any 1.1.1.1/32",
            "rule deny any one.one.one.one",
            "commit",
        ])
        // It is a rule by address: valid as one, and an allow of it may open the Mac's network.
        let one = Rule(action: .allow, proto: .any, target: "192.168.1.10")
        XCTAssertTrue(one.isAddressRule)
        XCTAssertTrue(one.opensByAddress)
        XCTAssertNoThrow(try Firewall.validate([one]))
        XCTAssertFalse(Rule(action: .allow, proto: .any, target: "1.1.1").isAddressRule, "not an address: a name")
        XCTAssertThrowsError(try Firewall.validate([Rule(action: .deny, proto: .any, target: "2606:4700::1111")]),
                             "netd has no IPv6: such a rule cannot be saved")
    }

    /// Everything a valid firewall renders is accepted by netd's own parser.
    func testNetdAcceptsWhatFirewallsRender() throws {
        let d = try XCTUnwrap(mnd_netd_create())
        defer { mnd_netd_destroy(d) }
        let ctl = try XCTUnwrap(mnd_ctl_create(d, nil, nil))
        defer { mnd_ctl_destroy(ctl) }
        func run(_ line: String, fd: Int32 = -1) -> String {
            var out = [CChar](repeating: 0, count: 256)
            if fd >= 0 {
                var nl = Array((line + "\n").utf8)
                var fds = [fd]
                _ = mnd_ctl_feed(ctl, &nl, nl.count, &fds, 1)
                return "sent"
            }
            mnd_ctl_command(ctl, line, &out, out.count)
            return String(cString: out)
        }
        XCTAssertEqual(run(NetworkDefinition.builtInDefault.netdNetworkCommand), "ok 0")
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sv), 0)
        defer { close(sv[1]) }
        _ = run("port 0 02:4d:4f:4e:00:31", fd: sv[0])
        let f = VMFirewall(allowlist: true, allowLAN: false, rules: [
            Rule(action: .allow, proto: .tcp, target: "192.168.1.50/32", ports: 5432...5432),
            Rule(action: .allow, proto: .any, target: "*.GitHub.com"),
            Rule(action: .deny, proto: .udp, target: "0.0.0.0/0", ports: 1...65535),
            Rule(action: .allow, proto: .icmp, target: "pypi.org"),
            Rule(action: .deny, proto: .any, target: "under_score.example"),
        ])
        XCTAssertNoThrow(try f.validate())
        for line in Firewall.netdCommands(Firewall.resolve(f, tags: []), port: 0) {
            XCTAssertEqual(run(line), "ok", line)
        }
    }

    // MARK: Monitor mode

    func testMonitorModeIsTheVMsOrATags() throws {
        XCTAssertFalse(VMFirewall().monitor)
        // Files from before monitor mode load without it.
        let old = try JSONDecoder().decode(VMFirewall.self, from: Data(#"{"allowLAN":true,"allowlist":false,"rules":[],"tags":[]}"#.utf8))
        XCTAssertEqual(old, VMFirewall(allowLAN: true))
        let oldTag = try FirewallTag.decode(Data(#"{"version":1,"name":"web","rules":[]}"#.utf8))
        XCTAssertFalse(oldTag.monitor)
        var watch = FirewallTag(name: "Watch", rules: [])
        watch.monitor = true
        XCTAssertTrue(Firewall.resolve(VMFirewall(monitor: true), tags: []).monitor)
        XCTAssertTrue(Firewall.resolve(VMFirewall(tags: ["Watch"]), tags: [watch]).monitor, "from a tag it carries")
        XCTAssertFalse(Firewall.resolve(VMFirewall(), tags: [watch]).monitor)
        let r = Firewall.Resolved(allowlist: false, allowLAN: false, monitor: true, rules: [])
        XCTAssertEqual(Firewall.netdCommands(r, port: 2), ["firewall 2 allowlist=0 lan=0 monitor=1", "commit"])
    }

    func testAnswersBecomeRules() {
        let ask = FirewallAsk(id: 1, proto: .tcp, address: "142.250.1.2", port: 443, names: ["www.google.com"])
        XCTAssertEqual(Firewall.rule(answering: ask, allow: false, target: .name("www.google.com")),
                       FirewallRule(action: .deny, proto: .tcp, target: "www.google.com", ports: 443...443))
        XCTAssertEqual(Firewall.rule(answering: ask, allow: true, target: .address),
                       FirewallRule(action: .allow, proto: .tcp, target: "142.250.1.2/32", ports: 443...443))
        let ping = FirewallAsk(id: 2, proto: .icmp, address: "1.1.1.1", port: 0, names: [])
        XCTAssertEqual(Firewall.rule(answering: ping, allow: true, target: .address),
                       FirewallRule(action: .allow, proto: .icmp, target: "1.1.1.1/32"))
        XCTAssertEqual(Firewall.sessionCommand(FirewallRule(action: .allow, proto: .tcp, target: "google.com",
                                                            ports: 443...443), port: 3),
                       "session 3 allow tcp google.com ports=443-443")
        // The names to offer: each name the address was looked up as, and its domain.
        XCTAssertEqual(ask.targets, [.name("www.google.com"), .name("google.com"), .address])
        XCTAssertEqual(ping.targets, [.address])
        let deep = FirewallAsk(id: 3, proto: .udp, address: "1.2.3.4", port: 53, names: ["a.b.example.co", "x.io"])
        XCTAssertEqual(deep.targets, [.name("a.b.example.co"), .name("b.example.co"), .name("example.co"),
                                      .name("x.io"), .address])
    }

    func testWhichQuestionsARuleAnswers() {
        let ask = FirewallAsk(id: 1, proto: .tcp, address: "142.250.1.2", port: 443, names: ["www.google.com"])
        let rule = { (t: String, p: FirewallRule.Proto, ports: ClosedRange<Int>?) in
            FirewallRule(action: .allow, proto: p, target: t, ports: ports)
        }
        XCTAssertTrue(rule("google.com", .tcp, 443...443).answers(ask))
        XCTAssertTrue(rule("*.google.com", .any, nil).answers(ask))
        XCTAssertTrue(rule("142.250.0.0/16", .tcp, 1...1000).answers(ask))
        XCTAssertFalse(rule("google.com", .udp, nil).answers(ask))
        XCTAssertFalse(rule("google.com", .tcp, 80...80).answers(ask))
        XCTAssertFalse(rule("oogle.com", .tcp, nil).answers(ask))
        XCTAssertFalse(rule("142.251.0.0/16", .tcp, nil).answers(ask))
        let ping = FirewallAsk(id: 2, proto: .icmp, address: "1.1.1.1", port: 0, names: [])
        XCTAssertFalse(rule("1.1.1.1/32", .icmp, 1...10).answers(ping), "a rule with ports never matches ping")
        XCTAssertTrue(rule("1.1.1.1/32", .icmp, nil).answers(ping))
    }

    func testNetdAsksAreParsed() {
        XCTAssertEqual(FirewallAsk.parse("event ask 3 tcp 93.184.216.34 443 www.example.com,example.com", id: 9),
                       FirewallAskEvent(port: 3, ask: FirewallAsk(id: 9, proto: .tcp, address: "93.184.216.34", port: 443,
                                                                  names: ["www.example.com", "example.com"])))
        XCTAssertEqual(FirewallAsk.parse("event ask 0 icmp 1.1.1.1 0", id: 1)?.ask.names, [])
        // A bad name is dropped, not the question: a held connection must not go unasked (F-04).
        XCTAssertEqual(FirewallAsk.parse("event ask 1 tcp 1.1.1.1 1 good.example,b!d.example,*.wild.example",
                                         id: 2)?.ask.names, ["good.example"])
        XCTAssertEqual(FirewallAsk.parse("event ask 1 tcp 1.1.1.1 1 b!d.example", id: 3)?.ask.names, [])
        for bad in ["event ask x tcp 1.1.1.1 1", "event ask 1 sctp 1.1.1.1 1", "event ask 1 tcp 1.1.1 1",
                    "event ask 1 tcp 1.1.1.1 70000", "event ask 1 tcp 1.1.1.1", "event other", "ok",
                    "event ask 1 tcp 1.1.1.1 1 bad name"] {
            XCTAssertNil(FirewallAsk.parse(bad, id: 1), bad)
        }
    }

    /// Monitor mode asks about a lookup by name (F-10): nothing but the name
    /// and its domains to offer, and the answer covers connections to what
    /// the name finds, as netd decides lookups.
    func testLookupsAreAskedByName() throws {
        let parsed = FirewallAsk.parse("event lookup 4 api.example.com", id: 5)
        XCTAssertEqual(parsed, FirewallAskEvent(port: 4, ask: .lookup(id: 5, name: "api.example.com")))
        let ask = try XCTUnwrap(parsed?.ask)
        XCTAssertTrue(ask.isLookup)
        XCTAssertEqual(ask.targets, [.name("api.example.com"), .name("example.com")])
        XCTAssertEqual(Firewall.rule(answering: ask, allow: true, target: .name("example.com")),
                       FirewallRule(action: .allow, proto: .any, target: "example.com"))
        XCTAssertTrue(FirewallRule(action: .allow, proto: .tcp, target: "example.com", ports: 443...443).answers(ask))
        XCTAssertTrue(FirewallRule(action: .deny, proto: .any, target: "example.com").answers(ask))
        XCTAssertFalse(FirewallRule(action: .deny, proto: .tcp, target: "example.com", ports: 25...25).answers(ask))
        XCTAssertFalse(FirewallRule(action: .allow, proto: .any, target: "93.184.216.0/24").answers(ask))
        XCTAssertFalse(FirewallRule(action: .allow, proto: .any, target: "example.com").answers(google443),
                       "a connection is not a lookup: by name only with the name known")
        for bad in ["event lookup x a.example", "event lookup 1", "event lookup 1 b!d.example",
                    "event lookup 1 *.example.com", "event lookup 1 a.example extra", "event lookup -1 a.example"] {
            XCTAssertNil(FirewallAsk.parse(bad, id: 1), bad)
        }
    }

    private var google443: FirewallAsk {
        FirewallAsk(id: 1, proto: .tcp, address: "142.250.1.2", port: 443, names: [])
    }

    // MARK: Store

    private func tempStore() -> FirewallTagStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return FirewallTagStore(directory: dir)
    }

    func testTheTagStore() throws {
        let store = tempStore()
        XCTAssertEqual(try store.all(), [])
        try store.save(FirewallTag(name: "web", rules: [github]))
        try store.save(FirewallTag(name: "python", rules: [pypi]))
        XCTAssertEqual(try store.all().map(\.name), ["python", "web"])
        XCTAssertEqual(try store.tag(named: "web")?.rules, [github])
        let file = store.directory.appendingPathComponent("web.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int,
                       0o700)
        XCTAssertThrowsError(try store.save(FirewallTag(name: "Bad Name", rules: [])))
        try store.delete(named: "web")
        XCTAssertEqual(try store.all().map(\.name), ["python"])
        XCTAssertEqual(FirewallTag(name: "x", rules: [github]).version, FirewallTag.currentVersion)
    }

    func testBrokenTagFilesAreSkipped() throws {
        let store = tempStore()
        try store.save(FirewallTag(name: "web", rules: [github]))
        try Data("{not json".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
        try FirewallTag(name: "other", rules: []).encoded().write(to: store.directory.appendingPathComponent("renamed.json"))
        let bad = FirewallTag(name: "evil", rules: [Rule(action: .allow, proto: .any, target: "no way")])
        try bad.encoded().write(to: store.directory.appendingPathComponent("evil.json"))
        try Data(#"{"version": 99, "name": "future", "rules": []}"#.utf8)
            .write(to: store.directory.appendingPathComponent("future.json"))
        XCTAssertEqual(try store.all().map(\.name), ["web"])
    }

    // MARK: Editing rules as text

    func testRulesAreEditedWithPortsAsText() throws {
        var e = FirewallRulesEditor(rules: [github])
        XCTAssertEqual(e.portsTexts, ["443"])
        e.add()
        e.update(1) { $0.target = " 10.0.0.0/8 " }
        e.setPorts(1, "8000 - 8100")
        XCTAssertEqual(try e.validatedRules(), [github, Rule(action: .allow, proto: .tcp, target: "10.0.0.0/8",
                                                              ports: 8000...8100)])
        e.setPorts(1, "nope")
        XCTAssertThrowsError(try e.validatedRules())
        e.setPorts(1, "")
        XCTAssertEqual(try e.validatedRules()[1].ports, nil)
        e.update(1) { $0.target = "not a host" }
        XCTAssertThrowsError(try e.validatedRules())
        e.remove(1)
        XCTAssertEqual(try e.validatedRules(), [github])
        XCTAssertTrue(e.differs(from: []))
        XCTAssertFalse(e.differs(from: [github]))
        e.setPorts(0, "444")
        XCTAssertTrue(e.differs(from: [github]), "unsaved port text counts")
    }

    /// SwiftUI can still draw a row for a rule that was just removed: reading
    /// or writing it must be harmless.
    func testStaleRuleIndexesAreHarmless() {
        var e = FirewallRulesEditor(rules: [])
        e.add()
        e.remove(0)
        XCTAssertNil(e.rule(0))
        e.update(0) { $0.target = "x" }
        e.setPorts(3, "80")
        e.remove(5)
        XCTAssertEqual(e.rules, [])
        XCTAssertEqual(e.portsText(3), "")
        e.add()
        e.update(0) { $0.action = .deny }
        XCTAssertEqual(e.rule(0)?.action, .deny)
    }

    func testPortsAreTypedAsText() {
        XCTAssertTrue(FirewallRulesEditor.ports(from: "") == nil, "empty: no range at all")
        XCTAssertEqual(FirewallRulesEditor.ports(from: "5432"), 5432...5432)
        XCTAssertEqual(FirewallRulesEditor.ports(from: " 8000 - 8100 "), 8000...8100)
        XCTAssertEqual(FirewallRulesEditor.portsText(8000...8100), "8000-8100")
        XCTAssertEqual(FirewallRulesEditor.portsText(22...22), "22")
        XCTAssertEqual(FirewallRulesEditor.portsText(nil), "")
        for bad in ["abc", "80-", "-80", "9000-8000", "0", "70000", "1-2-3"] {
            // Present but invalid (.some(nil)), unlike empty text (nil).
            guard case .some(.none) = FirewallRulesEditor.ports(from: bad) else { return XCTFail(bad) }
        }
    }
}
