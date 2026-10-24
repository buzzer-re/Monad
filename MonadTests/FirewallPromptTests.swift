//
//  FirewallPromptTests.swift — the monitor-mode prompt: which question is
//  shown, what it offers, and the answer it sends.
//

import XCTest
@testable import Monad

final class FirewallPromptTests: XCTestCase {
    private let google = FirewallAsk(id: 7, proto: .tcp, address: "142.250.1.2", port: 443, names: ["www.google.com"])

    private func config(_ name: String, monitor: Bool = true, tags: [String] = []) -> InstanceConfig {
        var c = InstanceConfig.defaults(name: name)
        c.firewall = VMFirewall(monitor: monitor, tags: tags)
        return c
    }

    func testTheOldestQuestionOfTheFirstVMIsShown() throws {
        let second = FirewallAsk(id: 8, proto: .udp, address: "8.8.8.8", port: 53, names: [])
        let p = try XCTUnwrap(FirewallPrompt.next(vms: [
            (config("web"), [second]),
            (config("dev"), [google, second]),
            (config("idle"), []),
        ], tags: []))
        XCTAssertEqual(p.vm, "dev")
        XCTAssertEqual(p.ask, google)
        XCTAssertEqual(p.waiting, 2)
        XCTAssertNil(FirewallPrompt.next(vms: [(config("idle"), [])], tags: []))
    }

    func testWhatItSays() throws {
        let p = try XCTUnwrap(FirewallPrompt.next(vms: [(config("dev"), [google])], tags: []))
        XCTAssertEqual(p.headline, "“dev” wants to connect to www.google.com")
        XCTAssertEqual(p.detail, "142.250.1.2, TCP port 443")
        let ping = FirewallAsk(id: 1, proto: .icmp, address: "1.1.1.1", port: 0, names: [])
        let q = try XCTUnwrap(FirewallPrompt.next(vms: [(config("dev"), [ping])], tags: []))
        XCTAssertEqual(q.headline, "“dev” wants to ping 1.1.1.1")
        XCTAssertEqual(q.detail, "No name was looked up for this address.")
        for text in [p.headline, p.detail, q.headline, q.detail] { XCTAssertFalse(text.contains(";")) }
    }

    func testALookupIsAskedAboutByName() throws {
        let p = try XCTUnwrap(FirewallPrompt.next(vms: [(config("dev"), [.lookup(id: 3, name: "api.example.com")])],
                                                  tags: []))
        XCTAssertEqual(p.headline, "“dev” wants to look up api.example.com")
        XCTAssertEqual(p.detail, "A name lookup. Allowing it also allows connections to the addresses it finds.")
        XCTAssertEqual(p.targets, [.name("api.example.com"), .name("example.com")])
        XCTAssertFalse(p.detail.contains(";"))
    }

    func testTheNameDefaultsToTheMostSpecificAndCountryDomainsAreNotOffered() throws {
        let p = try XCTUnwrap(FirewallPrompt.next(vms: [(config("dev"), [google])], tags: []))
        XCTAssertEqual(p.targets, [.name("www.google.com"), .name("google.com"), .address])
        XCTAssertEqual(p.target, .name("www.google.com"))
        let bbc = FirewallAsk(id: 2, proto: .tcp, address: "1.2.3.4", port: 443, names: ["www.bbc.co.uk"])
        XCTAssertEqual(bbc.targets, [.name("www.bbc.co.uk"), .name("bbc.co.uk"), .address], "never co.uk")
        let br = FirewallAsk(id: 3, proto: .tcp, address: "1.2.3.4", port: 443, names: ["loja.com.br"])
        XCTAssertEqual(br.targets, [.name("loja.com.br"), .address])
        let io = FirewallAsk(id: 4, proto: .tcp, address: "1.2.3.4", port: 443, names: ["api.abc.io"])
        XCTAssertEqual(io.targets, [.name("api.abc.io"), .name("abc.io"), .address])
    }

    /// An answer is saved where monitor mode came from: the VM, or the tag
    /// that turned it on. Any tag the VM carries can be chosen.
    func testWhereAnAnswerIsSaved() throws {
        let watch = FirewallTag(name: "Watch", rules: [], monitor: true)
        let web = FirewallTag(name: "Web", rules: [])
        var p = try XCTUnwrap(FirewallPrompt.next(vms: [(config("dev", tags: ["Web", "Watch"]), [google])],
                                                  tags: [watch, web]))
        XCTAssertEqual(p.scopes, [.vm, .tag("Web"), .tag("Watch")])
        XCTAssertEqual(p.scope, .vm, "the VM's own monitor mode")
        p = try XCTUnwrap(FirewallPrompt.next(vms: [(config("dev", monitor: false, tags: ["Web", "Watch", "Gone"]), [google])],
                                              tags: [watch, web]))
        XCTAssertEqual(p.scopes, [.vm, .tag("Web"), .tag("Watch")], "only tags that exist")
        XCTAssertEqual(p.scope, .tag("Watch"))
        XCTAssertEqual(p.answer(.block), FirewallAnswer(askID: 7, decision: .block, target: .name("www.google.com"),
                                                        scope: .tag("Watch")))
        p.target = .address
        XCTAssertEqual(p.answer(.allowUntilStop).target, .address)
        XCTAssertEqual(FirewallPrompt.label(for: .vm, vm: "dev"), "This VM (dev)")
        XCTAssertEqual(FirewallPrompt.label(for: .tag("Watch"), vm: "dev"), "Tag Watch")
        XCTAssertEqual(FirewallPrompt.label(for: .name("google.com")), "google.com and its subdomains")
        XCTAssertEqual(FirewallPrompt.label(for: .address, address: "1.2.3.4"), "Only 1.2.3.4")
    }
}
