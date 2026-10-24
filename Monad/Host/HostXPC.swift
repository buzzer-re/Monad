//
//  HostXPC.swift — XPC transport between Monad.app and MonadHost.
//
//  The XPC surface is two methods carrying HostProtocol JSON, so the typed
//  contract lives in one place (HostProtocol) and is golden-tested. Both
//  sides pin the peer's code signature: the host only serves Monad, and the
//  app only talks to a MonadHost it signed.
//

import Foundation
import Security
import os

@objc protocol MonadHostXPCProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
}

@objc protocol MonadClientXPCProtocol {
    func event(_ data: Data)
}

enum HostXPCSecurity {
    /// launchd label and Mach service of the host agent (each flavor its own).
    static let machServiceName = Flavor.current.hostLabel
    static let appIdentifier = Flavor.current.appIdentifier
    static let hostIdentifier = Flavor.current.hostIdentifier

    /// Code requirement both sides impose on their peer, derived from our own
    /// signature. With a Team ID (release builds) peers must be signed by the
    /// same team with one of our identifiers. Development builds are signed
    /// ad hoc and can only be pinned by identifier.
    static func peerRequirement() -> String? {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { return failed("SecCodeCopySelf", status) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { return failed("SecCodeCopyStaticCode", status) }
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dict = info as? [String: Any] else {
            return failed("SecCodeCopySigningInformation", status)
        }
        let identifiers = "(identifier \"\(appIdentifier)\" or identifier \"\(hostIdentifier)\")"
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and \(identifiers)"
        }
        guard dict[kSecCodeInfoIdentifier as String] != nil else { return failed("unsigned", errSecCSUnsigned) }
        return identifiers
    }

    /// The requirement MonadHost puts on a client, read again for each
    /// connection. With a team: the team and our identifiers. Ad hoc (where
    /// anyone can sign with our identifiers): each identifier with the code
    /// hash of Monad's own binary as installed now (the app beside MonadHost,
    /// and MonadHost itself for `--mcp`), so a process that only borrows the
    /// identifier is refused, and an app rebuilt or updated in place is not.
    /// nil when a hash cannot be read: no client is served then.
    static func clientRequirement(team: String?, app: URL, host: URL) -> String? {
        if let team, !team.isEmpty {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and "
                + "(identifier \"\(appIdentifier)\" or identifier \"\(hostIdentifier)\")"
        }
        guard let a = cdhash(of: app), let h = cdhash(of: host) else { return nil }
        return "(identifier \"\(appIdentifier)\" and cdhash H\"\(a)\") or (identifier \"\(hostIdentifier)\" and cdhash H\"\(h)\")"
    }

    /// MonadHost's client requirement for the bundle it runs from.
    static func clientRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path else { return nil }
        let host = path as URL
        return clientRequirement(team: teamIdentifier(), app: host.deletingLastPathComponent().appendingPathComponent("Monad"),
                                 host: host)
    }

    /// The code directory hash of the binary at `url`, in hex (nil when it
    /// is unsigned or unreadable).
    static func cdhash(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// Team ID of this process's signature (nil when signed ad hoc).
    static func teamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    private static func failed(_ step: String, _ status: OSStatus) -> String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        Log.host.fault("reading our own code signature failed at \(step, privacy: .public): \(text, privacy: .public)")
        return nil
    }
}

// MARK: - Host side

/// Accepts app connections and binds each to a HostConnection.
final class HostXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let service: HostService
    /// The client requirement, asked for each connection (nil: refused).
    /// No closure: every client is served (tests).
    private let requirement: (@Sendable () -> String?)?
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    init(listener: NSXPCListener, service: HostService, peerRequirement: String?) {
        self.listener = listener
        self.service = service
        self.requirement = peerRequirement.map { r in { r } }
        super.init()
        listener.delegate = self
    }

    init(listener: NSXPCListener, service: HostService, requirement: @escaping @Sendable () -> String?) {
        self.listener = listener
        self.service = service
        self.requirement = requirement
        super.init()
        listener.delegate = self
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    func resume() { listener.resume() }

    /// Stop listening and drop every client.
    func invalidate() {
        listener.invalidate()
        let all = lock.withLock { () -> [NSXPCConnection] in
            defer { connections.removeAll() }
            return Array(connections.values)
        }
        for c in all { c.invalidate() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        if let requirement {
            // Fail closed: a requirement that cannot be made serves no one.
            guard let r = requirement() else { return false }
            conn.setCodeSigningRequirement(r)
        }
        conn.exportedInterface = NSXPCInterface(with: MonadHostXPCProtocol.self)
        conn.remoteObjectInterface = NSXPCInterface(with: MonadClientXPCProtocol.self)
        let export = HostXPCExport(service: service, xpc: conn)
        conn.exportedObject = export
        let id = ObjectIdentifier(conn)
        let ended: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in export.close() }
            guard let self else { return }
            _ = self.lock.withLock { self.connections.removeValue(forKey: id) }
        }
        conn.invalidationHandler = ended
        conn.interruptionHandler = ended
        lock.withLock { connections[id] = conn }
        conn.resume()
        return true
    }
}

