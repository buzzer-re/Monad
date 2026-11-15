//
//  SSHAskpass.swift — every question ssh asks about an SSH host (trust this
//  host key? a password, a passphrase, a one-time code) is asked by Monad,
//  never in a terminal tab and never on a command line:
//
//    ssh (SSH_ASKPASS_REQUIRE=force) → MonadHost as SSH_ASKPASS (`relay`)
//      → XPC, the peer pinned → the running MonadHost (SSHHostManager.ask)
//      → the Keychain, or a panel of the app's (SSHPromptPanel)
//
//  A ticket in the environment of the ssh Monad started says which host the
//  question is about; without one MonadHost answers nothing. The pure parts
//  are here: what kind of question a prompt is, which prompts a stored
//  password may answer, how a server's words are shown, the tickets, and
//  the questions waiting for the user.
//

import Foundation
import Security

enum SSHAskpass {
    static let ticketVariable = "MONAD_ASKPASS_TICKET"
    /// ssh's hint about what the prompt is for ("confirm", "none").
    static let hintVariable = "SSH_ASKPASS_PROMPT"
    /// ssh keeps 1023 bytes of an askpass answer, up to its first line end.
    static let maxSecretBytes = 1023

    /// This build's MonadHost binary, from the app or from MonadHost itself.
    static var helperPath: String {
        if let executable = Bundle.main.executableURL, executable.lastPathComponent == "MonadHost" { return executable.path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MonadHost").path
    }

    /// What an ssh run for an SSH host gets, so that its questions come to
    /// Monad even though it has a terminal.
    static func environment(ticket: String, helper: String = helperPath) -> [String: String] {
        ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", ticketVariable: ticket]
    }

    /// A ticket as MonadHost issues them: 32 random bytes in lowercase hex.
    static func isTicket(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Whether a secret can be an askpass answer: one line, within ssh's limit.
    static func isAnswerable(_ secret: String) -> Bool {
        secret.utf8.count <= maxSecretBytes && !secret.utf8.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0 }
    }

    /// The longest prompt MonadHost takes (the rest is not asked about).
    static let maxPromptBytes = 4096

    /// The askpass helper (MonadHost started by ssh as SSH_ASKPASS): asks
    /// the running MonadHost this one question and prints its answer. Any
    /// failure ends with status 1, which ssh takes as no answer.
    @MainActor
    static func relay(ticket: String, prompt: String, hint: String?, requirement: String) -> Never {
        func fail(_ reason: String) -> Never {
            FileHandle.standardError.write(Data("monad: \(reason)\n".utf8))
            exit(EXIT_FAILURE)
        }
        let transport = XPCHostTransport(peerRequirement: requirement)
        transport.onInvalidated = { fail("lost the connection to MonadHost") }
        Task { @MainActor in
            do {
                let hello = try HostProtocol.decode(HostResponse.self, from: try await transport.send(
                    HostProtocol.encode(HostRequest(id: 1, op: .hello, version: HostProtocol.version))))
                guard hello.ok else { throw MonadError(hello.error ?? "MonadHost refused the connection.") }
                var ask = HostRequest(id: 2, op: .askSSH)
                ask.ticket = ticket
                ask.prompt = String(decoding: prompt.utf8.prefix(maxPromptBytes), as: UTF8.self)
                ask.promptHint = hint
                let answer = try HostProtocol.decode(HostResponse.self, from: try await transport.send(
                    HostProtocol.encode(ask)))
                guard answer.ok, let secret = answer.secret else { throw MonadError(answer.error ?? "no answer") }
                transport.onInvalidated = nil
                FileHandle.standardOutput.write(Data((secret + "\n").utf8))
                exit(EXIT_SUCCESS)
            } catch {
                fail(error.localizedDescription)
            }
        }
        dispatchMain()
    }

    enum Kind: String, Codable, Sendable { case confirm, secret }

    /// What a prompt asks for; nil when ssh only tells something (the
    /// answer is empty).
    static func kind(prompt: String, hint: String?) -> Kind? {
        if hint == "none" { return nil }
        if hint == "confirm" || prompt.contains("(yes/no") { return .confirm }
        return .secret
    }

    /// Whether `prompt` is ssh's own password question for this user and
    /// host: "user@host's password:" (the system's ssh prints both whole;
    /// older ones cut them to 30 and 128 characters), or its
    /// keyboard-interactive "(user@host) Password:". Nothing else is ever
    /// answered from the Keychain: a prompt worded by the server (a code, a
    /// new password) always reaches the user.
    static func isPasswordPrompt(_ prompt: String, for host: SSHHost) -> Bool {
        let asked = prompt.trimmingCharacters(in: .whitespaces)
        return asked == "\(host.user)@\(host.host)'s password:"
            || asked == "\(host.user.prefix(30))@\(host.host.prefix(128))'s password:"
            || asked == "(\(host.user)@\(host.host)) Password:"
    }

    /// A prompt as Monad's panel shows it: a server chooses part of these
    /// words, so no control or direction characters, and a bounded size.
    static func shown(_ prompt: String) -> String {
        prompt.split(whereSeparator: \.isNewline).prefix(8).map { String($0).plain(limit: 200) }
            .joined(separator: "\n")
    }
}

/// One question of ssh's, waiting for the user.
struct SSHPromptRequest: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// The SSH host's name in Monad.
    var host: String
    var kind: SSHAskpass.Kind
    /// What ssh says (`SSHAskpass.shown`).
    var prompt: String
    /// The answer is this host's password and may be kept in the Keychain.
    var canRemember: Bool
    /// The connection asked before: the last answer was not accepted.
    var retry: Bool
    var asked: Date
}

