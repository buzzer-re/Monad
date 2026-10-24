//
//  ConnectionsModelTests.swift — the VM window's Connections page (Phase
//  13): netd's log for one VM as rows (open ones first, then the most
//  recent), what decided each and why in words, filtering and searching,
//  and Allow or Block turning a row into a firewall rule at the top of the
//  VM's own (in place of one for exactly that destination).
//

import XCTest
@testable import Monad

@MainActor
final class ConnectionsModelTests: XCTestCase {
    private func conn(_ proto: FirewallRule.Proto = .tcp, _ address: String, _ port: Int = 443,
                      _ verdict: NetConnection.Verdict = .allowed, _ reason: NetConnection.Reason = .byDefault,
                      rule: Int? = nil, active: Int = 0, refused: Int = 0, last: Int = 0, name: String? = nil) -> NetConnection {
        NetConnection(proto: proto, address: address, port: port, verdict: verdict, reason: reason, rule: rule,
                      opened: verdict == .allowed ? 1 : 0, refused: refused, asked: verdict == .asked ? 1 : 0,
                      active: active, bytesOut: 100, bytesIn: 2000, firstSeen: last + 10, lastSeen: last, name: name)
    }

    private let github = NetConnection(proto: .tcp, address: "140.82.112.3", port: 443, verdict: .allowed, reason: .rule,
                                       rule: 0, opened: 3, refused: 0, asked: 0, active: 2, bytesOut: 1234,
                                       bytesIn: 56789, firstSeen: 120, lastSeen: 30, name: "github.com")

    private func config(_ firewall: VMFirewall = VMFirewall(), network: String = "default") -> InstanceConfig {
        var c = InstanceConfig.defaults(name: "dev")
        c.networks = [NetworkAttachment(network: network, macAddress: nil)]
        c.firewall = firewall
        return c
    }

    func testRowsSayWhatEachConnectionIs() {
        let dns = conn(.udp, "9.9.9.9", 53, .denied, .byDefault, refused: 4, last: 5)
        let ping = conn(.icmp, "1.1.1.1", 0, .asked, .monitor, last: 2)
        let rows = ConnectionsModel.rows([dns, github, ping], firewall: VMFirewall(), tags: [])
        XCTAssertEqual(rows.map(\.title), ["github.com", "1.1.1.1", "9.9.9.9"], "open first, then the most recent")
        XCTAssertEqual(rows[0].detail, "140.82.112.3, TCP port 443")
        XCTAssertEqual(rows[0].status, .open(2))
        XCTAssertEqual(rows[1].detail, "Ping")
        XCTAssertEqual(rows[1].status, .asked)
        XCTAssertEqual(rows[2].detail, "UDP port 53", "no name looked up: the address is the title")
        XCTAssertEqual(rows[2].status, .blocked)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        let closed = ConnectionsModel.rows([conn(.tcp, "1.2.3.4", 80, last: 9)], firewall: VMFirewall(), tags: [])
        XCTAssertEqual(closed.first?.status, .allowed)
    }

