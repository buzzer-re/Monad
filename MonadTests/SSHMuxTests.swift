//
//  SSHMuxTests.swift — forwards as ssh sees them: -L/-R/-D specs, and the
//  control-master commands MonadHost runs to add and remove them.
//

import XCTest
@testable import Monad

final class SSHMuxTests: XCTestCase {
    private let paths = InstancePaths(name: "dev", root: URL(fileURLWithPath: "/Users/x/.monad/instances"))

    private var options: [String] { CloudInit.sshArguments(config: InstanceConfig.defaults(name: "dev"), paths: paths) }
    private var mux: SSHMux { SSHMux(paths: paths, host: "monad-dev", options: options) }

    func testForwardSpecs() {
        XCTAssertEqual(SSHMux.spec(ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)),
                       .init(flag: "-L", value: "127.0.0.1:8080:127.0.0.1:80"))
        XCTAssertEqual(SSHMux.spec(ForwardRule(kind: .local, hostAddress: "0.0.0.0", hostPort: 3000, guestHost: "10.0.0.5",
                                               guestPort: 3000)),
                       .init(flag: "-L", value: "0.0.0.0:3000:10.0.0.5:3000"))
        XCTAssertEqual(SSHMux.spec(ForwardRule(kind: .local, hostAddress: "::1", hostPort: 8080, guestHost: "::1",
                                               guestPort: 80)),
                       .init(flag: "-L", value: "[::1]:8080:[::1]:80"), "IPv6 addresses are bracketed")
        // Remote: the guest listens on guestHost:guestPort and reaches the Mac's hostAddress:hostPort.
        XCTAssertEqual(SSHMux.spec(ForwardRule(kind: .remote, hostPort: 5432, guestPort: 15432)),
                       .init(flag: "-R", value: "127.0.0.1:15432:127.0.0.1:5432"))
        XCTAssertEqual(SSHMux.spec(ForwardRule(kind: .socks, hostPort: 1080)),
                       .init(flag: "-D", value: "127.0.0.1:1080"))
        XCTAssertEqual(SSHMux.spec(ForwardRule(kind: .unixLocal, hostSocket: "/Users/x/.monad/docker.sock",
                                               guestSocket: "/run/docker.sock")),
                       .init(flag: "-L", value: "/Users/x/.monad/docker.sock:/run/docker.sock"))
        XCTAssertEqual(SSHMux.spec(ForwardRule(kind: .unixRemote, hostSocket: "/tmp/agent.sock",
                                               guestSocket: "/run/user/1000/agent.sock")),
                       .init(flag: "-R", value: "/run/user/1000/agent.sock:/tmp/agent.sock"))
    }

    func testControlCommands() {
        let base = options
        let rule = ForwardRule(kind: .local, hostPort: 8080, guestPort: 80)
        XCTAssertEqual(mux.check, base + ["-O", "check", "monad-dev"])
        XCTAssertEqual(mux.add(rule), base + ["-O", "forward", "-L", "127.0.0.1:8080:127.0.0.1:80", "monad-dev"])
        XCTAssertEqual(mux.cancel(rule), base + ["-O", "cancel", "-L", "127.0.0.1:8080:127.0.0.1:80", "monad-dev"])
        XCTAssertEqual(mux.exit, base + ["-O", "exit", "monad-dev"])
        XCTAssertFalse(mux.check.contains(paths.sshConfig.path), "never the file on disk")
    }

    func testMasterIsPersistentAndDetachedFromPipes() {
        let (exe, args) = mux.startMaster
        XCTAssertEqual(exe, "/bin/sh")
        // sh execs ssh with stdio on /dev/null, so the forked master holds no pipe of ours open.
        XCTAssertEqual(Array(args.prefix(3)), ["-c", "exec \"$@\" </dev/null >/dev/null 2>&1", "sh"])
        let ssh = Array(args.dropFirst(3))
        XCTAssertEqual(ssh.first, "/usr/bin/ssh")
        for pair in [["-F", "none"], ["-o", "ControlMaster=yes"], ["-o", "ControlPersist=yes"],
                     ["-E", paths.dir.appendingPathComponent("ssh-master.log").path]] {
            XCTAssertTrue(ssh.windows(ofCount: 2).contains { Array($0) == pair }, "missing \(pair)")
        }
        XCTAssertTrue(ssh.contains("-f") && ssh.contains("-N"))
        XCTAssertEqual(ssh.last, "monad-dev")
    }

    func testMasterPIDFromCheck() {
        XCTAssertEqual(SSHMux.masterPID(fromCheckOutput: "Master running (pid=4242)\r\n"), 4242)
        XCTAssertNil(SSHMux.masterPID(fromCheckOutput: "Control socket connect(/x): No such file or directory"))
        XCTAssertNil(SSHMux.masterPID(fromCheckOutput: "Master running (pid=-1)"))
    }

    func testOnlyMonadHostEverStartsTheMaster() {
        // Tabs share the host's master when it exists but never become one:
        // a tab-owned master dies with its tab, and MonadHost's own master
        // then degrades into a stray plain connection.
        let cfg = CloudInit.sshConfig(config: InstanceConfig.defaults(name: "dev"), paths: paths)
        XCTAssertTrue(cfg.contains("ControlMaster no"), cfg)
        XCTAssertFalse(cfg.contains("ControlMaster auto"))
        XCTAssertFalse(cfg.contains("ControlPersist"), "persistence is the host master's own option")
        XCTAssertTrue(cfg.contains("ControlPath"))
    }

    func testMastersGiveUpOnAGuestThatStopsAnswering() {
        // A persistent master must not outlive an unresponsive guest.
        let cfg = CloudInit.sshConfig(config: InstanceConfig.defaults(name: "dev"), paths: paths)
        let interval = cfg.firstMatch(of: /ServerAliveInterval (\d+)/).flatMap { Int($0.1) }
        let count = cfg.firstMatch(of: /ServerAliveCountMax (\d+)/).flatMap { Int($0.1) }
        XCTAssertNotNil(interval)
        XCTAssertNotNil(count)
        XCTAssertLessThanOrEqual((interval ?? 0) * (count ?? 0), 180, "at most 3 minutes")
    }
}