/// The questions waiting for the user, and their answers (as `Approvals`).
@MainActor
final class SSHPrompts {
    nonisolated static let timeout: TimeInterval = 120
    nonisolated static let maxPending = 16

    private(set) var pending: [SSHPromptRequest] = []
    private var waiters: [UUID: CheckedContinuation<(answer: String?, remember: Bool), Never>] = [:]
    /// The list changed (HostService tells the apps).
    var onChange: (([SSHPromptRequest]) -> Void)?
    /// A question was asked (MonadHost opens the app if none is there).
    var onAsk: (() -> Void)?
    private let clock: MonadClock
    private let timeoutSeconds: TimeInterval

    init(clock: MonadClock = SystemClock(), timeout: TimeInterval = SSHPrompts.timeout) {
        self.clock = clock
        timeoutSeconds = timeout
    }

    /// Waits for the user's answer; nil when too many wait already, the
    /// user cancelled, or no answer came in time.
    func ask(_ request: SSHPromptRequest) async -> (answer: String?, remember: Bool) {
        guard pending.count < Self.maxPending else { return (nil, false) }
        pending.append(request)
        onChange?(pending)
        onAsk?()
        let id = request.id
        let timeoutSeconds = self.timeoutSeconds
        let clock = self.clock
        Task { @MainActor [weak self] in
            await clock.sleep(seconds: timeoutSeconds)
            self?.answer(id, nil, remember: false)
        }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    /// The user's answer (nil: cancelled); false when the question is gone
    /// (answered or timed out).
    @discardableResult
    func answer(_ id: UUID, _ answer: String?, remember: Bool) -> Bool {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return false }
        pending.remove(at: i)
        onChange?(pending)
        waiters.removeValue(forKey: id)?.resume(returning: (answer, remember))
        return true
    }
}

/// What lets an askpass helper ask about a host: MonadHost issues a ticket
/// for each ssh it (or the app, for a tab) starts, and a question without a
/// live one is refused.
@MainActor
final class SSHTickets {
    nonisolated static let lifetime: TimeInterval = 600
    nonisolated static let maxLive = 256

    struct Ticket: Equatable {
        let host: String
        /// The hosts whose stored password this connection was given
        /// already: a second password question means the server refused it.
        var released: Set<String> = []
        /// The secrets asked for on this connection, as shown: one asked
        /// again was not accepted.
        private(set) var answered: Set<String> = []

        mutating func note(answered prompt: String) {
            if answered.count < 32 { answered.insert(prompt) }
        }
    }

    private var live: [(value: String, issued: Date, ticket: Ticket)] = []
    private let clock: MonadClock

    init(clock: MonadClock = SystemClock()) {
        self.clock = clock
    }

    private func dropExpired() {
        let now = clock.now()
        live.removeAll { now.timeIntervalSince($0.issued) > Self.lifetime }
    }

    func issue(for host: String) -> String {
        dropExpired()
        if live.count >= Self.maxLive { live.removeFirst(live.count - Self.maxLive + 1) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("no random bytes for an askpass ticket")
        }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        live.append((value, clock.now(), Ticket(host: host)))
        return value
    }

    /// nil when unknown or older than `lifetime`.
    func ticket(_ value: String) -> Ticket? {
        dropExpired()
        return live.first { $0.value == value }?.ticket
    }

    func update(_ value: String, _ change: (inout Ticket) -> Void) {
        guard let i = live.firstIndex(where: { $0.value == value }) else { return }
        change(&live[i].ticket)
    }

    func forget(host: String) {
        live.removeAll { $0.ticket.host == host }
    }
}
