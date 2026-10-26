//
//  Fakes.swift — test doubles for the seams VM code talks through.
//

import Foundation
import XCTest
@testable import Monad

/// Records every command and answers from a script.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let stdin: Data?
    }

    typealias Handler = (Call) throws -> ProcessRunner.Result

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var handler: Handler

    init(handler: @escaping Handler = { _ in .ok() }) {
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { _calls } }

    func setHandler(_ h: @escaping Handler) { lock.withLock { handler = h } }

    /// For streamed commands: emits lines as the "process" runs (may block
    /// the calling thread to keep it running). Nil: the plain handler, lines after.
    typealias StreamHandler = (Call, (String) -> Void) throws -> ProcessRunner.Result?
    private var streamHandler: StreamHandler?

    func setStreamHandler(_ h: StreamHandler?) { lock.withLock { streamHandler = h } }

    func stream(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval,
                onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessRunner.Result {
        let call = Call(executable: executable, arguments: arguments, stdin: stdin)
        if let h = lock.withLock({ streamHandler }) {
            lock.withLock { _calls.append(call) }
            if let r = try h(call, onLine) { return r }
            lock.withLock { _ = _calls.removeLast() }
        }
        let r = try await run(executable, arguments, stdin: stdin, timeout: timeout)
        for data in [r.stdout, r.stderr] {
            var s = LineSplitter()
            s.feed(data, onLine)
            s.finish(onLine)
        }
        return r
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> ProcessRunner.Result {
        let call = Call(executable: executable, arguments: arguments, stdin: stdin)
        let h = lock.withLock { () -> Handler in
            _calls.append(call)
            return handler
        }
        return try h(call)
    }

    /// Calls whose last argument (the remote command for ssh) matches.
    func sshCalls(runningRemote command: String) -> [Call] {
        calls.filter { $0.executable == "/usr/bin/ssh" && $0.arguments.last == command }
    }
}

extension ProcessRunner.Result {
    static func ok(_ out: String = "") -> ProcessRunner.Result {
        .init(status: 0, stdout: Data(out.utf8), stderr: Data())
    }

    static func fail(_ status: Int32 = 255, _ err: String = "") -> ProcessRunner.Result {
        .init(status: status, stdout: Data(), stderr: Data(err.utf8))
    }
}

/// A controllable virtual machine.
@MainActor
final class FakeVM: VirtualMachineControlling, MacRecoveryInput, DiskAttaching {
    /// "release" (keys let go), "wake" (a lone shift), "key" (anything else), in order.
    private(set) var inputLog: [String] = []

    func release(keyCodes: [UInt16]) async throws { inputLog.append("release") }
    /// Not seen: recovery waits as long as it would without looking.
    func screen() async -> MacRecovery.Screen? { nil }

    func press(keyCode: UInt16, modifiers: [UInt16]) async throws {
        inputLog.append(keyCode == MacRecovery.Key.shift && modifiers.isEmpty ? "wake" : "key")
        if keyCode == MacRecovery.Key.returnKey { typed += "\n"; return }
        if modifiers.contains(MacRecovery.Key.command) { typed += "⌘" }
        if let ch = MacRecovery.character(forKeyCode: keyCode, shift: modifiers.contains(MacRecovery.Key.shift)) { typed.append(ch) }
    }

    func click(x: Double, y: Double) async throws {}

    var macAddress: String? = "52:54:00:12:34:56"
    var onEvent: ((VMRuntimeEvent) -> Void)?

    var startError: Error?
    var bridgeError: Error?
    var requestStopError: Error?
    /// Answer for each vsock probe, consumed in order; the last one repeats.
    var probeAnswers: [Bool] = [true]
    /// Whether Virtualization would start this machine (not after an error).
    var canStart = true
    /// When true, requestStop() immediately reports the guest powered off.
    var stopsGracefully = true

    private(set) var started = 0
    private(set) var bridge: (path: String, port: UInt32)?
    private(set) var bridgeStopped = 0
    private(set) var stopRequests = 0
    private(set) var forceStops = 0
    private(set) var probes = 0
    /// Channels handed out by openChannel, in order.
    var channels: [ByteChannel] = []
    private(set) var openedPorts: [UInt32] = []
    private(set) var memoryTargets: [UInt64] = []
    /// Folder sets handed to the running share, in order.
    private(set) var shareSets: [[SharedFolder]] = []
    var shareError: Error?

    func start() async throws {
        started += 1
        if let startError { throw startError }
    }

    /// Desktops opened, by window title, and the buttons they were given.
    private(set) var desktops: [String] = []
    private(set) var desktopActions: [DesktopAction] = []
    private(set) var desktopPaste: (@MainActor (String) async -> Void)?
    func showDesktop(title: String, actions: [DesktopAction], paste: @escaping @MainActor (String) async -> Void) throws {
        desktops.append(title)
        desktopActions = actions
        desktopPaste = paste
    }

    /// What was typed into its display (US layout; Return as a newline).
    private(set) var typed = ""

    func requestStop() async throws {
        stopRequests += 1
        if let requestStopError { throw requestStopError }
        if stopsGracefully { onEvent?(.stopped) }
    }

    func setShares(_ shares: [SharedFolder]) async throws {
        if let shareError { throw shareError }
        shareSets.append(shares)
    }

    func setMemoryTarget(bytes: UInt64) {
        memoryTargets.append(bytes)
    }

    /// Disks attached while running, in order, and how many were taken away.
    private(set) var attachedDisks: [URL] = []
    private(set) var detachedDisks = 0
    var attachError: Error?
    /// Runs once a disk is attached (the guest sees a new block device).
    var onAttach: (() -> Void)?

    func attachDisk(_ url: URL) async throws {
        if let attachError { throw attachError }
        attachedDisks.append(url)
        onAttach?()
    }

    func detachDisk() async throws { detachedDisks += 1 }

    func forceStop() async {
        forceStops += 1
        onEvent?(.stopped)
    }

    func startBridge(socketPath: String, port: UInt32) throws {
        if let bridgeError { throw bridgeError }
        bridge = (socketPath, port)
    }

    func stopBridge() { bridgeStopped += 1 }

    /// Called at each vsock probe (a test can write console output then).
    var onProbe: (() -> Void)?

    func probe(port: UInt32, timeout: TimeInterval) async -> Bool {
        probes += 1
        onProbe?()
        let answer = probeAnswers.first ?? true
        if probeAnswers.count > 1 { probeAnswers.removeFirst() }
        return answer
    }

    /// Called on every channel attempt (e.g. to note the time).
    var onOpen: (() -> Void)?

    func openChannel(port: UInt32, timeout: TimeInterval) async throws -> ByteChannel {
        openedPorts.append(port)
        onOpen?()
        guard !channels.isEmpty else { throw TestError("connection refused") }
        return channels.removeFirst()
    }

    /// Simulate the guest crashing / VZ reporting an error.
    func emit(_ event: VMRuntimeEvent) { onEvent?(event) }
}

@MainActor
final class FakeMachineFactory: VirtualMachineFactory {
    var machine = FakeVM()
    var makeError: Error?
    private(set) var made: [(config: InstanceConfig, paths: InstancePaths)] = []
    /// The NIC socket each machine was built with (nil: Apple's NAT or none).
    private(set) var nics: [FileHandle?] = []
    /// macOS recoveryOS boots (System Integrity Protection), with their NICs.
    var recoveryMachine = FakeRecoveryVM()
    private(set) var recoveries: [(config: InstanceConfig, nic: FileHandle?)] = []

    func makeMachine(config: InstanceConfig, paths: InstancePaths, nic: FileHandle?) throws -> VirtualMachineControlling {
        if let makeError { throw makeError }
        made.append((config, paths))
        nics.append(nic)
        return machine
    }

    func makeRecoveryMachine(config: InstanceConfig, paths: InstancePaths,
                             nic: FileHandle?) throws -> VirtualMachineControlling & MacRecoveryInput {
        if let makeError { throw makeError }
        recoveries.append((config, nic))
        return recoveryMachine
    }

    /// Machines built able to take a disk while running (Repair Disk's helper).
    private(set) var diskMachines: [InstanceConfig] = []

    func makeDiskMachine(config: InstanceConfig, paths: InstancePaths,
                         nic: FileHandle?) throws -> VirtualMachineControlling & DiskAttaching {
        if let makeError { throw makeError }
        made.append((config, paths))
        nics.append(nic)
        diskMachines.append(config)
        return machine
    }
}

/// A VM booted into macOS recovery: records what is typed and clicked; it
/// shuts down when `shutdown -h now` is entered (unless told not to).
@MainActor
final class FakeRecoveryVM: VirtualMachineControlling, MacRecoveryInput {
    var macAddress: String? = "52:54:00:12:34:57"
    var onEvent: ((VMRuntimeEvent) -> Void)?
    var canStart = true
    var shutsDown = true
    private(set) var started = 0
    private(set) var forceStops = 0
    private(set) var typed = ""
    private(set) var clicks = 0

    func start() async throws { started += 1 }
    func requestStop() async throws {}
    func forceStop() async {
        forceStops += 1
        onEvent?(.stopped)
    }
    func setShares(_ shares: [SharedFolder]) async throws {}
    func setMemoryTarget(bytes: UInt64) {}
    func startBridge(socketPath: String, port: UInt32) throws {}
    func stopBridge() {}
    func probe(port: UInt32, timeout: TimeInterval) async -> Bool { false }
    func openChannel(port: UInt32, timeout: TimeInterval) async throws -> ByteChannel { throw TestError("no vsock in recovery") }

    /// Holds the steps (the VM stays in recovery) until set false or cancelled.
    var paused = false

    func release(keyCodes: [UInt16]) async throws {}
    func screen() async -> MacRecovery.Screen? { nil }

    func press(keyCode: UInt16, modifiers: [UInt16]) async throws {
        while paused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let ch = MacRecovery.character(forKeyCode: keyCode, shift: modifiers.contains(MacRecovery.Key.shift)) else {
            if keyCode == MacRecovery.Key.returnKey {
                if shutsDown, typed.hasSuffix("shutdown -h now") { onEvent?(.stopped) }
                typed += "\n"
            }
            return
        }
        if modifiers.contains(MacRecovery.Key.command) { return }
        typed.append(ch)
    }

    func click(x: Double, y: Double) async throws { clicks += 1 }

    private(set) var desktops: [String] = []
    func showDesktop(title: String, actions: [DesktopAction], paste: @escaping @MainActor (String) async -> Void) throws {
        desktops.append(title)
    }
}

/// Hands out real (unconnected) datagram sockets and records attachments.
@MainActor
final class FakeNetworkAttacher: NetworkAttaching {
    var error: Error?
    private(set) var attached: [(vm: String, network: String, mac: String, firewall: VMFirewall)] = []
    private(set) var detached = 0
    /// Firewalls set on attached NICs after they were attached.
    private(set) var firewallUpdates: [VMFirewall] = []
    /// Monitor-mode answers given to netd, and how often a VM's were forgotten.
    private(set) var sessionRules: [FirewallRule] = []
    private(set) var forgotten = 0
    /// The last NIC handed out (tests ask questions through it).
    private(set) var lastNIC: NICAttachment?
    /// What netd's connection log says, per VM; which VMs were asked.
    var connectionLog: [String: [NetConnection]] = [:]
    private(set) var connectionsAsked: [String] = []

    func connections(vm: String) async throws -> [NetConnection] {
        connectionsAsked.append(vm)
        return connectionLog[vm] ?? []
    }

    /// What netd's switches counted between VMs.
    var traffic: [VMTraffic] = []

    func traffic() async throws -> [VMTraffic] { traffic }

    func attach(vm: String, network: String, mac: String, firewall: VMFirewall) async throws -> NICAttachment {
        if let error { throw error }
        attached.append((vm, network, mac, firewall))
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0)
        close(fds[1])
        let nic = NICAttachment(handle: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true),
                                onFirewall: { [weak self] in self?.firewallUpdates.append($0) },
                                onAnswer: { [weak self] in self?.sessionRules.append($0) },
                                onForget: { [weak self] in self?.forgotten += 1 },
                                onDetach: { [weak self] in self?.detached += 1 })
        lastNIC = nic
        return nic
    }
}