    func testWhySaysWhatDecided() {
        let tag = FirewallTag(name: "web", rules: [FirewallRule(action: .deny, proto: .any, target: "10.0.0.0/8"),
                                                    FirewallRule(action: .allow, proto: .udp, target: "*.ntp.org",
                                                                 ports: 123...123)])
        let other = FirewallTag(name: "unused", rules: [FirewallRule(action: .allow, proto: .tcp, target: "example.com")])
        let firewall = VMFirewall(rules: [FirewallRule(action: .allow, proto: .tcp, target: "github.com", ports: 443...443)],
                                  tags: ["missing", "web"])
        func why(_ c: NetConnection) -> String { ConnectionsModel.why(c, firewall: firewall, tags: [other, tag]) }
        XCTAssertEqual(why(github), "This VM's rule 1: Allow github.com, TCP port 443")
        XCTAssertEqual(why(conn(.tcp, "10.1.2.3", 22, .denied, .rule, rule: 1)), "Tag web, rule 1: Block 10.0.0.0/8")
        XCTAssertEqual(why(conn(.udp, "5.6.7.8", 123, .allowed, .rule, rule: 2)),
                       "Tag web, rule 2: Allow *.ntp.org, UDP port 123", "a missing tag adds no rules")
        XCTAssertEqual(why(conn(.tcp, "5.6.7.8", 80, .allowed, .rule, rule: 3)), "A rule that has changed since")
        XCTAssertEqual(why(conn(.tcp, "5.6.7.8", 80, .allowed, .session)), "Your answer, until the VM stops")
        XCTAssertEqual(why(conn(.tcp, "192.168.1.5", 80, .denied, .lan)), "This Mac and its network are blocked")
        XCTAssertEqual(why(conn(.tcp, "192.168.1.5", 80, .allowed, .lan)), "This Mac and its network are allowed")
        XCTAssertEqual(why(conn(.tcp, "5.6.7.8", 80, .allowed, .byDefault)), "No rule decides, so it is allowed")
        XCTAssertEqual(why(conn(.tcp, "5.6.7.8", 80, .denied, .byDefault)), "No rule allows it (only what the rules allow)")
        XCTAssertEqual(why(conn(.tcp, "5.6.7.8", 80, .asked, .monitor)), "Monitor mode asks you about it")
        XCTAssertEqual(why(conn(.tcp, "5.6.7.8", 80, .denied, .monitor)), "Monitor mode refused it, too many questions waiting")
        let rules = [FirewallRule(action: .deny, proto: .any, target: "example.com"),
                     FirewallRule(action: .allow, proto: .tcp, target: "1.2.3.0/24", ports: 8000...8100),
                     FirewallRule(action: .allow, proto: .icmp, target: "1.1.1.1/32")]
        XCTAssertEqual(rules.map(ConnectionsModel.describe),
                       ["Block example.com", "Allow 1.2.3.0/24, TCP ports 8000–8100", "Allow 1.1.1.1/32, ping"])
    }

    func testLastSeenInWords() {
        let cases: [(Int, String)] = [(0, "just now"), (4, "just now"), (5, "5 s ago"), (59, "59 s ago"),
                                      (60, "1 min ago"), (3599, "59 min ago"), (3600, "1 h ago"), (86400, "1 d ago")]
        for (seconds, text) in cases { XCTAssertEqual(ConnectionsModel.ago(seconds), text, "\(seconds)") }
    }

