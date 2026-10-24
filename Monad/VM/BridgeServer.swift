//
//  BridgeServer.swift — MonadHost's side of a stdio bridge (Phase 12): a
//  unix socket only the user can reach (0600, in the VM's private folder),
//  and for each connection the bridge's command, socat `fork EXEC:` style:
//  the connection is its stdin and stdout, stderr goes to the bridge's log.
//  The command runs without a shell, with only the variables a program
//  needs, in a process group of its own; at most `maxConnections` run at
//  once, and stopping the bridge ends them all. The VM reaches the socket
//  through a remote forward on its ssh master (CommandBridge.spec).
//

import Foundation

/// What VMInstance needs of a bridge's server (fakes in tests).
protocol BridgeServing: AnyObject {
    func start() throws
    func stop()
}

final class BridgeServer: BridgeServing, @unchecked Sendable {
    /// The variables a command gets from MonadHost's environment; nothing
    /// else (no secrets, no DYLD_ settings) reaches it.
    static let passedVariables: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"]

    private let command: [String]
    private let socket: URL
    private let log: URL
    private let maxConnections: Int
    private let maxLogBytes: Int
    private let environment: [String]
    private let home: String?

    // State, only touched on `queue`.
    private let queue = DispatchQueue(label: "dev.monad.bridge")
    private var listener: Int32 = -1
    private var logFD: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var children: [pid_t: DispatchSourceProcess] = [:]

    init(command: [String], socket: URL, log: URL, maxConnections: Int, maxLogBytes: Int, environment: [String: String]) {
        self.command = command
        self.socket = socket
        self.log = log
        self.maxConnections = maxConnections
        self.maxLogBytes = maxLogBytes
        self.environment = environment.filter { Self.passedVariables.contains($0.key) }.map { "\($0.key)=\($0.value)" }.sorted()
        home = environment["HOME"]
    }

    deinit { stop() }

    /// Commands running now.
    var running: Int { queue.sync { children.count } }

    /// A unix socket at `path` only the user can reach (0600), listening,
    /// non-blocking and close-on-exec. A socket left by an earlier MonadHost
    /// is replaced; anything else at that path is not Monad's to remove.
    static func listen(at path: String, what: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw MonadError("The path of \(what) is too long: \(path)")
        }
        if let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType {
            guard type == .typeSocket else { throw MonadError("\(path) exists and is not a socket.") }
            unlink(path)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MonadError.posix(errno, "Cannot make \(what)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw MonadError.posix(e, "Cannot listen on \(path)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    // MARK: Socket

    func start() throws {
        let fd = try Self.listen(at: socket.path, what: "the bridge's socket")
        let logged = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard logged >= 0 else {
            let e = errno
            close(fd)
            unlink(socket.path)
            throw MonadError.posix(e, "Cannot open the bridge's log")
        }
        queue.sync {
            listener = fd
            logFD = logged
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.resume()
            accepting = source
        }
    }

    /// Stops listening, removes the socket and ends every command (their
    /// process groups get SIGTERM, then SIGKILL a moment later).
    func stop() {
        queue.sync {
            accepting?.cancel()
            accepting = nil
            if listener >= 0 {
                close(listener)
                listener = -1
                unlink(socket.path)
            }
            for pid in children.keys { kill(-pid, SIGTERM) }
            let left = Array(children.keys)
            if !left.isEmpty {
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    for pid in left where self.children[pid] != nil { kill(-pid, SIGKILL) }
                }
            }
        }
    }

    // MARK: Connections

    private func acceptAll() {
        while listener >= 0 {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            // The command reads and writes it plainly.
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
            if children.count >= maxConnections {
                note("a connection was refused: \(children.count) commands are running, the most this bridge runs at once")
                close(connection)
                continue
            }
            spawn(on: connection)
            close(connection)
        }
    }

    private func spawn(on connection: Int32) {
        boundLog()
        // In the home folder when there is one (a failed chdir would fail the spawn).
        var isFolder: ObjCBool = false
        let folder = home.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue ? $0 : nil }
        let pid: pid_t
        do {
            pid = try Self.spawn(command, environment: environment, stdin: connection, stdout: connection, stderr: logFD,
                                 directory: folder)
        } catch {
            note("\(command[0]) could not start: \(error.localizedDescription)")
            return
        }
        note("connection: \(command[0]) started (pid \(pid))")
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap(pid) }
        children[pid] = exit
        exit.resume()
        // It may have ended before the source was watching.
        reap(pid, onlyIfDone: true)
    }

    /// `argv` started without a shell: only stdin, stdout and stderr reach
    /// it, it leads a process group of its own with default signal handling,
    /// and it gets exactly `environment` ("NAME=value").
    static func spawn(_ argv: [String], environment: [String], stdin: Int32, stdout: Int32, stderr: Int32,
                      directory: String?) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                                                   | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        let args = argv.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            args.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid = pid_t()
        let rc = posix_spawn(&pid, argv[0], &actions, &attributes, args, envp)
        guard rc == 0 else { throw MonadError(String(cString: strerror(rc))) }
        return pid
    }

    private func reap(_ pid: pid_t, onlyIfDone: Bool = false) {
        guard children[pid] != nil else { return }
        var status: Int32 = 0
        let done = waitpid(pid, &status, WNOHANG)
        guard done == pid || !onlyIfDone else { return }
        children[pid]?.cancel()
        children[pid] = nil
        note("pid \(pid) ended")
    }

    // MARK: Log

    private func note(_ line: String) {
        guard logFD >= 0 else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        _ = text.utf8CString.withUnsafeBytes { write(logFD, $0.baseAddress, $0.count - 1) }
    }

    /// The log starts again once it passes its size.
    private func boundLog() {
        var info = stat()
        guard logFD >= 0, fstat(logFD, &info) == 0, info.st_size > maxLogBytes else { return }
        _ = ftruncate(logFD, 0)
        note("the log started again (it had passed \(maxLogBytes) bytes)")
    }
}