/// A clock whose sleeps complete instantly and advance virtual time, so
/// timeouts measured in minutes run in microseconds.
final class TestClock: MonadClock, @unchecked Sendable {
    /// Optional real pause per sleep, for tests that must interleave with a polling loop.
    private let realDelay: TimeInterval
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private(set) var totalSlept: TimeInterval = 0

    init(realDelay: TimeInterval = 0) { self.realDelay = realDelay }

    func now() -> Date { lock.withLock { current } }

    func sleep(seconds: TimeInterval) async {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
            totalSlept += seconds
        }
        if realDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(realDelay * 1e9)) }
        await Task.yield()
    }
}

/// A base image provider that hands out a small local raw file.
final class FakeImageProvider: BaseImageProviding, @unchecked Sendable {
    let url: URL
    var error: Error?
    private(set) var requests = 0

    init(url: URL) { self.url = url }

    private(set) var asked: [(distro: String, release: String?)] = []

    func baseImage(distro: String, release: String?, progress: @escaping ImagePipeline.Progress) async throws -> BaseImage {
        requests += 1
        asked.append((distro, release))
        if let error { throw error }
        progress("fake image ready")
        return BaseImage(url: url, name: "Fake Linux 1.0", distro: distro, release: release ?? "1.0", digest: "",
                         verification: .checksumOverHTTPS)
    }
}

