//
//  SSHHostTests.swift — an SSH host's settings, its files and the options
//  of the ssh Monad runs to it: no config file is read, the host key is
//  asked about, and each way of signing in offers only what it says.
//

import XCTest
@testable import Monad

final class SSHHostTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/dev/.monad/ssh-hosts")
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func host(_ auth: SSHHost.Auth = .password, keyPath: String? = nil, jump: String? = nil) -> SSHHost {
        SSHHost(name: "box", host: "example.com", user: "dev", auth: auth, keyPath: keyPath, jump: jump)
    }

    private func arguments(_ host: SSHHost, jump: SSHHost? = nil, purpose: SSHHostPurpose = .session) -> [String] {
        SSHHost.sshArguments(host, root: root, home: home, jump: jump, purpose: purpose)
    }

    /// The `-o` values, in order.
    private func options(_ argv: [String]) -> [String] {
        XCTAssertEqual(Array(argv.prefix(2)), ["-F", "none"], "no config file is ever read")
        let rest = Array(argv.dropFirst(2))
        XCTAssertEqual(rest.count % 2, 0)
        return stride(from: 0, to: rest.count, by: 2).map { i -> String in
            XCTAssertEqual(rest[i], "-o")
            return rest[i + 1]
        }
    }

    private let common = [
        "User=dev",
        "Port=22",
        "StrictHostKeyChecking=ask",
        "UserKnownHostsFile=/Users/dev/.monad/ssh-hosts/known_hosts /Users/dev/.ssh/known_hosts",
        "ForwardAgent=no",
        "ForwardX11=no",
        "ServerAliveInterval=30",
        "ServerAliveCountMax=4",
        "ConnectTimeout=15",
        "StreamLocalBindUnlink=yes",
        "SetEnv=COLORTERM=truecolor TERM_PROGRAM=Monad",
        "EscapeChar=none",
        "LogLevel=ERROR",
    ]

    // MARK: ssh options

    func testAPasswordHostOffersNoKey() {
        let argv = arguments(host(.password))
        XCTAssertEqual(Array(argv.prefix(8)), ["-F", "none", "-o", "User=dev", "-o", "Port=22", "-o", "StrictHostKeyChecking=ask"])
        XCTAssertEqual(options(argv), common + [
            "PubkeyAuthentication=no", "IdentityAgent=none", "PreferredAuthentications=password,keyboard-interactive",
        ])
        XCTAssertFalse(argv.contains { $0.hasPrefix("IdentityFile") })
        XCTAssertFalse(argv.contains { $0.hasPrefix("ControlPath") || $0.hasPrefix("ControlMaster") || $0.hasPrefix("BatchMode") },
                       "left to each caller")
    }

    func testAKeyFileIsTheOnlyKeyOffered() {
        XCTAssertEqual(options(arguments(host(.key, keyPath: "/Users/dev/.ssh/id_work"))), common + [
            "IdentityFile=/Users/dev/.ssh/id_work", "IdentitiesOnly=yes",
            "PreferredAuthentications=publickey,keyboard-interactive",
        ])
    }

    func testWithoutAKeyFileSshUsesItsOwnKeysAndAgent() {
        XCTAssertEqual(options(arguments(host(.key))), common + ["PreferredAuthentications=publickey,keyboard-interactive"])
    }

    func testMonadsKeyPairIsTheOnlyKeyOffered() {
        XCTAssertEqual(options(arguments(host(.generated))), common + [
            "IdentityFile=/Users/dev/.monad/ssh-hosts/box/id_ed25519", "IdentitiesOnly=yes", "IdentityAgent=none",
            "PreferredAuthentications=publickey,keyboard-interactive",
        ])
    }

    /// ssh-copy-id gets in with whatever this Mac has: nothing is narrowed.
    func testInstallingAKeyLeavesEveryWayInOpen() {
        for auth in SSHHost.Auth.allCases {
            XCTAssertEqual(options(arguments(host(auth), purpose: .install)), common, "\(auth)")
        }
    }

    func testThePortIsTheHosts() {
        var h = host()
        h.port = 2222
        XCTAssertEqual(options(arguments(h))[1], "Port=2222")
    }

    /// ssh splits an option's value into words and expands % in file names.
    func testPathsWithSpacesAndPercentSignsReachSshWhole() {
        let argv = SSHHost.sshArguments(host(.key, keyPath: "/Users/dev/My Keys/50%.key"),
                                        root: URL(fileURLWithPath: "/Users/dev/Library/App Data/ssh-hosts"), home: home)
        XCTAssertTrue(argv.contains("IdentityFile=\"/Users/dev/My Keys/50%%.key\""), "\(argv)")
        XCTAssertTrue(argv.contains("UserKnownHostsFile=\"/Users/dev/Library/App Data/ssh-hosts/known_hosts\" "
                                    + "/Users/dev/.ssh/known_hosts"), "\(argv)")
    }

    func testAJumpHostIsAnSshOfMonadsAsTheProxyCommand() throws {
        var bastion = SSHHost(name: "bastion", host: "bastion.example.com", user: "ops", auth: .key)
        bastion.port = 2200
        let argv = arguments(host(.password, jump: "bastion"), jump: bastion)
        let proxy = try XCTUnwrap(options(argv).last)
        XCTAssertEqual(options(argv).dropLast(), (common + [
            "PubkeyAuthentication=no", "IdentityAgent=none", "PreferredAuthentications=password,keyboard-interactive",
        ])[...])
        XCTAssertEqual(proxy, "ProxyCommand=/usr/bin/ssh -F none -o User=ops -o Port=2200 -o StrictHostKeyChecking=ask "
                       + "-o 'UserKnownHostsFile=/Users/dev/.monad/ssh-hosts/known_hosts /Users/dev/.ssh/known_hosts' "
                       + "-o ForwardAgent=no -o ForwardX11=no -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "
                       + "-o ConnectTimeout=15 -o StreamLocalBindUnlink=yes "
                       + "-o 'SetEnv=COLORTERM=truecolor TERM_PROGRAM=Monad' -o EscapeChar=none -o LogLevel=ERROR "
                       + "-o PreferredAuthentications=publickey,keyboard-interactive -o ControlPath=none "
                       + "-W '[%h]:%p' bastion.example.com")
    }

    // MARK: Validation

    func testValidation() {
        XCTAssertNoThrow(try host().validate())
        XCTAssertNoThrow(try host(.key, keyPath: "/Users/dev/.ssh/id_work", jump: "bastion").validate())
        var v6 = host()
        v6.host = "2001:db8::1"
        XCTAssertNoThrow(try v6.validate())

        func rejected(_ expected: SSHHost.ValidationError, _ change: (inout SSHHost) -> Void, line: UInt = #line) {
            var h = host()
            change(&h)
            XCTAssertThrowsError(try h.validate(), line: line) { XCTAssertEqual($0 as? SSHHost.ValidationError, expected, line: line) }
        }
        rejected(.name("a b")) { $0.name = "a b" }
        rejected(.name("box\n")) { $0.name = "box\n" }
        rejected(.name("")) { $0.name = "" }
        rejected(.host("example.com evil")) { $0.host = "example.com evil" }
        rejected(.host("-oProxyCommand=x")) { $0.host = "-oProxyCommand=x" }
        rejected(.host("example.com\n")) { $0.host = "example.com\n" }
        rejected(.host("")) { $0.host = "" }
        rejected(.port(0)) { $0.port = 0 }
        rejected(.port(65536)) { $0.port = 65536 }
        rejected(.user("-x")) { $0.user = "-x" }
        rejected(.user("a b")) { $0.user = "a b" }
        rejected(.user(String(repeating: "u", count: 65))) { $0.user = String(repeating: "u", count: 65) }
        rejected(.keyWithoutKeySignIn) { $0.keyPath = "/Users/dev/.ssh/id_work" }
        rejected(.keyPath) { $0.auth = .key; $0.keyPath = ".ssh/id_work" }
        rejected(.keyPath) { $0.auth = .key; $0.keyPath = "/Users/dev/a\u{1B}b" }
        rejected(.keyPath) { $0.auth = .key; $0.keyPath = "/" + String(repeating: "k", count: 1024) }
        rejected(.jump("no good")) { $0.jump = "no good" }
        rejected(.selfJump) { $0.jump = "box" }
        XCTAssertEqual(SSHHost.ValidationError.host("x y").errorDescription, "“x y” is not a host name or address.")
        XCTAssertEqual(SSHHost.ValidationError.selfJump.errorDescription, "An SSH host cannot jump through itself.")
    }

    // MARK: Files

    func testAHostRoundTrips() throws {
        var h = host(.generated, jump: "bastion")
        h.port = 2222
        h.keyInstalled = true
        let data = try JSONEncoder().encode(h)
        XCTAssertEqual(try JSONDecoder().decode(SSHHost.self, from: data), h)
    }

    func testAFileWithoutTheOptionalKeysLoads() throws {
        let json = #"{"name": "box", "host": "example.com", "user": "dev", "auth": "key"}"#
        let h = try JSONDecoder().decode(SSHHost.self, from: Data(json.utf8))
        XCTAssertEqual(h, SSHHost(name: "box", host: "example.com", user: "dev", auth: .key))
        XCTAssertEqual(h.port, 22)
        XCTAssertFalse(h.keyInstalled)
    }

    // MARK: Its own forwards and the agent

    /// Forwards between this Mac and the server, and the agent that makes
    /// some by themselves: in the file only when there are any, so a host
    /// without them is written as it always was.
    func testItsForwardsAndAgentAreKeptOnlyWhenThereAreAny() throws {
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host())) as? [String: Any])
        XCTAssertEqual(Set(plain.keys), ["version", "name", "host", "port", "user", "auth", "keyInstalled"])
        var h = host(.key)
        h.agent = true
        h.autoForward.ignoredPorts = [5432]
        h.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)]
        XCTAssertEqual(try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(h)), h)
        let old = try JSONDecoder().decode(SSHHost.self,
                                           from: Data(#"{"name": "box", "host": "example.com", "user": "dev", "auth": "key"}"#.utf8))
        XCTAssertFalse(old.agent)
        XCTAssertEqual(old.forwards, [])
        XCTAssertEqual(old.autoForward, AutoForwardSettings())
    }

    /// Ports are forwarded by themselves only with the agent, and Monad
    /// stays connected only to a host that has something to carry.
    func testWhatAHostIsConnectedFor() {
        var h = host(.key)
        XCTAssertFalse(h.effectiveAutoForward.enabled, "no agent: nothing says which ports there are")
        XCTAssertFalse(h.keepsConnection)
        h.agent = true
        h.autoForward.ignoredPorts = [5432]
        XCTAssertEqual(h.effectiveAutoForward, AutoForwardSettings(enabled: true, minimumPort: 1024, ignoredPorts: [5432]))
        XCTAssertTrue(h.keepsConnection)
        h.agent = false
        var rule = ForwardRule(kind: .socks, hostPort: 1080)
        h.forwards = [rule]
        XCTAssertTrue(h.keepsConnection)
        rule.enabled = false
        h.forwards = [rule]
        XCTAssertFalse(h.keepsConnection, "a forward that is off needs no connection")
    }

    func testItsForwardsAreCheckedLikeAVMs() {
        func problem(_ change: (inout SSHHost) -> Void) -> String? {
            var h = host(.key)
            change(&h)
            do {
                try h.validate()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        XCTAssertNil(problem {
            $0.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80),
                           ForwardRule(kind: .remote, hostPort: 5432, guestPort: 15432)]
        })
        XCTAssertEqual(problem { $0.forwards = [ForwardRule(kind: .local, hostPort: 80, guestPort: 80)] },
                       "Port 80 is privileged on the Mac. Use 1024 or above.")
        XCTAssertEqual(problem { $0.forwards = [ForwardRule(kind: .local, hostPort: 8080)] },
                       "A forward is missing its ports or socket paths.")
        XCTAssertEqual(problem {
            $0.forwards = [ForwardRule(kind: .local, hostPort: 8080, guestPort: 80), ForwardRule(kind: .socks, hostPort: 8080)]
        }, "Two forwards listen on 127.0.0.1:8080.")
        XCTAssertEqual(problem {
            $0.forwards = (0...SSHHost.maxForwards).map { ForwardRule(kind: .local, hostPort: 2000 + $0, guestPort: 80) }
        }, "An SSH host can have at most 32 forwards.")
        XCTAssertEqual(problem { $0.autoForward.minimumPort = 80 }, "Auto-forwarding cannot start below port 1024 (got 80).")
        XCTAssertEqual(problem { $0.autoForward.ignoredPorts = [0] }, "0 is not a valid port (1–65535).")
        XCTAssertEqual(problem { $0.autoForward.ignoredPorts = Array(1024...2048) }, "At most 256 ports to skip.")
    }

    func testAHostFromANewerMonadIsNotLoaded() {
        let json = #"{"version": 2, "name": "box", "host": "example.com", "user": "dev", "auth": "key"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SSHHost.self, from: Data(json.utf8))) {
            XCTAssertEqual($0 as? SSHHost.DecodingProblem, .unsupportedVersion(2))
        }
    }

    func testTheStoreKeepsEachHostInAFolderOfItsOwnReadableOnlyByTheUser() throws {
        let tmp = TempDir()
        let store = SSHHostStore(root: tmp.url.appendingPathComponent("ssh-hosts"))
        XCTAssertEqual(store.all(), [], "no folder yet")
        try store.save(host())
        var other = host(.key)
        other.name = "alpha"
        try store.save(other)
        XCTAssertEqual(store.all().map(\.name), ["alpha", "box"])
        let file = store.paths("box").sshHost
        XCTAssertEqual(file.lastPathComponent, "host.json")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        let folder = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.paths("box").dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(folder & 0o777, 0o700)
        try store.delete("alpha")
        XCTAssertEqual(store.all().map(\.name), ["box"])
        var bad = host()
        bad.port = 0
        XCTAssertThrowsError(try store.save(bad))
    }

    func testTheStoreSkipsWhatItCannotTrust() throws {
        let tmp = TempDir()
        let root = tmp.url.appendingPathComponent("ssh-hosts")
        let store = SSHHostStore(root: root)
        try store.save(host())
        // Another host's file in this folder, an invalid one, an oversized one, and the known hosts file.
        func write(_ folder: String, _ text: String) throws {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("host.json"))
        }
        try write("other", #"{"name": "box", "host": "example.com", "user": "dev", "auth": "key"}"#)
        try write("badport", #"{"name": "badport", "host": "example.com", "port": 0, "user": "dev", "auth": "key"}"#)
        try write("junk", "not json")
        try write("huge", #"{"name": "huge", "host": "example.com", "user": "dev", "auth": "key", "pad": ""#
                  + String(repeating: "x", count: SSHHostStore.maxFileBytes) + "\"}")
        try Data("example.com ssh-ed25519 AAAA\n".utf8).write(to: SSHHost.knownHosts(root: root))
        XCTAssertEqual(store.all(), [host()])
    }
}
