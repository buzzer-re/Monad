//
//  MCPAccessTests.swift — who may call which of Monad's MCP tools, and when
//  the user is asked (agents phase): agents on the Mac freely but for risky
//  tools; a VM without a role never; a VM with host commands only those; an
//  orchestrator freely on its own children, asking for anything else.
//  "Always" answers are kept per caller, and every call is in the audit log.
//

import XCTest
@testable import Monad

@MainActor
final class MCPAccessTests: XCTestCase {
    private func vms() -> [String: InstanceConfig] {
        var boss = InstanceConfig.defaults(name: "boss")
        boss.agents = AgentAccess(role: .orchestrator)
        var runner = InstanceConfig.defaults(name: "runner")
        runner.agents = AgentAccess(role: .hostCommands)
        var child = InstanceConfig.defaults(name: "kid")
        child.parent = "boss"
        let other = InstanceConfig.defaults(name: "other")
        return ["boss": boss, "runner": runner, "kid": child, "other": other]
    }

    private func decide(_ caller: MCPCaller, _ tool: String, _ risk: MCPTool.Risk, name: String? = nil,
                        grants: MCPGrants = MCPGrants()) -> MCPAccess.Decision {
        MCPAccess.decide(caller: caller, tool: tool, risk: risk, arguments: name.map { ["name": .string($0)] } ?? [:],
                         vms: vms(), grants: grants)
    }

    /// Making a macOS VM ends in the Mac's administrator password prompt
    /// (and 25 GB): any agent asks first, an orchestrator too.
    func testMakingAMacOSVMAsksFirst() {
        func decide(_ caller: MCPCaller, grants: MCPGrants = MCPGrants()) -> MCPAccess.Decision {
            MCPAccess.decide(caller: caller, tool: "create_vm", risk: .normal, arguments: ["name": .string("update")],
                             vms: vms(), grants: grants, makesAMac: true)
        }
        XCTAssertEqual(decide(.mac), .ask)
        XCTAssertEqual(decide(.vm("boss")), .ask)
        var g = MCPGrants()
        g.add(.vm("boss"), tool: "create_vm")
        XCTAssertEqual(decide(.vm("boss"), grants: g), .allow, "unless always allowed")
        XCTAssertEqual(MCPAccess.decide(caller: .vm("boss"), tool: "create_vm", risk: .normal, arguments: [:], vms: vms(),
                                        grants: MCPGrants()), .allow, "a Linux VM as before")
    }

    func testAgentsOnTheMacAreAskedOnlyForRiskyTools() {
        XCTAssertEqual(decide(.mac, "list_vms", .read), .allow)
        XCTAssertEqual(decide(.mac, "exec", .normal, name: "other"), .allow)
        XCTAssertEqual(decide(.mac, "add_bridge", .risky, name: "other"), .ask)
        var g = MCPGrants()
        g.add(.mac, tool: "add_bridge")
        XCTAssertEqual(decide(.mac, "add_bridge", .risky, grants: g), .allow, "always, for that tool")
        XCTAssertEqual(decide(.mac, "delete_vm", .risky, grants: g), .ask)
        g.add(.mac, tool: nil)
        XCTAssertEqual(decide(.mac, "delete_vm", .risky, grants: g), .allow, "always, for everything")
    }

    func testAVMWithoutARoleGetsNothing() {
        XCTAssertEqual(decide(.vm("other"), "list_vms", .read), .deny("This VM has no access to Monad."))
        XCTAssertEqual(decide(.vm("ghost"), "list_vms", .read), .deny("This VM has no access to Monad."))
        XCTAssertEqual(MCPAccess.visible(MonadToolsTests.sampleTools, to: .vm("other"), vms: vms()).map(\.name), [])
    }

    func testAHostCommandsVMRunsOnlyItsHostCommands() {
        XCTAssertEqual(decide(.vm("runner"), "host_make", .normal), .allow)
        XCTAssertEqual(decide(.vm("runner"), "run_status", .read), .allow)
        XCTAssertEqual(decide(.vm("runner"), "list_vms", .read),
                       .deny("This VM may only run its host commands. Its role is set in Monad's settings."))
        XCTAssertEqual(MCPAccess.visible(MonadToolsTests.sampleTools, to: .vm("runner"), vms: vms()).map(\.name), ["host_make"])
    }

    /// Its children freely; itself only to read; anything else asks, and an
    /// "always" for this VM covers it from then on.
    func testAnOrchestratorWorksOnItsChildrenAndAsksForTheRest() {
        for tool in ["start_vm", "stop_vm", "delete_vm", "exec", "read_file", "write_file", "get_vm"] {
            XCTAssertEqual(decide(.vm("boss"), tool, tool == "delete_vm" ? .risky : .normal, name: "kid"), .allow, tool)
            XCTAssertEqual(decide(.vm("boss"), tool, tool == "delete_vm" ? .risky : .normal, name: "other"), .ask, tool)
        }
        XCTAssertEqual(decide(.vm("boss"), "create_vm", .normal), .allow, "its limits are checked when it makes one")
        XCTAssertEqual(decide(.vm("boss"), "list_vms", .read), .allow)
        XCTAssertEqual(decide(.vm("boss"), "get_vm", .read, name: "boss"), .allow)
        XCTAssertEqual(decide(.vm("boss"), "delete_vm", .risky, name: "boss"), .ask, "not itself")
        XCTAssertEqual(decide(.vm("boss"), "exec", .normal, name: "boss"), .ask, "its own shell is its own: through Monad, ask")
        XCTAssertEqual(decide(.vm("boss"), "add_share", .risky, name: "kid"), .ask, "nothing that reaches the Mac")
        XCTAssertEqual(decide(.vm("boss"), "add_distro", .risky), .ask)
        var g = MCPGrants()
        g.add(.vm("boss"), tool: "add_distro")
        XCTAssertEqual(decide(.vm("boss"), "add_distro", .risky, grants: g), .allow)
        XCTAssertEqual(decide(.mac, "add_distro", .risky, grants: g), .ask, "a VM's grant is its own")
        g.forget(vm: "boss")
        XCTAssertEqual(decide(.vm("boss"), "add_distro", .risky, grants: g), .ask, "gone with the VM")
    }