    func testFilterAndSearch() async {
        let list = [github, conn(.udp, "9.9.9.9", 53, .denied, .byDefault, last: 5),
                    conn(.tcp, "151.101.1.69", 443, last: 7, name: "pypi.org")]
        let model = ConnectionsModel(vm: "dev", fetch: { name in
            XCTAssertEqual(name, "dev")
            return list
        }, update: { _ in })
        XCTAssertFalse(model.loaded)
        await model.refresh(config: config(), tags: [])
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.shown.count, 3)
        model.filter = .open
        XCTAssertEqual(model.shown.map(\.title), ["github.com"])
        model.filter = .blocked
        XCTAssertEqual(model.shown.map(\.title), ["9.9.9.9"])
        model.filter = .all
        model.search = "PYPI"
        XCTAssertEqual(model.shown.map(\.title), ["pypi.org"], "names, either case")
        model.search = "140.82"
        XCTAssertEqual(model.shown.map(\.title), ["github.com"], "addresses")
        model.search = "53"
        XCTAssertEqual(model.shown.map(\.title), ["9.9.9.9"], "ports")
    }

    func testARefreshThatFailsSaysWhyAndKeepsTheRows() async {
        var fail = false
        let model = ConnectionsModel(vm: "dev", fetch: { _ in
            if fail { throw MonadError("MonadHost is not running.") }
            return [self.github]
        }, update: { _ in })
        await model.refresh(config: config(), tags: [])
        fail = true
        await model.refresh(config: config(), tags: [])
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.errorMessage, "MonadHost is not running.")
        fail = false
        await model.refresh(config: config(), tags: [])
        XCTAssertNil(model.errorMessage)
    }

    func testAllowAndBlockMakeARuleForTheDestination() {
        XCTAssertEqual(ConnectionsModel.rule(deciding: github, allow: false),
                       FirewallRule(action: .deny, proto: .tcp, target: "github.com", ports: 443...443), "by its name")
        XCTAssertEqual(ConnectionsModel.rule(deciding: conn(.udp, "9.9.9.9", 53), allow: true),
                       FirewallRule(action: .allow, proto: .udp, target: "9.9.9.9/32", ports: 53...53), "no name: the address")
        XCTAssertEqual(ConnectionsModel.rule(deciding: conn(.icmp, "1.1.1.1", 0), allow: true),
                       FirewallRule(action: .allow, proto: .icmp, target: "1.1.1.1/32"), "ping has no port")
        XCTAssertEqual(ConnectionsModel.rule(deciding: conn(.tcp, "192.168.1.5", 80, .denied, .lan, name: "nas.local"), allow: true),
                       FirewallRule(action: .allow, proto: .tcp, target: "192.168.1.5/32", ports: 80...80),
                       "a name never opens the Mac or its LAN: the address")
    }

    func testTheRuleGoesFirstInPlaceOfOneForTheSameDestination() {
        let block = FirewallRule(action: .deny, proto: .tcp, target: "github.com", ports: 443...443)
        let wide = FirewallRule(action: .allow, proto: .any, target: "github.com")
        let old = FirewallRule(action: .allow, proto: .tcp, target: "github.com", ports: 443...443)
        XCTAssertEqual(Firewall.putFirst(block, in: [wide, old]), [block, wide], "ahead of the rule that decided it")
        var editor = FirewallRulesEditor(rules: [wide, old])
        editor.setPorts(0, "80")
        editor.putFirst(block)
        XCTAssertEqual(editor.rules, [block, wide])
        XCTAssertEqual(editor.portsText(0), "443")
        XCTAssertEqual(editor.portsText(1), "80", "what was typed stays")
    }

    func testDecidingSavesTheVMsFirewall() async {
        var sent: [InstanceConfig] = []
        let model = ConnectionsModel(vm: "dev", fetch: { _ in [] }, update: { sent.append($0) })
        let row = ConnectionsModel.rows([github], firewall: VMFirewall(), tags: [])[0]
        let rule = await model.decide(row, allow: false, config: config(VMFirewall(rules: [
            FirewallRule(action: .allow, proto: .any, target: "github.com")])))
        XCTAssertEqual(rule, FirewallRule(action: .deny, proto: .tcp, target: "github.com", ports: 443...443))
        XCTAssertEqual(sent.first?.firewall.rules.first, rule)
        XCTAssertEqual(sent.first?.firewall.rules.count, 2)
        XCTAssertNil(model.errorMessage)
        let full = VMFirewall(rules: (1...Firewall.maxRules).map { FirewallRule(action: .allow, proto: .tcp, target: "h\($0).example") })
        let none = await model.decide(row, allow: true, config: config(full))
        XCTAssertNil(none)
        XCTAssertEqual(sent.count, 1, "too many rules: nothing sent")
        XCTAssertNotNil(model.errorMessage)
    }

    func testWhyThereIsNoLog() {
        let networks = [NetworkDefinition.builtInDefault]
        func why(_ c: InstanceConfig, running: Bool = true) -> String? {
            ConnectionsModel.unavailable(config: c, networks: networks, running: running)
        }
        XCTAssertNil(why(config()))
        XCTAssertEqual(why(config(), running: false), "Connections show while the VM runs.")
        var apple = config()
        apple.networks = [NetworkAttachment(network: NetworkDefinition.appleNATName, macAddress: nil)]
        XCTAssertEqual(why(apple), "This VM is on Apple's NAT, which Monad does not see. "
                       + "Move it to a Monad NAT network (such as default) and restart it to see its connections.")
        var offline = config()
        offline.networks = []
        XCTAssertEqual(why(offline), "This VM has no network device.")
        XCTAssertEqual(why(config(network: "gone")), "This VM's network does not exist any more.")
        for text in [why(apple), why(offline), why(config(), running: false)].compactMap({ $0 }) {
            XCTAssertFalse(text.contains(";"), text)
        }
    }
}
