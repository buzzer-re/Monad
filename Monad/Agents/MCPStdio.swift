//
//  MCPStdio.swift — `MonadHost --mcp`: Monad's MCP server for agents on
//  the Mac, over stdio (one JSON-RPC message per line), as Claude Code and
//  Codex start a local server:
//
//      claude mcp add monad -- /Applications/Monad.app/Contents/MacOS/MonadHost --mcp
//
//  It is the same signed binary as MonadHost, so the running host accepts
//  it over XPC like the app (HostXPC's peer check), and relays each line as
//  an `mcp` request; the server itself, its tools, the user's approvals and
//  the audit log live in MonadHost.
//

import Foundation

enum MCPStdio {
    /// Relays stdin to MonadHost and its answers to stdout until stdin ends.
    @MainActor
    static func run(requirement: String) -> Never {
        let transport = XPCHostTransport(peerRequirement: requirement)
        transport.onInvalidated = {
            FileHandle.standardError.write(Data("monad mcp: lost the connection to MonadHost\n".utf8))
            exit(EX_UNAVAILABLE)
        }
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
        Task { @MainActor in
            var id: UInt64 = 1
            do {
                let hello = try HostProtocol.decode(HostResponse.self, from: try await transport.send(
                    HostProtocol.encode(HostRequest(id: id, op: .hello, version: HostProtocol.version))))
                guard hello.ok else { throw MonadError(hello.error ?? "MonadHost refused the connection.") }
            } catch {
                // Said on stderr and to the client, every request: an MCP
                // client shows no stderr, only a connection that closed.
                let reason = "MonadHost cannot be reached (open Monad once): \(error.localizedDescription) "
                    + "(\(launchdSummary()))"
                FileHandle.standardError.write(Data("monad mcp: \(reason)\n".utf8))
                transport.onInvalidated = nil
                for await line in lines {
                    if let answer = unreachableAnswer(to: line, reason: reason) {
                        FileHandle.standardOutput.write(answer + Data("\n".utf8))
                    }
                }
                exit(EX_UNAVAILABLE)
            }
            for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                id += 1
                let answer: String?
                do {
                    let r = try HostProtocol.decode(HostResponse.self, from: try await transport.send(
                        HostProtocol.encode(HostRequest(id: id, op: .mcp, mcp: line))))
                    if r.ok {
                        answer = r.mcp
                    } else {
                        answer = String(decoding: MCPServer.error(nil, .internalError, r.error ?? "MonadHost could not answer."),
                                        as: UTF8.self)
                    }
                } catch {
                    answer = String(decoding: MCPServer.error(nil, .internalError, error.localizedDescription), as: UTF8.self)
                }
                if let answer {
                    FileHandle.standardOutput.write(Data((answer + "\n").utf8))
                }
            }
            transport.invalidate()
            exit(EXIT_SUCCESS)
        }
        dispatchMain()
    }

    /// The error a request gets while MonadHost cannot be reached (its id
    /// kept); nothing for a notification.
    @MainActor
    static func unreachableAnswer(to line: String, reason: String) -> Data? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              case .object(let fields) = message else {
            return MCPServer.error(nil, .parse, reason)
        }
        guard let id = fields["id"], id != .null else { return nil }
        return MCPServer.error(id, .internalError, reason)
    }

    /// launchd's view of MonadHost's job, from `launchctl print`.
    static func launchdSummary(status: Int32, printed: String) -> String {
        guard status == 0 else { return "launchd has no MonadHost job" }
        func value(_ key: String) -> String? {
            printed.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(key + " = ") }.map { String($0.dropFirst(key.count + 3)) }
        }
        return "launchd: " + [value("state"), value("pid").map { "pid \($0)" }, value("program")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private static func launchdSummary() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(HostXPCSecurity.machServiceName)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return "launchctl did not run" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return launchdSummary(status: p.terminationStatus, printed: String(decoding: data.prefix(64 << 10), as: UTF8.self))
    }
}
