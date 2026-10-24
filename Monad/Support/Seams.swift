//
//  Seams.swift — the boundaries VM code talks through. Production uses the
//  live implementations; tests substitute fakes (MonadTests/Support/Fakes.swift).
//

import Foundation
import os

// MARK: Helper processes

protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> ProcessRunner.Result
    /// Like run, and each line of output (stdout and stderr) goes to
    /// `onLine` as it comes.
    func stream(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval,
                onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessRunner.Result
}

extension CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> ProcessRunner.Result {
        try await run(executable, arguments, stdin: nil, timeout: timeout)
    }

    /// Runs to the end, then hands over the output's lines (fakes need no more).
    func stream(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval,
                onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessRunner.Result {
        let r = try await run(executable, arguments, stdin: stdin, timeout: timeout)
        for data in [r.stdout, r.stderr] {
            var s = LineSplitter()
            s.feed(data, onLine)
            s.finish(onLine)
        }
        return r
    }
}

struct SystemCommandRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> ProcessRunner.Result {
        try await ProcessRunner.run(executable, arguments, stdin: stdin, timeout: timeout)
    }

    func stream(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval,
                onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessRunner.Result {
        let splitters = OSAllocatedUnfairLock(initialState: [LineSplitter(), LineSplitter()])
        let r = try await ProcessRunner.run(executable, arguments, stdin: stdin, timeout: timeout) { i, data in
            let lines = splitters.withLock { all -> [String] in
                var out: [String] = []
                all[i].feed(data) { out.append($0) }
                return out
            }
            lines.forEach(onLine)
        }
        let rest = splitters.withLock { all -> [String] in
            var out: [String] = []
            for i in all.indices { all[i].finish { out.append($0) } }
            return out
        }
        rest.forEach(onLine)
        return r
    }
}

/// Bytes into lines ("\n", a trailing "\r" dropped), each at most `maxLine`
/// characters (the rest of a longer line is dropped): a guest cannot grow
/// one line without bound.
struct LineSplitter: Sendable {
    let maxLine: Int
    private var pending: [UInt8] = []
    private var cut = false

    init(maxLine: Int = 4096) { self.maxLine = maxLine }

    mutating func feed(_ data: Data, _ emit: (String) -> Void) {
        for byte in data {
            if byte == 0x0A {
                emitPending(emit)
            } else if pending.count < maxLine {
                pending.append(byte)
            } else {
                cut = true
            }
        }
    }

    /// The last line, if it did not end with a newline.
    mutating func finish(_ emit: (String) -> Void) {
        if !pending.isEmpty || cut { emitPending(emit) }
    }

    private mutating func emitPending(_ emit: (String) -> Void) {
        if pending.last == 0x0D { pending.removeLast() }
        emit(String(decoding: pending, as: UTF8.self))
        pending.removeAll(keepingCapacity: true)
        cut = false
    }
}

// MARK: Time

protocol MonadClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async
}

struct SystemClock: MonadClock {
    func now() -> Date { Date() }

    func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
    }
}

// MARK: Virtual machines

/// Runtime events a machine reports after it has started.
enum VMRuntimeEvent: Equatable {
    case stopped
    case failed(String)
}

@MainActor
protocol VirtualMachineControlling: AnyObject {
    /// MAC address of the NIC (generated on first build when not configured).
    var macAddress: String? { get }
    var onEvent: ((VMRuntimeEvent) -> Void)? { get set }

    func start() async throws
    /// ACPI power button.
    func requestStop() async throws
    /// Immediate power off.
    func forceStop() async
    /// Replace the folders of the running VM's virtio-fs share.
    func setShares(_ shares: [SharedFolder]) async throws
    /// Memory the guest may use, through the balloon (≤ the boot memory).
    func setMemoryTarget(bytes: UInt64)
    /// Serve guest vsock `port` on a private unix socket.
    func startBridge(socketPath: String, port: UInt32) throws
    func stopBridge()
    /// Whether the guest accepts connections on a vsock port.
    func probe(port: UInt32, timeout: TimeInterval) async -> Bool
    /// Whether Virtualization would start this machine: not once it ended
    /// in an error (a new one is built then).
    var canStart: Bool { get }
    /// Connect to a guest vsock port (host-initiated).
    func openChannel(port: UInt32, timeout: TimeInterval) async throws -> ByteChannel
    /// A window on the guest's display (a macOS VM's desktop), with
    /// buttons for what Monad can do there; ⌘V in it hands the Mac's text
    /// to `paste`.
    func showDesktop(title: String, actions: [DesktopAction], paste: @escaping @MainActor (String) async -> Void) throws
}