/// Apple's macOS installer stand-in: records each install and writes what
/// a real one leaves in the VM's folder (Phase 14).
final class FakeMacInstaller: MacInstalling, @unchecked Sendable {
    struct Install {
        let restoreImage: URL
        let paths: InstancePaths
        let diskBytes: UInt64
    }

    private let lock = NSLock()
    private var _installs: [Install] = []
    var installs: [Install] { lock.withLock { _installs } }
    var progressSteps: [Double] = []
    var error: Error?

    func install(restoreImage: URL, paths: InstancePaths, diskBytes: UInt64,
                 progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { _installs.append(Install(restoreImage: restoreImage, paths: paths, diskBytes: diskBytes)) }
        if let error { throw error }
        for step in progressSteps {
            progress(step)
            await Task.yield()
        }
        for file in [paths.disk, paths.auxStorage, paths.hardwareModel, paths.macMachineID] {
            try Data("installed".utf8).write(to: file)
        }
    }
}

/// The app and its root step, for tests: records what is asked and does
/// what the step does (a work folder with the finished disk), or fails.
@MainActor
final class FakeMacSetup: MacSetupAuthorizing {
    struct Ask: Equatable {
        let vm: String
        let disk: URL
        let payload: URL
    }

    private(set) var asked: [Ask] = []
    private(set) var stagedPassword: String?
    var error: Error?
    let workParent = TempDir()

