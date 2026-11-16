//
//  SSHHostManagerTests.swift — MonadHost's side of SSH hosts: what is
//  saved and refused, where a password goes, which of ssh's questions the
//  Keychain may answer (only ssh's own password question, once per
//  connection), how Monad's key gets onto a server, the hosts' side of
//  the VMs' forwards (one ssh master per host that carries any), a host's
//  own forwards, and Monad's agent on a server (put there with the user's
//  yes, run over that master, its ports forwarded by themselves).
//

import XCTest
@testable import Monad

@MainActor
final class SSHHostManagerTests: XCTestCase {
    private var tmp: TempDir!
    private var root: URL!
    private var home: URL!
    private var runner: FakeCommandRunner!
    private var secrets: FakeSecrets!
    private var ssh: FakeSSHMaster!
    private var watcher: ManualProcessWatcher!
    /// Whether a master's start fails.
    private let masterStart = MasterStart()
    /// What the manager runs commands through: `runner`, with a master's
    /// start held on request (as ssh waits for the user's answer).
    private var commands: HoldingRunner!
    /// The agents run on servers: each a stream the test holds the far end of.
    private var channels: FakeChannels!
    /// What the server says it is (`uname -s`), a login shell's noise included.
    private let server = Server()

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var _uname = "Linux\n"
        var uname: String { get { lock.withLock { _uname } } set { lock.withLock { _uname = newValue } } }
    }

    private final class MasterStart: @unchecked Sendable {
        private let lock = NSLock()
        private var _fails = false
        var fails: Bool { get { lock.withLock { _fails } } set { lock.withLock { _fails = newValue } } }
    }

    /// Holds a master's start, without holding a thread, until released;
    /// the ticket of the held start is shown meanwhile.
    private final class HoldingRunner: CommandRunning, @unchecked Sendable {
        private let inner: CommandRunning
        private let lock = NSLock()
        private var _holds = false, _ticket: String?
        private var held: CheckedContinuation<Void, Never>?

        init(_ inner: CommandRunning) { self.inner = inner }

        var holds: Bool { get { lock.withLock { _holds } } set { lock.withLock { _holds = newValue } } }
        var ticket: String? { lock.withLock { _ticket } }

        func release() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { held = nil }
                return held
            }
            waiting?.resume()
        }

        func run(_ executable: String, _ arguments: [String], environment: [String: String], stdin: Data?,
                 timeout: TimeInterval) async throws -> ProcessRunner.Result {
            if executable == "/bin/sh", holds {
                await withCheckedContinuation { waiting in
                    lock.withLock {
                        _ticket = environment[SSHAskpass.ticketVariable]
                        held = waiting
                    }
                }
            }
            return try await inner.run(executable, arguments, environment: environment, stdin: stdin, timeout: timeout)
        }
    }

    override func setUp() async throws {
        tmp = TempDir()
        root = tmp.url.appendingPathComponent("ssh-hosts")
        home = tmp.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        secrets = FakeSecrets()
        ssh = FakeSSHMaster()
        watcher = ManualProcessWatcher()
        channels = FakeChannels()
        // ssh-keygen leaves a key pair, a master its control socket; everything else succeeds.
        runner = FakeCommandRunner { [ssh, masterStart, server] call in
            if call.executable == "/usr/bin/ssh", call.arguments.last == SSHHostAgent.probe { return .ok(server.uname) }
            if call.executable == "/usr/bin/ssh-keygen", let i = call.arguments.firstIndex(of: "-f") {
                let key = call.arguments[i + 1]
                try Data("private\n".utf8).write(to: URL(fileURLWithPath: key))
                try Data("ssh-ed25519 AAAA monad\n".utf8).write(to: URL(fileURLWithPath: key + ".pub"))
            }
            if call.executable == "/bin/sh", let control = call.arguments.first(where: { $0.hasPrefix("ControlPath=") }) {
                if masterStart.fails { return .fail(255) }
                try Data().write(to: URL(fileURLWithPath: String(control.dropFirst("ControlPath=".count))))
            }
            return ssh!.handle(call) ?? .ok()
        }
        commands = HoldingRunner(runner)
    }

    private func manager(clock: MonadClock = SystemClock()) -> SSHHostManager {
        var env = SSHHostManager.Environment()
        env.runner = commands
        env.secrets = secrets
        env.clock = clock
        env.helper = "/Applications/Monad.app/Contents/MacOS/MonadHost"
        env.home = home
        env.agentSocket = "/private/tmp/agent.sock"
        env.watcher = watcher
        env.channels = channels
        env.agentScript = { "# the \($0.rawValue) agent\n" }
        return SSHHostManager(root: root, environment: env)
    }

    private func box(_ auth: SSHHost.Auth = .password, name: String = "box", jump: String? = nil) -> SSHHost {
        SSHHost(name: name, host: "example.com", user: "dev", auth: auth, jump: jump)
    }

    private func message(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Asks as the askpass helper would, and hands back the question once it waits.
    private func asking(_ m: SSHHostManager, ticket: String, _ prompt: String, hint: String? = nil,
                        line: UInt = #line) async -> (Task<String, Error>, SSHPromptRequest?) {
        let before = Set(m.prompts.pending.map(\.id))
        let task = Task { @MainActor in try await m.ask(ticket: ticket, prompt: prompt, hint: hint) }
        let waiting = await eventually(timeout: 2) { m.prompts.pending.contains { !before.contains($0.id) } }
        XCTAssertTrue(waiting, "the user is asked", line: line)
        return (task, m.prompts.pending.first { !before.contains($0.id) })
    }

    // MARK: Hosts

    func testAHostIsSavedSortedAndAnnounced() async throws {
        let m = manager()
        var seen: [[String]] = []
        m.onChange = { seen.append($0.map(\.config.name)) }
        try await m.set(box(), password: nil)
        try await m.set(box(.key, name: "alpha"), password: nil)
        XCTAssertEqual(m.hosts.map(\.name), ["alpha", "box"])
        XCTAssertEqual(seen, [["box"], ["alpha", "box"]])
        XCTAssertEqual(manager().hosts, m.hosts, "read again from its files")
        var edited = box()
        edited.port = 2222
        try await m.set(edited, password: nil)
        XCTAssertEqual(m.hosts.map(\.port), [22, 2222], "the same name is the same host")
    }

    func testNamesThatDifferOnlyInCaseAreOneHost() async throws {
        let m = manager()
        try await m.set(box(), password: nil)
        let refused = await message { try await m.set(self.box(name: "Box"), password: nil) }
        XCTAssertEqual(refused, "An SSH host named box exists already.")
        let invalid = await message { try await m.set(SSHHost(name: "box", host: "a b", user: "dev", auth: .key), password: nil) }
        XCTAssertEqual(invalid, "“a b” is not a host name or address.")
    }

    func testOnlySoManyHosts() async throws {
        let m = manager()
        for i in 0..<SSHHost.maxHosts { try await m.set(box(.key, name: "h\(i)"), password: nil) }
        let refused = await message { try await m.set(self.box(.key, name: "more"), password: nil) }
        XCTAssertEqual(refused, "Monad keeps at most 64 SSH hosts.")
        try await m.set(box(.password, name: "h3"), password: nil)
    }

    func testAJumpHostIsAnotherHostReachedDirectly() async throws {
        let m = manager()
        var refused = await message { try await m.set(self.box(jump: "bastion"), password: nil) }
        XCTAssertEqual(refused, "“bastion” is not an SSH host to connect through.")
        try await m.set(box(.key, name: "bastion"), password: nil)
        try await m.set(box(jump: "bastion"), password: nil)
        refused = await message { try await m.set(self.box(.key, name: "far", jump: "box"), password: nil) }
        XCTAssertEqual(refused, "An SSH host used to connect through cannot connect through another.")
        try await m.set(box(.key, name: "other"), password: nil)
        refused = await message { try await m.set(self.box(.key, name: "bastion", jump: "other"), password: nil) }
        XCTAssertEqual(refused, "An SSH host used to connect through cannot connect through another.")
        refused = await message { try await m.remove("bastion") }
        XCTAssertEqual(refused, "box connects through it.")
        try await m.remove("box")
        try await m.remove("bastion")
        XCTAssertEqual(m.hosts.map(\.name), ["other"])
    }

    // MARK: Passwords

    func testATypedPasswordGoesToTheKeychainNeverToAFile() async throws {
        let m = manager()
        try await m.set(box(), password: "correct horse")
        XCTAssertEqual(secrets["box"], "correct horse")
        XCTAssertEqual(m.snapshots.map(\.hasPassword), [true])
        for file in tmp.files() {
            let text = String(decoding: try Data(contentsOf: tmp.url.appendingPathComponent(file)), as: UTF8.self)
            XCTAssertFalse(text.contains("correct horse"), file)
        }
        try await m.set(box(), password: nil)
        XCTAssertEqual(secrets["box"], "correct horse", "saving again without typing one keeps it")
        try m.forgetPassword("box")
        XCTAssertNil(secrets["box"])
        XCTAssertEqual(m.snapshots.map(\.hasPassword), [false])
    }

    func testAPasswordIsOneLineThatSshTakes() async throws {
        let m = manager()
        for bad in ["two\nlines", "cr\rhere", String(repeating: "p", count: 1024)] {
            let refused = await message { try await m.set(self.box(), password: bad) }
            XCTAssertEqual(refused, "A password is one line of at most 1023 bytes.")
        }
        XCTAssertEqual(m.hosts, [], "nothing saved")
        XCTAssertNil(secrets["box"])
    }

    func testAnotherWayOfSigningInForgetsThePassword() async throws {
        let m = manager()
        try await m.set(box(), password: "pw")
        try await m.set(box(.key), password: "ignored")
        XCTAssertNil(secrets["box"])
        XCTAssertEqual(m.snapshots.map(\.hasPassword), [false])
    }

    /// Without a Keychain that takes it, the host is still there and asks each time.
    func testAKeychainThatRefusesLeavesTheHostSaved() async throws {
        let m = manager()
        secrets.writeError = TestError("The password could not be kept in the Keychain: no access")
        let refused = await message { try await m.set(self.box(), password: "pw") }
        XCTAssertEqual(refused, "The password could not be kept in the Keychain: no access")
        XCTAssertEqual(m.hosts.map(\.name), ["box"])
        XCTAssertEqual(m.snapshots.map(\.hasPassword), [false])
    }

    func testRemovingAHostForgetsEverythingAboutIt() async throws {
        let m = manager()
        try await m.set(box(), password: "pw")
        let ticket = try m.ticket(for: "box")
        try await m.remove("box")
        XCTAssertEqual(m.hosts, [])
        XCTAssertNil(secrets["box"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("box").path))
        let gone = await message { _ = try await m.ask(ticket: ticket, prompt: "dev@example.com's password: ", hint: nil) }
        XCTAssertEqual(gone, "This question did not come from a connection Monad started.")
        let unknown = await message { try await m.remove("box") }
        XCTAssertEqual(unknown, "No SSH host named box.")
        XCTAssertThrowsError(try m.ticket(for: "box"))
        XCTAssertThrowsError(try m.forgetPassword("box"))
    }

    // MARK: Questions

    func testAStoredPasswordAnswersSshsOwnQuestionOncePerConnection() async throws {
        let m = manager()
        try await m.set(box(), password: nil)
        secrets["box"] = "pw"
        let ticket = try m.ticket(for: "box")
        let first = try await m.ask(ticket: ticket, prompt: "dev@example.com's password: ", hint: nil)
        XCTAssertEqual(first, "pw")
        XCTAssertEqual(m.prompts.pending, [], "nobody was asked")

        // Asked again on the same connection: the server refused it.
        let (again, question) = await asking(m, ticket: ticket, "dev@example.com's password: ")
        XCTAssertEqual(m.prompts.pending.count, 1)
        XCTAssertEqual(question?.retry, true)
        XCTAssertEqual(question?.canRemember, true)
        XCTAssertEqual(question?.kind, .secret)
        XCTAssertEqual(question?.host, "box")
        try m.answer(try XCTUnwrap(question).id, "better", remember: true)
        let second = try await again.value
        XCTAssertEqual(second, "better")
        XCTAssertEqual(secrets["box"], "better")

        // Another connection starts over.
        let next = try await m.ask(ticket: try m.ticket(for: "box"), prompt: "dev@example.com's password: ", hint: nil)
        XCTAssertEqual(next, "better")
    }

    /// A server words its own prompts; none of them is answered from the Keychain.
    func testAServersOwnQuestionAlwaysReachesTheUser() async throws {
        let m = manager()
        try await m.set(box(), password: "pw")
        let ticket = try m.ticket(for: "box")
        for prompt in ["Verification code: ", "(dev@example.com) New password: ", "Password: "] {
            let (task, question) = await asking(m, ticket: ticket, prompt)
            XCTAssertEqual(question?.canRemember, false, prompt)
            XCTAssertEqual(question?.retry, false, prompt)
            try m.answer(try XCTUnwrap(question).id, "123456", remember: true)
            let answer = try await task.value
            XCTAssertEqual(answer, "123456")
        }
        XCTAssertEqual(secrets["box"], "pw", "an answer that is not the password is never kept")
        XCTAssertEqual(secrets.reads, 0)
    }

    func testTheHostKeyQuestionIsTheUsersAndThePasswordAfterItIsNotARetry() async throws {
        let m = manager()
        try await m.set(box(), password: nil)
        let ticket = try m.ticket(for: "box")
        let hostKey = "The authenticity of host 'example.com (203.0.113.7)' can't be established.\n"
            + "ED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
        let (trust, question) = await asking(m, ticket: ticket, hostKey)
        XCTAssertEqual(question?.kind, .confirm)
        XCTAssertEqual(question?.canRemember, false)
        XCTAssertEqual(question?.prompt.components(separatedBy: "\n").count, 3)
        try m.answer(try XCTUnwrap(question).id, "yes", remember: true)
        let trusted = try await trust.value
        XCTAssertEqual(trusted, "yes")
        XCTAssertNil(secrets["box"], "a yes is not a password")

        let (sign, password) = await asking(m, ticket: ticket, "dev@example.com's password: ")
        XCTAssertEqual(password?.retry, false)
        XCTAssertEqual(password?.canRemember, true)
        try m.answer(try XCTUnwrap(password).id, "pw", remember: false)
        let typed = try await sign.value
        XCTAssertEqual(typed, "pw")
        XCTAssertNil(secrets["box"], "not kept unless asked to")

        let (refuse, second) = await asking(m, ticket: try m.ticket(for: "box"), hostKey)
        try m.answer(try XCTUnwrap(second).id, "anything else", remember: false)
        let refused = try await refuse.value
        XCTAssertEqual(refused, "no", "only an exact yes trusts a key")
    }

    func testACancelledOrUnansweredQuestionFailsTheHelper() async throws {
        let m = manager()
        try await m.set(box(), password: nil)
        let (task, question) = await asking(m, ticket: try m.ticket(for: "box"), "dev@example.com's password: ")
        try m.answer(try XCTUnwrap(question).id, nil, remember: false)
        let cancelled = await message { _ = try await task.value }
        XCTAssertEqual(cancelled, "The question was not answered.")
        XCTAssertThrowsError(try m.answer(try XCTUnwrap(question).id, "late", remember: false)) {
            XCTAssertEqual($0.localizedDescription, "That question is no longer waiting (it was answered, or two minutes passed).")
        }

        // Nobody answers: it ends after the wait (instant on this clock).
        let quick = manager(clock: TestClock())
        let ticket = try quick.ticket(for: "box")
        let unanswered = await message { _ = try await quick.ask(ticket: ticket, prompt: "Verification code: ", hint: nil) }
        XCTAssertEqual(unanswered, "The question was not answered.")
    }

    func testOnlyAConnectionMonadStartedIsAnswered() async throws {
        let m = manager()
        try await m.set(box(), password: "pw")
        let stranger = await message {
            _ = try await m.ask(ticket: String(repeating: "0", count: 64), prompt: "dev@example.com's password: ", hint: nil)
        }
        XCTAssertEqual(stranger, "This question did not come from a connection Monad started.")
        XCTAssertEqual(m.prompts.pending, [])
        XCTAssertEqual(secrets.reads, 0)
        // ssh only telling something needs no answer.
        let told = try await m.ask(ticket: try m.ticket(for: "box"), prompt: "Confirm user presence", hint: "none")
        XCTAssertEqual(told, "")
    }

    func testAJumpHostsPasswordAnswersItsOwnQuestionOnly() async throws {
        let m = manager()
        try await m.set(SSHHost(name: "bastion", host: "bastion.example.com", user: "ops", auth: .password), password: "jump-pw")
        try await m.set(box(.key, jump: "bastion"), password: nil)
        let ticket = try m.ticket(for: "box")
        let through = try await m.ask(ticket: ticket, prompt: "ops@bastion.example.com's password: ", hint: nil)
        XCTAssertEqual(through, "jump-pw")
        // The host itself signs in with a key: its password question is the user's, and never kept.
        let (task, question) = await asking(m, ticket: ticket, "dev@example.com's password: ")
        XCTAssertEqual(question?.canRemember, false)
        XCTAssertEqual(question?.retry, false)
        try m.answer(try XCTUnwrap(question).id, "typed", remember: true)
        _ = try await task.value
        XCTAssertNil(secrets["box"])
    }

    func testAKeychainThatRefusesStillAnswersSsh() async throws {
        let m = manager()
        try await m.set(box(), password: nil)
        secrets.writeError = TestError("The password could not be kept in the Keychain: no access")
        let (task, question) = await asking(m, ticket: try m.ticket(for: "box"), "dev@example.com's password: ")
        XCTAssertThrowsError(try m.answer(try XCTUnwrap(question).id, "pw", remember: true)) {
            XCTAssertEqual($0.localizedDescription, "The password could not be kept in the Keychain: no access")
        }
        let answer = try await task.value
        XCTAssertEqual(answer, "pw", "the connection goes on")
    }

    // MARK: Monad's key pair

    func testAGeneratedHostGetsAKeyPairOfItsOwn() async throws {
        let m = manager()
        try await m.set(box(.generated), password: nil)
        let keygen = try XCTUnwrap(runner.calls.first { $0.executable == "/usr/bin/ssh-keygen" })
        let key = root.appendingPathComponent("box/id_ed25519").path
        XCTAssertEqual(keygen.arguments, ["-q", "-t", "ed25519", "-N", "", "-C", "monad-ssh-box", "-f", key])
        XCTAssertTrue(FileManager.default.fileExists(atPath: key))
        XCTAssertEqual(m.hosts.map(\.keyInstalled), [false])
        // Another way of signing in: the key pair goes.
        try await m.set(box(.key), password: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: key + ".pub"))
    }

    func testInstallingTheKeyRunsSshCopyIdWithMonadAsItsAskpass() async throws {
        let m = manager()
        var claimed = box(.generated)
        claimed.keyInstalled = true
        try await m.set(claimed, password: nil)
        XCTAssertEqual(m.hosts.map(\.keyInstalled), [false], "whether the server has the key is MonadHost's to say")
        var announced = 0
        m.onChange = { _ in announced += 1 }
        try await m.installKey("box")

        let calls = runner.calls.filter { $0.executable != "/usr/bin/ssh-keygen" }
        XCTAssertEqual(calls.map(\.executable), ["/usr/bin/ssh-copy-id", "/usr/bin/ssh"])
        let folder = root.appendingPathComponent("box").path
        let copy = calls[0]
        XCTAssertEqual(Array(copy.arguments.prefix(4)), ["-i", folder + "/id_ed25519.pub", "-F", "none"])
        XCTAssertEqual(Array(copy.arguments.suffix(3)), ["-o", "ControlPath=none", "example.com"])
        XCTAssertFalse(copy.arguments.contains { $0.hasPrefix("IdentityFile") || $0.hasPrefix("PreferredAuthentications") },
                       "it signs in with what this Mac has")
        XCTAssertEqual(copy.environment["SSH_ASKPASS"], "/Applications/Monad.app/Contents/MacOS/MonadHost")
        XCTAssertEqual(copy.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(copy.environment["SSH_AUTH_SOCK"], "/private/tmp/agent.sock")
        let ticket = try XCTUnwrap(copy.environment["MONAD_ASKPASS_TICKET"])
        XCTAssertTrue(SSHAskpass.isTicket(ticket), ticket)
        XCTAssertNil(copy.stdin)
        let check = calls[1]
        XCTAssertTrue(check.arguments.contains("IdentityFile=\(folder)/id_ed25519"))
        XCTAssertEqual(Array(check.arguments.suffix(6)), ["-o", "ControlPath=none", "-o", "BatchMode=yes", "example.com", "true"])
        XCTAssertEqual(check.environment, [:], "the check asks nothing")

        XCTAssertEqual(m.hosts.map(\.keyInstalled), [true])
        XCTAssertEqual(SSHHostStore(root: root).all().map(\.keyInstalled), [true], "host.json says so")
        XCTAssertEqual(announced, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh").path),
                      "ssh-copy-id keeps its scratch files there")

        // The password it may ask for is asked like any question, and never kept.
        let (task, question) = await asking(m, ticket: ticket, "dev@example.com's password: ")
        XCTAssertEqual(question?.canRemember, false)
        try m.answer(try XCTUnwrap(question).id, "pw", remember: true)
        _ = try await task.value
        XCTAssertNil(secrets["box"])

        // The key stays installed while the server is the same one.
        var edited = box(.generated)
        try await m.set(edited, password: nil)
        XCTAssertEqual(m.hosts.map(\.keyInstalled), [true])
        edited.user = "ops"
        try await m.set(edited, password: nil)
        XCTAssertEqual(m.hosts.map(\.keyInstalled), [false], "another account has no key of Monad's yet")
    }

    func testAFailedInstallSaysWhatTheToolSaid() async throws {
        let m = manager()
        try await m.set(box(.generated), password: nil)
        try await m.set(box(.key, name: "plain"), password: nil)
        var refused = await message { try await m.installKey("plain") }
        XCTAssertEqual(refused, "plain does not use a key pair of Monad's.")
        refused = await message { try await m.installKey("nobody") }
        XCTAssertEqual(refused, "No SSH host named nobody.")

        runner.setHandler { call in
            call.executable == "/usr/bin/ssh-copy-id"
                ? .fail(1, "INFO: attempting to log in\n\u{1B}[31mdev@example.com: Permission denied (publickey,password).\n\n") : .ok()
        }
        refused = await message { try await m.installKey("box") }
        XCTAssertEqual(refused, "[31mdev@example.com: Permission denied (publickey,password).")
        XCTAssertEqual(m.hosts.first { $0.name == "box" }?.keyInstalled, false)

        runner.setHandler { call in
            call.arguments.last == "true" ? .fail(255, "dev@example.com: Permission denied (publickey).\n") : .ok()
        }
        refused = await message { try await m.installKey("box") }
        XCTAssertEqual(refused, "The key was copied, but the server did not accept it: dev@example.com: Permission denied (publickey).")
        XCTAssertEqual(m.hosts.first { $0.name == "box" }?.keyInstalled, false)
    }

    // MARK: Leftovers

    /// MonadHost ends them as it starts; making a manager (the app, a test)
    /// touches no master.
    func testAMasterLeftByAnEarlierMonadHostIsEnded() async throws {
        try await manager().set(box(.key), password: nil)
        let socket = root.appendingPathComponent("box/ctl.sock")
        try Data().write(to: socket)
        let m = manager()
        XCTAssertEqual(runner.calls, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        m.endLeftoverMasters()
        let ended = await eventually { !FileManager.default.fileExists(atPath: socket.path) }
        XCTAssertTrue(ended)
        let exit = try XCTUnwrap(runner.calls.last)
        XCTAssertEqual(exit.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(exit.arguments.suffix(5)), ["-o", "ControlPath=\(socket.path)", "-O", "exit", "example.com"])
        XCTAssertEqual(m.hosts.map(\.name), ["box"])
    }

    // MARK: Forwards

    /// A VM's leg on an SSH host's master (the host's half of an SSHForward).
    private func leg(_ n: Int, on host: String = "box") -> SSHLeg {
        SSHLeg(host: host, spec: SSHMux.Spec(flag: "-L", value: "/vms/web/sshfwd-0000000\(n).sock:127.0.0.1:\(5000 + n)"))
    }

    private var masterStarts: [FakeCommandRunner.Call] { runner.calls.filter { $0.executable == "/bin/sh" } }
    private var masterExits: [FakeCommandRunner.Call] {
        runner.calls.filter { call in call.arguments.firstIndex(of: "-O").map { call.arguments[$0 + 1] == "exit" } ?? false }
    }

    private func pause() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    func testEveryVMsLegsOnAHostShareOneMasterWhichGoesWithTheLast() async throws {
        let m = manager()
        try await m.set(box(.key), password: nil)
        let control = root.appendingPathComponent("box/ctl.sock").path
        m.apply([leg(1)], for: "web")
        m.apply([leg(2), leg(3)], for: "db")
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs.count == 3 }
        XCTAssertEqual(Set(ssh.specs), Set([leg(1), leg(2), leg(3)].map(\.spec.value)))
        XCTAssertEqual(masterStarts.count, 1)
        let start = try XCTUnwrap(masterStarts.first)
        XCTAssertFalse(start.arguments.contains("BatchMode=yes"), "it may ask, in Monad's panel")
        XCTAssertTrue(start.arguments.contains("ControlPath=\(control)"))
        XCTAssertTrue(start.arguments.contains("StrictHostKeyChecking=ask"))
        XCTAssertEqual(start.arguments.last, "example.com")
        XCTAssertEqual(start.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertTrue(SSHAskpass.isTicket(start.environment["MONAD_ASKPASS_TICKET"] ?? ""))
        XCTAssertEqual(watcher.watched, [4242], "the master is supervised like a VM's")
        await assertEventually { m.snapshots.first?.forwards?.count == 3 }
        XCTAssertEqual(m.snapshots.first?.forwards?.map(\.state), [.active, .active, .active])

        // A VM applies its forwards at every change of its ports: the same legs again do nothing.
        let calls = runner.calls.count
        m.apply([leg(1)], for: "web")
        m.apply([leg(2), leg(3)], for: "db")
        await pause()
        XCTAssertEqual(runner.calls.count, calls)

        m.apply([], for: "db")
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == [self.leg(1).spec.value] }
        XCTAssertEqual(masterExits.count, 0, "another VM still uses it")
        var announced = 0
        m.onChange = { _ in announced += 1 }
        m.apply([], for: "web")
        await assertEventually { self.masterExits.count == 1 && !FileManager.default.fileExists(atPath: control) }
        XCTAssertNil(m.snapshots.first?.forwards)
        XCTAssertGreaterThan(announced, 0)
        XCTAssertEqual(masterStarts.count, 1)
    }

    func testAnotherServerOrAccountStartsItsMasterAgain() async throws {
        let m = manager()
        try await m.set(box(.key), password: nil)
        m.apply([leg(1)], for: "web")
        await assertEventually { self.ssh.specs == [self.leg(1).spec.value] }
        var moved = box(.key)
        moved.port = 2222
        try await m.set(moved, password: nil)
        await assertEventually { self.masterStarts.count == 2 && self.ssh.specs == [self.leg(1).spec.value] }
        XCTAssertTrue(masterExits.first?.arguments.contains("Port=22") ?? false, "ended as it was reached")
        XCTAssertTrue(masterStarts[1].arguments.contains("Port=2222"))
        XCTAssertNotEqual(masterStarts[0].environment["MONAD_ASKPASS_TICKET"], masterStarts[1].environment["MONAD_ASKPASS_TICKET"],
                          "a ticket of its own each start")

        // Saved again as it is: nothing to do.
        try await m.set(moved, password: nil)
        await pause()
        XCTAssertEqual(masterStarts.count, 2)

        // The host removed: its master goes; the VM's forward stays, and waits.
        try await m.remove("box")
        XCTAssertEqual(masterExits.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("box").path))
        try await m.set(box(.key), password: nil)
        await assertEventually { self.masterStarts.count == 3 && self.ssh.specs == [self.leg(1).spec.value] }
    }

    func testLegsWaitForAHostThatIsNotThereYet() async throws {
        let m = manager()
        m.apply([leg(1, on: "later")], for: "web")
        await pause()
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(m.snapshots, [])
        try await m.set(box(.key, name: "later"), password: nil)
        await assertEventually { self.ssh.specs == [self.leg(1, on: "later").spec.value] }
    }

    /// A master that cannot start (a question unanswered, a key refused)
    /// leaves its legs failed, says why, and is not started again by itself.
    func testAMasterThatCannotStartIsTriedAgainOnlyWhenAsked() async throws {
        let m = manager()
        try await m.set(box(.key), password: nil)
        masterStart.fails = true
        m.apply([leg(1)], for: "web")
        let failed = ForwardStatus.State.failed("The SSH connection to the SSH host box is not available (no details).")
        await assertEventually { m.snapshots.first?.forwards?.map(\.state) == [failed] }
        XCTAssertEqual(masterStarts.count, 1)
        m.apply([leg(1)], for: "web")
        await pause()
        XCTAssertEqual(masterStarts.count, 1, "the user is not asked again at every change of the VM's ports")

        masterStart.fails = false
        try m.reconnect("box")
        await assertEventually { m.snapshots.first?.forwards?.map(\.state) == [.active] }
        XCTAssertEqual(masterStarts.count, 2)
        XCTAssertThrowsError(try m.reconnect("nobody"))
    }

    /// A master's start may wait for the user (a password). When its legs
    /// go meanwhile, its question goes with them, and the master, should it
    /// still come up, is ended.
    func testAMastersQuestionEndsWithTheNeedForIt() async throws {
        let m = manager()
        try await m.set(box(), password: nil)
        commands.holds = true
        m.apply([leg(1)], for: "web")
        await assertEventually { self.commands.ticket != nil }
        XCTAssertEqual(masterStarts.count, 0, "its start waits (for the user)")
        let ticket = try XCTUnwrap(commands.ticket)
        let (asked, question) = await asking(m, ticket: ticket, "dev@example.com's password: ")
        XCTAssertEqual(question?.host, "box")

        m.apply([], for: "web")
        XCTAssertEqual(m.prompts.pending, [], "nothing left to ask about")
        let unanswered = await message { _ = try await asked.value }
        XCTAssertEqual(unanswered, "The question was not answered.")

        commands.release()
        let control = root.appendingPathComponent("box/ctl.sock").path
        await assertEventually { self.masterExits.count == 1 && !FileManager.default.fileExists(atPath: control) }
        XCTAssertEqual(ssh.specs, [])
        XCTAssertNil(m.snapshots.first?.forwards)
    }

    // MARK: A host's own forwards, and the agent

    private func remote(_ command: String) -> String { "sh -c " + ShellQuote.quote(command) }

    private func withAgent(_ auth: SSHHost.Auth = .key) -> SSHHost {
        var host = box(auth)
        host.agent = true
        return host
    }

    /// With the user's yes, the agent is put on the server and run over the
    /// host's master, which is kept for it; the ports it reports from 1024
    /// up, on addresses the server's own programs reach, come to this Mac's
    /// localhost.
    func testTheAgentsPortsAreForwardedByThemselves() async throws {
        let m = manager()
        var host = withAgent()
        host.autoForward.ignoredPorts = [5432]
        try await m.set(host, password: nil)
        await assertEventually { self.channels.opened.count == 1 }
        XCTAssertEqual(masterStarts.count, 1, "kept for the agent, with nothing to forward yet")

        // What ran on the server: each over the master, none that could ask.
        let control = root.appendingPathComponent("box/ctl.sock").path
        let probe = try XCTUnwrap(runner.sshCalls(runningRemote: "uname -s").first)
        let install = try XCTUnwrap(runner.sshCalls(runningRemote: remote(SSHHostAgent.install)).first)
        XCTAssertEqual(install.stdin, Data("# the Linux agent\n".utf8))
        let run = channels.opened[0]
        XCTAssertEqual(run.executable, "/usr/bin/ssh")
        XCTAssertEqual(run.arguments.last, remote(SSHHostAgent.run(.linux)))
        for arguments in [probe.arguments, install.arguments, run.arguments] {
            XCTAssertEqual(Array(arguments.prefix(2)), ["-F", "none"])
            XCTAssertTrue(arguments.contains("ControlPath=\(control)"))
            XCTAssertTrue(arguments.contains("ControlMaster=no"))
            XCTAssertTrue(arguments.contains("BatchMode=yes"))
            XCTAssertEqual(arguments.dropLast().last, "example.com")
        }
        XCTAssertEqual(m.snapshots.first?.agentRunning, false, "not until it has said hello")

        let agent = channels.channels[0]
        agent.agentSays("hello monad-agent 1\nmode polling\nport+ tcp 0.0.0.0 8080\nport+ tcp 127.0.0.1 5432\n"
            + "port+ tcp 0.0.0.0 22\nport+ tcp 192.0.2.7 9000\n")
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == ["127.0.0.1:8080:127.0.0.1:8080"] }
        XCTAssertEqual(m.snapshots.first?.agentRunning, true)
        await assertEventually {
            m.snapshots.first?.forwards == [ForwardStatus(flag: "-L", spec: "127.0.0.1:8080:127.0.0.1:8080", origin: .auto,
                                                          state: .active)]
        }

        agent.agentSays("port- tcp 0.0.0.0 8080\nport+ tcp :: 3000\n")
        await assertEventually("specs \(ssh.specs)") { self.ssh.specs == ["127.0.0.1:3000:[::1]:3000"] }
        XCTAssertEqual(masterStarts.count, 1)
    }

    /// A VM's port on the server makes the server listen: the agent reports
    /// that port like any other, and it must not come to the Mac by itself
    /// (the VM's own settings say whether its ports do).
    func testAPortAVMPutOnTheServerIsNotForwardedBack() async throws {
        let m = manager()
        try await m.set(withAgent(), password: nil)
        let onto = SSHLeg(host: "box", spec: SSHMux.Spec(flag: "-R", value: "127.0.0.1:18000:/vms/web/sshfwd-00000001.sock"),
                          listensOn: 18000)
        m.apply([onto], for: "web")
        await assertEventually { self.channels.opened.count == 1 }
        channels.channels[0].agentSays("hello monad-agent 1\nport+ tcp 127.0.0.1 18000\nport+ tcp 127.0.0.1 9090\n")
        await assertEventually("specs \(ssh.specs)") {
            Set(self.ssh.specs) == [onto.spec.value, "127.0.0.1:9090:127.0.0.1:9090"]
        }
    }

    /// Turned off: the agent stops, its script is taken from the server
    /// while the connection is still there, and the connection goes when
    /// nothing else needs it.
    func testTurningTheAgentOffTakesItFromTheServer() async throws {
        let m = manager()
        var host = withAgent()
        try await m.set(host, password: nil)
        await assertEventually { self.channels.opened.count == 1 }
        channels.channels[0].agentSays("hello monad-agent 1\nport+ tcp 0.0.0.0 8080\n")
        await assertEventually { self.ssh.specs == ["127.0.0.1:8080:127.0.0.1:8080"] }

        host.agent = false
        try await m.set(host, password: nil)
        await assertEventually { self.masterExits.count == 1 }
        let removed = try XCTUnwrap(runner.calls.firstIndex { $0.arguments.last == self.remote(SSHHostAgent.remove) })
        let exited = try XCTUnwrap(runner.calls.firstIndex { $0 == self.masterExits[0] })
        XCTAssertLessThan(removed, exited, "while Monad is still connected")
        XCTAssertTrue(channels.channels[0].closed)
        XCTAssertNil(m.snapshots.first?.agentRunning)
        XCTAssertNil(m.snapshots.first?.forwards)
        await pause()
        XCTAssertEqual(channels.opened.count, 1, "not run again")
    }

    /// Ports and sockets between this Mac and the server, set by hand, need
    /// no agent: the master carries them, and goes with the last.
    func testAHostsOwnForwardsNeedNoAgent() async throws {
        let m = manager()
        var host = box(.key)
        var off = ForwardRule(kind: .socks, hostPort: 1080)
        off.enabled = false
        host.forwards = [ForwardRule(kind: .local, hostPort: 15432, guestPort: 5432), off]
        try await m.set(host, password: nil)
        await assertEventually { self.ssh.specs == ["127.0.0.1:15432:127.0.0.1:5432"] }
        await assertEventually {
            m.snapshots.first?.forwards == [ForwardStatus(flag: "-L", spec: "127.0.0.1:15432:127.0.0.1:5432",
                                                          origin: .configured, state: .active)]
        }
        XCTAssertEqual(channels.opened.count, 0)
        XCTAssertEqual(runner.sshCalls(runningRemote: "uname -s").count, 0, "nothing runs on the server")
        XCTAssertNil(m.snapshots.first?.agentRunning)

        host.forwards = []
        try await m.set(host, password: nil)
        await assertEventually { self.masterExits.count == 1 }
        XCTAssertEqual(ssh.specs, [])
    }

    /// Monad has an agent for Linux and for macOS. Another system says so,
    /// and is not asked again until the user asks.
    func testAServerTheAgentDoesNotRunOnSaysSo() async throws {
        let m = manager()
        server.uname = "FreeBSD\n"
        try await m.set(withAgent(), password: nil)
        await assertEventually { m.snapshots.first?.agentProblem != nil }
        XCTAssertEqual(m.snapshots.first?.agentProblem,
                       "Monad's agent runs on Linux and macOS servers. This one says it is “FreeBSD”.")
        XCTAssertEqual(m.snapshots.first?.agentRunning, false)
        await pause()
        XCTAssertEqual(runner.sshCalls(runningRemote: "uname -s").count, 1)
        XCTAssertEqual(channels.opened.count, 0)

        // A login shell may print before uname does: its last line counts.
        server.uname = "Welcome to box\n\nDarwin\n"
        try m.reconnect("box")
        await assertEventually { self.channels.opened.count == 1 }
        XCTAssertEqual(channels.opened[0].arguments.last, remote(SSHHostAgent.run(.macos)))
        XCTAssertEqual(runner.sshCalls(runningRemote: remote(SSHHostAgent.install)).first?.stdin, Data("# the Darwin agent\n".utf8))
        XCTAssertNil(m.snapshots.first?.agentProblem)
    }

    /// An agent that ends while Monad is still connected: what it reported
    /// is no longer forwarded, and it is run again.
    func testAnAgentThatEndsIsRunAgainAndItsPortsForgotten() async throws {
        let m = manager()
        try await m.set(withAgent(), password: nil)
        await assertEventually { self.channels.opened.count == 1 }
        channels.channels[0].agentSays("hello monad-agent 1\nport+ tcp 0.0.0.0 8080\n")
        await assertEventually { self.ssh.specs == ["127.0.0.1:8080:127.0.0.1:8080"] }
        channels.channels[0].hangUp()
        await assertEventually("specs \(ssh.specs), agents \(channels.opened.count)") {
            self.ssh.specs == [] && self.channels.opened.count == 2
        }
        XCTAssertEqual(masterStarts.count, 1, "the connection stayed")
        channels.channels[1].agentSays("hello monad-agent 1\nport+ tcp 0.0.0.0 8081\n")
        await assertEventually { self.ssh.specs == ["127.0.0.1:8081:127.0.0.1:8081"] }
    }

    /// MonadHost connects to the hosts that carry something as it starts,
    /// and leaves no master behind as it ends (a forward on a Mac port
    /// would otherwise outlive Monad).
    func testHostsAreConnectedWhileMonadHostRuns() async throws {
        var carrying = withAgent()
        carrying.forwards = [ForwardRule(kind: .local, hostPort: 15432, guestPort: 5432)]
        for host in [carrying, box(.key, name: "quiet")] { try SSHHostStore(root: root).save(host) }
        let m = manager()
        XCTAssertEqual(runner.calls, [], "making a manager connects to nothing")
        m.connectHosts()
        await assertEventually { self.channels.opened.count == 1 && self.ssh.specs == ["127.0.0.1:15432:127.0.0.1:5432"] }
        let control = root.appendingPathComponent("box/ctl.sock").path
        XCTAssertEqual(masterStarts.map { $0.arguments.contains("ControlPath=\(control)") }, [true],
                       "none for a host with nothing to carry")

        await m.stopAll()
        XCTAssertEqual(masterExits.count, 1)
        XCTAssertTrue(channels.channels[0].closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: control))
        XCTAssertNil(m.snapshots.first?.forwards)
    }
}