extension VirtualMachineControlling {
    func showDesktop(title: String, actions: [DesktopAction], paste: @escaping @MainActor (String) async -> Void) throws {
        throw MonadError("This VM has no display to show.")
    }
}

/// A button on a VM's desktop window.
struct DesktopAction {
    let title: String
    let run: @MainActor () async -> Void
}

@MainActor
protocol VirtualMachineFactory: AnyObject {
    /// `nic`: the VM's socket to monad-netd when its network is a Monad network.
    func makeMachine(config: InstanceConfig, paths: InstancePaths, nic: FileHandle?) throws -> VirtualMachineControlling
    /// A macOS VM that boots into its recoveryOS, with a display, a keyboard
    /// and a pointer Monad drives (System Integrity Protection).
    func makeRecoveryMachine(config: InstanceConfig, paths: InstancePaths,
                             nic: FileHandle?) throws -> VirtualMachineControlling & MacRecoveryInput
}

extension VirtualMachineFactory {
    func makeRecoveryMachine(config: InstanceConfig, paths: InstancePaths,
                             nic: FileHandle?) throws -> VirtualMachineControlling & MacRecoveryInput {
        throw MonadError("This Monad cannot start a VM in macOS recovery.")
    }
}

// MARK: Images

protocol BaseImageProviding: Sendable {
    /// Raw base disk for `distro` (`release` nil: its default release).
    func baseImage(distro: String, release: String?, progress: @escaping ImagePipeline.Progress) async throws -> BaseImage
}

extension ImagePipeline: BaseImageProviding {}

// MARK: Monad networks

/// A VM's NIC on a Monad network: the VM's end of its socket to monad-netd.
/// `detach` (once) takes the port out of netd.
@MainActor
final class NICAttachment {
    let handle: FileHandle
    /// Monitor mode: netd asks about a destination nothing decides (set by
    /// the VM that uses the NIC).
    var onAsk: ((FirewallAsk) -> Void)?
    /// What netd made of the VM's firewall each time it was sent: nil when
    /// in force as saved, else why not (a refusal, a missing tag). The last
    /// report is given at once to whoever starts listening.
    var onFirewallProblem: ((String?) -> Void)? {
        didSet { if let reported { onFirewallProblem?(reported) } }
    }
    private var reported: String??
    private var onFirewall: ((VMFirewall) -> Void)?
    private var onAnswer: ((FirewallRule) -> Void)?
    private var onForget: (() -> Void)?
    private var onDetach: (() -> Void)?

    init(handle: FileHandle, onFirewall: @escaping (VMFirewall) -> Void = { _ in },
         onAnswer: @escaping (FirewallRule) -> Void = { _ in }, onForget: @escaping () -> Void = {},
         onDetach: @escaping () -> Void) {
        self.handle = handle
        self.onFirewall = onFirewall
        self.onAnswer = onAnswer
        self.onForget = onForget
        self.onDetach = onDetach
    }

    /// The VM's firewall changed: it applies at once, to what is open too.
    func setFirewall(_ firewall: VMFirewall) {
        onFirewall?(firewall)
    }

    /// From netd: a question for the VM.
    func ask(_ question: FirewallAsk) {
        onAsk?(question)
    }

    /// From the supervisor: the firewall sent last is in force (nil), or why not.
    func firewallApplied(problem: String?) {
        reported = .some(problem)
        onFirewallProblem?(problem)
    }

    /// An answer, in force until the VM stops.
    func answer(_ rule: FirewallRule) {
        onAnswer?(rule)
    }

    /// The VM stopped: its answers and questions go.
    func forgetSession() {
        onForget?()
    }

    func detach() {
        let f = onDetach
        onDetach = nil
        onFirewall = nil
        onAnswer = nil
        onForget = nil
        onAsk = nil
        f?()
    }
}

