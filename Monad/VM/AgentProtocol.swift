//
//  AgentProtocol.swift — host side of the monad-agent line protocol.
//
//  Every byte here comes from the guest, which we treat as hostile: lines are
//  bounded, restricted to printable ASCII, and must match an exact grammar.
//  Anything else is dropped.
//

import Foundation

/// A TCP socket listening inside the guest.
struct ListeningPort: Hashable, Sendable, Codable {
    let address: String
    let port: Int

    var isWildcard: Bool { address == "0.0.0.0" || address == "::" }

    var isLoopback: Bool {
        if address == "::1" { return true }
        var v4 = in_addr()
        guard inet_pton(AF_INET, address, &v4) == 1 else { return false }
        return UInt32(bigEndian: v4.s_addr) >> 24 == 127
    }
}

/// How the agent learns about listening sockets.
enum AgentWatchMode: String, Sendable {
    case events   // kernel tracepoint: changes arrive within milliseconds
    case polling  // fallback: /proc is re-read every second
}

enum AgentMessage: Equatable, Sendable {
    case hello(version: Int)
    case mode(AgentWatchMode)
    case port(ListeningPort)    // snapshot entry
    case opened(ListeningPort)  // port+
    case closed(ListeningPort)  // port-
    case end
    case ping
    /// A password prompt came on the guest's screen (macOS: auto-fill).
    case prompt
    case error(String)

    static let maxLineLength = 512

    /// For the debug log; nil for pings (one every 10 s says nothing).
    var debugText: String? {
        switch self {
        case .hello(let version): return "hello, protocol \(version)"
        case .mode(.events): return "watching ports through kernel events"
        case .mode(.polling): return "watching ports by checking every second"
        case .port(let p): return "port listening \(p.address):\(p.port)"
        case .opened(let p): return "port opened \(p.address):\(p.port)"
        case .closed(let p): return "port closed \(p.address):\(p.port)"
        case .end: return "end of the port list"
        case .ping: return nil
        case .prompt: return "a password prompt is on screen"
        case .error(let message): return "error: \(message)"
        }
    }

    static func parse<S: StringProtocol>(_ line: S) -> AgentMessage? {
        guard line.utf8.count <= maxLineLength, !line.isEmpty,
              line.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else { return nil }
        let t = String(line).split(separator: " ", omittingEmptySubsequences: false).map { String($0) }
        guard !t.contains(where: { $0.isEmpty }) else { return nil }

        switch (t.first, t.count) {
        case ("hello", 3):
            guard t[1] == "monad-agent", let v = decimal(t[2], max: 1000) else { return nil }
            return .hello(version: v)
        case ("port", 4), ("port+", 4), ("port-", 4):
            guard t[1] == "tcp", isIPAddress(t[2]), let p = decimal(t[3], max: 65535) else { return nil }
            let lp = ListeningPort(address: t[2], port: p)
            switch t[0] {
            case "port+": return .opened(lp)
            case "port-": return .closed(lp)
            default: return .port(lp)
            }
        case ("mode", 2):
            return AgentWatchMode(rawValue: t[1]).map { .mode($0) }
        case ("end", 1): return .end
        case ("ping", 1): return .ping
        case ("prompt", 2): return t[1] == "password" ? .prompt : nil
        case ("error", 2):
            guard t[1].range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil else { return nil }
            return .error(t[1])
        default:
            return nil
        }
    }

    /// Strict positive decimal: digits only, no sign, no leading zero.
    private static func decimal(_ s: String, max: Int) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy({ $0.isASCII && $0.isNumber }), s.first != "0",
              let v = Int(s), v >= 1, v <= max else { return nil }
        return v
    }

    private static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}

/// Splits a byte stream into lines with bounded memory. A line longer than
/// the limit is discarded in its entirety (up to its newline).
struct AgentLineReader {
    let maxLineLength: Int
    private var buffer = Data()
    private var discarding = false
    private(set) var droppedLines = 0

    init(maxLineLength: Int = AgentMessage.maxLineLength) {
        self.maxLineLength = maxLineLength
    }

    var bufferedBytes: Int { buffer.count }

    /// Feed bytes; returns the complete, valid UTF-8 lines (without CR/LF).
    mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if discarding {
                    discarding = false
                } else {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    if let s = String(data: buffer, encoding: .utf8) { lines.append(s) }
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if discarding { continue }
            buffer.append(byte)
            if buffer.count > maxLineLength {
                buffer.removeAll(keepingCapacity: true)
                discarding = true
                droppedLines += 1
            }
        }
        return lines
    }
}
