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
                FileHandle.standardError.write(Data("monad mcp: cannot reach MonadHost (open Monad once): \(error.localizedDescription)\n".utf8))
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
}