@MainActor
protocol NetworkAttaching: AnyObject {
    /// Attach a NIC with `mac` to the Monad network `network`, behind the
    /// VM's firewall.
    func attach(vm: String, network: String, mac: String, firewall: VMFirewall) async throws -> NICAttachment
    /// The VM's connection log, most recent first (empty: no port here).
    func connections(vm: String) async throws -> [NetConnection]
    /// Traffic between VMs on every Monad network, by VM name.
    func traffic() async throws -> [VMTraffic]
}

// MARK: Environment

/// Everything a VM needs from the outside world.
/// Apple's macOS installer (Phase 14): from a restore image, the VM's disk
/// (`diskBytes`, sparse), auxiliary storage, hardware model and machine
/// identifier in `paths`, then macOS installed onto the disk.
protocol MacInstalling: Sendable {
    func install(restoreImage: URL, paths: InstancePaths, diskBytes: UInt64,
                 progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The one admin prompt that finishes a macOS VM's setup (Phase 14): the
/// app runs Monad's root step on `disk` with the files staged in `payload`
/// and answers with the work folder holding the finished disk.
@MainActor
protocol MacSetupAuthorizing: AnyObject {
    func authorize(vm: String, disk: URL, payload: URL) async throws -> String
    /// Where the root step's work folders are made (/private/tmp).
    var workFolderParent: String { get }
}

struct VMEnvironment {
    let runner: CommandRunning
    let machines: VirtualMachineFactory
    let clock: MonadClock
    let virtualizationSupported: Bool
    /// Supervises ssh masters; nil means kqueue.
    var watcher: ProcessExitWatching? = nil
    /// Monad networks (monad-netd); nil: only Apple's NAT is available.
    var networks: NetworkAttaching? = nil
    /// The profiles there are (read when a run starts: custom ones may change).
    var profiles: () -> ProfileCatalog = {
        (try? ProfileCatalog.bundled(custom: ProfileStore())) ?? ProfileCatalog(builtIn: [], custom: [])
    }
    /// Settings › Logs.
    var debugLog: DebugLog = .shared
    /// macOS guests: Apple's installer, and whether macOS VMs may be made
    /// here (`GuestOS.ready`; tests set it).
    var macInstaller: MacInstalling = VZMacInstaller()
    var allowsMacGuests = false
    /// Asks the app for the setup's admin prompt (HostService); nil: no app.
    var macSetup: MacSetupAuthorizing?
    /// monad-guestd, copied into macOS guests: this MonadHost.
    var guestdBinary: URL? = Bundle.main.executableURL
    /// A bridge's server on the Mac (Phase 12).
    var bridgeServer: (CommandBridge, InstancePaths) -> BridgeServing = { bridge, paths in
        BridgeServer(command: bridge.command, socket: bridge.socket(in: paths), log: bridge.log(in: paths),
                     maxConnections: 4, maxLogBytes: 1 << 20, environment: ProcessInfo.processInfo.environment)
    }

    /// A host command's server on the Mac (agents phase). `home`: the
    /// guest user's home, where the exchange folder is.
    var hostCommandServer: (HostCommand, InstancePaths, String) -> HostCommandServing = { command, paths, home in
        HostCommandServer(command: command, socket: command.socket(in: paths), log: command.log(in: paths),
                          exchange: paths.exchange, guestExchange: home + "/.monad/exchange",
                          environment: ProcessInfo.processInfo.environment)
    }

    /// Monad's MCP endpoint for a VM with a role (agents phase).
    var mcpEndpoint: (URL, String, String) -> MCPEndpointServing = { socket, token, vm in
        MCPHTTPServer(socket: socket, token: token) { data in await MCPRouter.route(vm, data) }
    }

    @MainActor
    static var live: VMEnvironment {
        var env = VMEnvironment(runner: LoggingCommandRunner(SystemCommandRunner()), machines: VZMachineFactory(), clock: SystemClock(),
                                virtualizationSupported: MNDVirtualMachine.isSupported(), networks: NetdSupervisor.shared)
        env.allowsMacGuests = GuestOS.ready.contains(.macos)
        return env
    }
}