    func testGrantsAreKeptAndReadStrictly() throws {
        let tmp = TempDir()
        let file = tmp.url.appendingPathComponent("agents/grants.json")
        var g = MCPGrants()
        g.add(.mac, tool: "add_bridge")
        g.add(.vm("boss"), tool: nil)
        g.add(.mac, tool: "add_bridge")
        XCTAssertEqual(g.grants.count, 2)
        try g.save(file)
        XCTAssertEqual(MCPGrants.load(file), g)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int, 0o600)
        try Data(#"{"grants":[{"caller":"mac","tool":"add_bridge"},{"caller":"vm:../x"},{"caller":"root"},{"caller":"mac","tool":"x y"}]}"#.utf8)
            .write(to: file)
        XCTAssertEqual(MCPGrants.load(file).grants, [.init(caller: "mac", tool: "add_bridge")], "only well formed grants")
        XCTAssertEqual(MCPGrants.load(tmp.url.appendingPathComponent("none.json")), MCPGrants())
    }

    /// A question waits for its answer; unanswered, it is refused; past the
    /// bound, refused at once.
    func testQuestionsWaitForTheirAnswer() async throws {
        let approvals = Approvals(clock: SystemClock(), timeout: 60)
        var seen: [[ApprovalRequest]] = []
        var asked = 0
        approvals.onChange = { seen.append($0) }
        approvals.onAsk = { asked += 1 }
        async let answer = approvals.ask(caller: .vm("boss"), tool: "add_share", arguments: ["host_path": .string("/Users/x")])
        await assertEventually { approvals.pending.count == 1 }
        let q = approvals.pending[0]
        XCTAssertEqual(q.caller, "vm:boss")
        XCTAssertEqual(q.callerLabel, "The VM “boss”")
        XCTAssertEqual(q.detail, "add_share\nhost_path: \"/Users/x\"")
        XCTAssertEqual(asked, 1, "Monad is brought forward")
        XCTAssertTrue(approvals.answer(q.id, .alwaysTool))
        let got = await answer
        XCTAssertEqual(got, .alwaysTool)
        XCTAssertEqual(approvals.pending, [])
        XCTAssertFalse(approvals.answer(q.id, .once), "answered once")
        XCTAssertEqual(seen.map(\.count), [1, 0])

        let quick = Approvals(clock: SystemClock(), timeout: 0.2)
        let refused = await quick.ask(caller: .mac, tool: "delete_vm", arguments: [:])
        XCTAssertEqual(refused, .deny, "no answer in time is a refusal")
    }

    /// The panel's text cannot be shaped by the caller: no control, format
    /// or separator characters (a newline in a key would make a line of its
    /// own, a right-to-left override turns a path around), each line cut.
    func testTheQuestionsTextCannotBeShaped() {
        let text = Approvals.describe("add_share", [
            "host_path": .string("/Users/dev\u{202E}stcejorP"),
            "read_only": .bool(false),
            "\nhost_path": .string(String(repeating: "x", count: 2500)),
        ])
        XCTAssertFalse(text.unicodeScalars.contains { $0.properties.generalCategory == .format }, text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 4, "one line per argument: \(lines)")
        XCTAssertEqual(lines.first, "add_share")
        XCTAssertTrue(lines.allSatisfy { $0.count <= 301 }, "each line cut")
        XCTAssertTrue(lines.contains("host_path: \"/Users/devstcejorP\""), "\(lines)")
        XCTAssertTrue(lines.contains("read_only: false"), "\(lines)")
        XCTAssertEqual(lines.filter { $0.hasPrefix("host_path:") }.count, 1, "an odd key is shown quoted, not as another")
        // A list cut short says how long it is: what is not shown is not taken for absent.
        let rules = (0..<40).map { JSONValue.string("deny tcp 10.0.0.\($0)/32") }
        let firewall = Approvals.describe("set_firewall", ["rules": .array(rules)])
        XCTAssertTrue(firewall.contains("(40 items, not all shown)"), firewall)
    }

    func testTheAuditLogKeepsEveryCall() throws {
        let tmp = TempDir()
        let audit = MCPAudit(url: tmp.url.appendingPathComponent("agents/audit.log"))
        audit.record(caller: .vm("boss"), tool: "exec", arguments: ["command": .string("uname\r\n-a")],
                     outcome: "ok", duration: .milliseconds(12))
        audit.record(caller: .mac, tool: "delete_vm", arguments: ["name": .string("web")],
                     outcome: "error: The user did not allow delete_vm.", duration: .seconds(3))
        let lines = audit.tail(10)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(" vm:boss exec {\"command\":\"uname\\r\\n-a\"} → ok (12 ms)"), lines[0])
        XCTAssertTrue(lines[1].contains(" mac delete_vm "), lines[1])
        XCTAssertTrue(lines[1].hasSuffix("(3000 ms)"), lines[1])
    }
}