    func authorize(vm: String, disk: URL, payload: URL) async throws -> String {
        asked.append(Ask(vm: vm, disk: disk, payload: payload))
        stagedPassword = try? String(contentsOf: payload.appendingPathComponent("password"), encoding: .utf8)
        if let error { throw error }
        let work = workParent.url.appendingPathComponent("monad-macsetup.Test0\(asked.count)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("set up".utf8).write(to: work.appendingPathComponent("disk.raw"))
        return work.path
    }

    var workFolderParent: String { workParent.url.path }
}

struct TestError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Temporary directory removed at deinit.
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("monad-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Every regular file under the directory, as relative paths.
    func files() -> [String] {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = url.resolvingSymlinksInPath().path
        return e.compactMap { item -> String? in
            guard let u = item as? URL,
                  (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return String(u.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
        }.sorted()
    }
}

/// Wait (cooperatively) until a condition on the main actor holds.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

/// Assert that a condition on the main actor becomes true within the timeout.
@MainActor
func assertEventually(_ message: @autoclosure () -> String = "", timeout: TimeInterval = 5,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ condition: () -> Bool) async {
    if await eventually(timeout: timeout, condition) { return }
    XCTFail("condition not met within \(timeout)s. \(message())", file: file, line: line)
}

/// A VMManager on fakes: temp root, scripted ssh/ssh-keygen, one FakeVM, a
/// tiny base image. VMs provision in milliseconds and boot to `ready`.
@MainActor
final class ManagerFixture {
    let tmp = TempDir()
    let root: URL
    let runner: FakeCommandRunner
    let factory = FakeMachineFactory()
    let networks = FakeNetworkAttacher()
    let images: FakeImageProvider
    let env: VMEnvironment
    let manager: VMManager

    init(environment edit: (inout VMEnvironment) -> Void = { _ in }) throws {
        root = tmp.url.appendingPathComponent("instances")
        let base = tmp.url.appendingPathComponent("base.raw")
        var mbr = Data(repeating: 0, count: 1 << 20)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try mbr.write(to: base)
        images = FakeImageProvider(url: base)

        // ssh-keygen stand-in: writes the key pair where it was asked to.
        runner = FakeCommandRunner { call in
            if call.executable == "/usr/bin/ssh-keygen", let i = call.arguments.firstIndex(of: "-f") {
                let key = call.arguments[i + 1]
                try Data("PRIVATE".utf8).write(to: URL(fileURLWithPath: key))
                try Data("ssh-ed25519 AAAATEST monad-test\n".utf8).write(to: URL(fileURLWithPath: key + ".pub"))
                return .ok()
            }
            if CloudInit.isIsolationCheck(call.arguments.last) { return .ok("ok\n") }
            return .ok()
        }
        // New VMs join the default Monad network: a fake netd hands out NICs.
        var env = VMEnvironment(runner: runner, machines: factory, clock: TestClock(), virtualizationSupported: true,
                                networks: networks)
        env.bootMessages = { .quiet }
        edit(&env)
        self.env = env
        manager = VMManager(root: root, environment: env, images: images, minimumFreeBytes: 0, macMinimumFreeBytes: 0)
    }

    /// Another manager on the same root, as a restarted host would create.
    func makeManager() -> VMManager {
        VMManager(root: root, environment: env, images: images, minimumFreeBytes: 0, macMinimumFreeBytes: 0)
    }
}

/// Bridge servers for tests: they record starts and stops; those named in
/// `failing` cannot listen. Used from the main actor, as VMInstance is.
final class FakeBridges {
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []
    var failing: Set<String> = []

    private final class Server: BridgeServing {
        let name: String
        unowned let owner: FakeBridges
        init(name: String, owner: FakeBridges) {
            self.name = name
            self.owner = owner
        }
        func start() throws {
            if owner.failing.contains(name) { throw TestError("cannot listen") }
            owner.started.append(name)
        }
        func stop() { owner.stopped.append(name) }
    }

    func make(_ bridge: CommandBridge, _ paths: InstancePaths) -> BridgeServing { Server(name: bridge.name, owner: self) }

    /// Host commands' servers, recorded alike (by command name).
    private final class CommandServer: HostCommandServing {
        let name: String
        unowned let owner: FakeBridges
        init(name: String, owner: FakeBridges) {
            self.name = name
            self.owner = owner
        }
        func start() throws {
            if owner.failing.contains(name) { throw TestError("cannot listen") }
            owner.started.append(name)
        }
        func stop() { owner.stopped.append(name) }
        func submit(_ values: [String], sink: @escaping @Sendable (HostCommandServer.Event) -> Void) throws {
            owner.submitted.append((name, values))
        }
    }

    private(set) var submitted: [(String, [String])] = []
    private(set) var homes: [String] = []

    func make(_ command: HostCommand, _ paths: InstancePaths, _ home: String) -> HostCommandServing {
        homes.append(home)
        return CommandServer(name: command.name, owner: self)
    }
}

/// A process watcher for tests: processes never exit unless told to.
@MainActor
final class ManualProcessWatcher: ProcessExitWatching {
    private var handlers: [Int32: () -> Void] = [:]
    private(set) var watched: [Int32] = []

    func watch(pid: Int32, onExit: @escaping @MainActor () -> Void) -> ProcessWatch {
        watched.append(pid)
        handlers[pid] = onExit
        return ProcessWatch { [weak self] in self?.handlers[pid] = nil }
    }

    func exit(_ pid: Int32) { handlers.removeValue(forKey: pid)?() }
}

/// ssh as seen through the command runner: a control master that can be
/// started and holds forwards. Chains to `other` for everything else.
final class FakeSSHMaster: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private(set) var forwards: [String] = []

    var specs: [String] { lock.withLock { forwards } }

    func handle(_ call: FakeCommandRunner.Call) -> ProcessRunner.Result? {
        lock.withLock {
            if call.executable == "/bin/sh", call.arguments.contains("ControlMaster=yes") {
                running = true
                return .ok()
            }
            guard call.executable == "/usr/bin/ssh", let o = call.arguments.firstIndex(of: "-O") else { return nil }
            switch call.arguments[o + 1] {
            case "check":
                return running ? .init(status: 0, stdout: Data(), stderr: Data("Master running (pid=4242)\r\n".utf8))
                               : .fail(255, "no master")
            case "forward":
                forwards.append(call.arguments[o + 3])
                return .ok()
            case "cancel":
                forwards.removeAll { $0 == call.arguments[o + 3] }
                return .ok()
            case "exit":
                running = false
                forwards = []
                return .ok()
            default:
                return nil
            }
        }
    }
}

/// CPU time this process used so far (all threads): lets tests catch spins.
func processCPUSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
        + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

/// Monad's MCP endpoints, recorded (agents phase).
final class FakeEndpoints {
    private(set) var started: [String] = []
    private(set) var tokens: [String] = []
    private(set) var stopped = 0

    private final class Endpoint: MCPEndpointServing {
        let socket: String
        unowned let owner: FakeEndpoints
        init(socket: String, owner: FakeEndpoints) {
            self.socket = socket
            self.owner = owner
        }
        func start() throws { owner.started.append(socket) }
        func stop() { owner.stopped += 1 }
    }

    func make(_ socket: URL, _ token: String) -> MCPEndpointServing {
        tokens.append(token)
        return Endpoint(socket: socket.path, owner: self)
    }
}

/// `hdiutil attach` of a macOS VM's disk: its volumes mounted under the
/// mount root asked for, the Data volume holding TCC.db.
enum FakeMacDisk {
    static func attach(_ call: FakeCommandRunner.Call) throws -> ProcessRunner.Result {
        let i = try XCTUnwrap(call.arguments.firstIndex(of: "-mountroot"))
        let root = call.arguments[i + 1]
        let tcc = URL(fileURLWithPath: root + "/Macintosh HD/Library/Application Support/com.apple.TCC")
        try FileManager.default.createDirectory(at: tcc, withIntermediateDirectories: true)
        try Data().write(to: tcc.appendingPathComponent("TCC.db"))
        return .ok("""
            /dev/disk6          \tGUID_partition_scheme          \t
            /dev/disk6s2        \tApple_APFS                     \t
            /dev/disk9          \tEF57347C-0000-11AA-AA11-0030654\t
            /dev/disk9s1        \t41504653-0000-11AA-AA11-0030654\t\(root)/Macintosh HD
            /dev/disk9s5        \t41504653-0000-11AA-AA11-0030654\t\(root)/Data

            """)
    }
}
