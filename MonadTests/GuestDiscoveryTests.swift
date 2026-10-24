//
//  GuestDiscoveryTests.swift — what programs in a VM find without being
//  told (agents phase): the profile's exports, ~/.monad/bridges.json, and
//  with a role ~/.monad/mcp.env and Monad registered in Claude Code and
//  Codex. The script runs here under /bin/sh with a home of its own and
//  stand-ins for the agents' CLIs.
//

import XCTest
@testable import Monad

final class GuestDiscoveryTests: XCTestCase {
    private var tmp: TempDir!
    private var home: URL { tmp.url.appendingPathComponent("home") }
    private var bin: URL { tmp.url.appendingPathComponent("bin") }
    private let token = String(repeating: "0f", count: 32)

    override func setUpWithError() throws {
        tmp = TempDir()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    /// A stand-in CLI that logs its arguments.
    private func agent(_ name: String) throws {
        let url = bin.appendingPathComponent(name)
        try "#!/bin/sh\necho \"\(name) $*\" >> '\(tmp.url.path)/calls'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private var calls: [String] {
        ((try? String(contentsOf: tmp.url.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    @discardableResult
    private func run(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-s"]
        p.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    private func config(role: AgentAccess.Role?) -> InstanceConfig {
        var c = InstanceConfig.defaults(name: "work")
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [SharedFolder(hostPath: "/Users/someone/src", guestPath: "/home/dev/src", readOnly: false)])
        c.bridges = [CommandBridge(name: "xcode", command: ["/usr/bin/xcrun", "mcpbridge"], guestPort: 9000)]
        c.hostCommands = [buildCommand(in: "/Users/someone/src/app")]
        c.agents = role.map { AgentAccess(role: $0) }
        return c
    }

    func testTheProfileExportsWhereThingsAre() {
        let p = GuestDiscovery.profileScript
        for line in ["export MONAD_SHOTS=\"$HOME/.monad/shots\"", "export MONAD_EXCHANGE=\"$HOME/.monad/exchange\"",
                     "export MONAD_BRIDGES=\"$HOME/.monad/bridges.json\"",
                     "if [ -r \"$HOME/.monad/mcp.env\" ]; then . \"$HOME/.monad/mcp.env\"; fi"] {
            XCTAssertTrue(p.contains(line), line)
        }
    }

    /// With a role: bridges.json, mcp.env (0600) and both agents told; the
    /// token in the file only. Without one, all of it goes again.
    func testAVMWithARoleFindsMonad() throws {
        try agent("claude")
        try agent("codex")
        let out = try run(GuestDiscovery.script(config(role: .orchestrator), token: token))
        XCTAssertTrue(out.contains("discovery-ok"), out)
        XCTAssertEqual(GuestDiscovery.registered(out), ["claude", "codex"])
        let env = try String(contentsOf: home.appendingPathComponent(".monad/mcp.env"), encoding: .utf8)
        XCTAssertEqual(env, "export MONAD_MCP_URL='http://127.0.0.1:7766/mcp'\nexport MONAD_MCP_TOKEN='\(token)'\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".monad/mcp.env").path))[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(calls, [
            "claude mcp remove --scope user monad",
            "claude mcp add --scope user --transport http monad http://127.0.0.1:7766/mcp --header Authorization: Bearer \(token)",
            "codex mcp remove monad",
            "codex mcp add monad --url http://127.0.0.1:7766/mcp --bearer-token-env-var MONAD_MCP_TOKEN",
        ])
        let bridges = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".monad/bridges.json"))) as? [String: Any])
        XCTAssertEqual(bridges["mcp"] as? String, "http://127.0.0.1:7766/mcp")
        let list = try XCTUnwrap(bridges["bridges"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["name"] as? String }, ["xcode", "app-make"])
        XCTAssertEqual(list.map { $0["kind"] as? String }, ["bridge", "hostCommand"])
        XCTAssertEqual(list[1]["endpoint"] as? String, "/run/monad/app-make.sock")

        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("calls"))
        let off = try run(GuestDiscovery.script(config(role: nil), token: nil))
        XCTAssertEqual(GuestDiscovery.registered(off), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".monad/mcp.env").path))
        XCTAssertEqual(calls, ["claude mcp remove --scope user monad", "codex mcp remove monad"])
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".monad/bridges.json"))) as? [String: Any])
        XCTAssertNil(again["mcp"])
    }

    /// macOS has no /etc/profile.d: the exports go in ~/.monad/profile.sh,
    /// which ~/.zprofile (made when missing) sources by one marked line,
    /// added once; what the file already had stays.
    func testAMacOSVMsShellFindsTheExports() throws {
        var c = config(role: nil)
        c.guestOS = .macos
        let zprofile = home.appendingPathComponent(".zprofile")
        let out = try run(GuestDiscovery.script(c, token: nil))
        XCTAssertTrue(out.contains("discovery-ok"), out)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".monad/profile.sh"), encoding: .utf8),
                       GuestDiscovery.profileScript)
        XCTAssertEqual(try String(contentsOf: zprofile, encoding: .utf8), GuestDiscovery.zprofileLine + "\n")
        try ("export EDITOR=vim\n" + GuestDiscovery.zprofileLine + "\n").write(to: zprofile, atomically: true, encoding: .utf8)
        try run(GuestDiscovery.script(c, token: nil))
        XCTAssertEqual(try String(contentsOf: zprofile, encoding: .utf8), "export EDITOR=vim\n" + GuestDiscovery.zprofileLine + "\n",
                       "once, and the user's lines kept")
        // The exports work in a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", ". \"$HOME/.zprofile\"; echo \"$MONAD_EXCHANGE\""]
        p.environment = ["HOME": home.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       home.path + "/.monad/exchange\n")
        // A Linux VM's script leaves ~/.zprofile alone (/etc/profile.d has it).
        try FileManager.default.removeItem(at: zprofile)
        try run(GuestDiscovery.script(config(role: nil), token: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zprofile.path))
    }

    /// No agent installed: the files are written, nothing is registered.
    func testWithoutAgentsOnlyTheFiles() throws {
        let out = try run(GuestDiscovery.script(config(role: .hostCommands), token: token))
        XCTAssertTrue(out.contains("discovery-ok"), out)
        XCTAssertEqual(GuestDiscovery.registered(out), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".monad/mcp.env").path))
        XCTAssertFalse(GuestDiscovery.script(config(role: .hostCommands), token: "not hex; rm -rf ~").contains("rm -rf"),
                       "only a token Monad made goes in")
    }
}