/// The object an app talks to. Requests are handled on the main actor, in
/// arrival order per connection.
private final class HostXPCExport: NSObject, MonadHostXPCProtocol, @unchecked Sendable {
    private let service: HostService
    private weak var xpc: NSXPCConnection?
    @MainActor private var connection: HostConnection?
    @MainActor private var closed = false

    init(service: HostService, xpc: NSXPCConnection) {
        self.service = service
        self.xpc = xpc
    }

    @MainActor private func hostConnection() -> HostConnection? {
        guard !closed else { return nil }
        if let connection { return connection }
        let c = service.connect { [weak self] event in
            guard let data = try? HostProtocol.encode(event),
                  let proxy = self?.xpc?.remoteObjectProxy as? MonadClientXPCProtocol else { return }
            proxy.event(data)
        }
        connection = c
        return c
    }

    @MainActor func close() {
        closed = true
        connection?.close()
        connection = nil
    }

    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        let reply = Unchecked(value: reply)
        Task { @MainActor in
            guard let c = self.hostConnection() else { return }
            reply.value(await c.handle(data))
        }
    }
}

// MARK: - App side

/// A connection to MonadHost (its Mach service, or an endpoint in tests).
@MainActor
final class XPCHostTransport: HostTransport {
    var onEvent: ((Data) -> Void)?
    var onInvalidated: (() -> Void)?
    private let connection: NSXPCConnection
    private let sink = EventSink()
    private var closedByUs = false
    private var ended = false

    convenience init(machServiceName: String = HostXPCSecurity.machServiceName, peerRequirement: String?) {
        self.init(connection: NSXPCConnection(machServiceName: machServiceName), peerRequirement: peerRequirement)
    }

    convenience init(endpoint: NSXPCListenerEndpoint, peerRequirement: String?) {
        self.init(connection: NSXPCConnection(listenerEndpoint: endpoint), peerRequirement: peerRequirement)
    }

    private init(connection: NSXPCConnection, peerRequirement: String?) {
        self.connection = connection
        if let peerRequirement { connection.setCodeSigningRequirement(peerRequirement) }
        connection.remoteObjectInterface = NSXPCInterface(with: MonadHostXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: MonadClientXPCProtocol.self)
        connection.exportedObject = sink
        observe()
        connection.resume()
    }

    private func observe() {
        sink.onEvent = { [weak self] data in
            Task { @MainActor in self?.onEvent?(data) }
        }
        // Interruption (the host exited) is final for this transport too: the
        // client makes a new one, which lets launchd start a fresh host.
        let ended: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.connectionEnded() }
        }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
    }

    private func connectionEnded() {
        guard !ended else { return }
        ended = true
        connection.invalidate()
        if !closedByUs { onInvalidated?() }
    }

    func send(_ request: Data) async throws -> Data {
        guard !ended else { throw HostClientError.unavailable }
        let connection = self.connection
        let reply: Data = try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce(cont)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: error)
            }
            guard let host = proxy as? MonadHostXPCProtocol else {
                once.resume(throwing: HostClientError.unavailable)
                return
            }
            host.request(request) { data in once.resume(returning: data) }
        }
        guard reply.count <= HostProtocol.maxMessageBytes else { throw HostProtocolError.tooLarge(reply.count) }
        return reply
    }

    func invalidate() {
        closedByUs = true
        ended = true
        connection.invalidate()
    }
}

private final class EventSink: NSObject, MonadClientXPCProtocol, @unchecked Sendable {
    var onEvent: ((Data) -> Void)?

    func event(_ data: Data) {
        guard data.count <= HostProtocol.maxMessageBytes else { return }
        onEvent?(data)
    }
}

/// XPC promises exactly one of reply or error handler per message; this
/// guards the continuation against a misbehaving peer all the same.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Data, Error>?

    init(_ cont: CheckedContinuation<Data, Error>) { self.cont = cont }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { cont = nil }
            return cont
        }
    }

    func resume(returning data: Data) { take()?.resume(returning: data) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}