private extension Array {
    func windows(ofCount n: Int) -> [ArraySlice<Element>] {
        guard count >= n else { return [] }
        return (0...(count - n)).map { self[$0..<$0 + n] }
    }
}

final class ForwardValidationTests: XCTestCase {
    private func config(_ rules: [ForwardRule]) -> InstanceConfig {
        var c = InstanceConfig.defaults(name: "unit")
        c.cpus = 2
        c.memoryGiB = 2
        c.forwards = rules
        return c
    }

    private func invalid(_ rules: [ForwardRule], line: UInt = #line) {
        XCTAssertThrowsError(try config(rules).validate(maxCPUs: 8, maxMemoryGiB: 16), line: line)
    }

    func testGuestHostMustBeAnAddressOrPlainHostName() {
        invalid([ForwardRule(kind: .local, hostPort: 8080, guestHost: "evil:1234", guestPort: 80)])
        invalid([ForwardRule(kind: .local, hostPort: 8080, guestHost: "a b", guestPort: 80)])
        invalid([ForwardRule(kind: .local, hostPort: 8080, guestHost: "", guestPort: 80)])
        XCTAssertNoThrow(try config([ForwardRule(kind: .local, hostPort: 8080, guestHost: "db.internal", guestPort: 5432)])
            .validate(maxCPUs: 8, maxMemoryGiB: 16))
        XCTAssertNoThrow(try config([ForwardRule(kind: .local, hostPort: 8080, guestHost: "fd00::2", guestPort: 80)])
            .validate(maxCPUs: 8, maxMemoryGiB: 16))
    }

    func testSocketPathsCannotReshapeTheSpec() {
        invalid([ForwardRule(kind: .unixLocal, hostSocket: "/tmp/a:b.sock", guestSocket: "/run/x.sock")])
        invalid([ForwardRule(kind: .unixLocal, hostSocket: "/tmp/a.sock", guestSocket: "/run/x y.sock")])
    }
}
