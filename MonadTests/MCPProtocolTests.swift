//
//  MCPProtocolTests.swift — the Model Context Protocol subset Monad serves
//  (agents phase): JSON-RPC 2.0 messages parsed strictly, initialize with
//  version negotiation, ping, tools/list and tools/call; notifications get
//  no answer; anything malformed gets the JSON-RPC error or nothing.
//

import XCTest
@testable import Monad

@MainActor
final class MCPProtocolTests: XCTestCase {
    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    /// One tool that echoes, one that fails.
    private func server() -> MCPServer {
        let echo = MCPTool(name: "echo", description: "Says it back.",
                           schema: .object(["type": .string("object"),
                                            "properties": .object(["text": .object(["type": .string("string")])]),
                                            "required": .array([.string("text")])]),
                           risk: .read) { call in
            MCPResult(text: try call.string("text"))
        }
        let broken = MCPTool(name: "broken", description: "Fails.", schema: .object(["type": .string("object")]), risk: .read) { _ in
            throw MonadError("It broke.")
        }
        return MCPServer(name: "monad", version: "1.0", tools: { _ in [echo, broken] })
    }

    private func send(_ s: MCPServer, _ text: String) async -> Data? {
        await s.handle(Data(text.utf8), caller: .mac)
    }

    func testInitializeNegotiatesTheVersion() async throws {
        let s = server()
        var r = try json(await send(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#))
        XCTAssertEqual(r["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(r["id"] as? Int, 1)
        var result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18", "a version Monad speaks is kept")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "monad")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNotNil(result["instructions"] as? String)
        r = try json(await send(s, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#))
        result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCP.supportedVersions[0], "otherwise Monad's newest")
        XCTAssertEqual(r["id"] as? String, "a")
    }

    func testPingAndNotifications() async throws {
        let s = server()
        let r = try json(await send(s, #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#))
        XCTAssertEqual((r["result"] as? [String: Any])?.count, 0)
        let none = await send(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none, "a notification gets no answer")
        let late = await send(s, #"{"jsonrpc":"2.0","id":3,"result":{}}"#)
        XCTAssertNil(late, "a response from the client is not answered")
    }

    func testToolsAreListedAndCalled() async throws {
        let s = server()
        let list = try json(await send(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["echo", "broken"])
        XCTAssertEqual(tools[0]["description"] as? String, "Says it back.")
        XCTAssertEqual((tools[0]["inputSchema"] as? [String: Any])?["type"] as? String, "object")

        var r = try json(await send(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#))
        var result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "hi")
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["type"] as? String, "text")

        r = try json(await send(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"broken","arguments":{}}}"#))
        result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "a tool's failure is a result the model sees")
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "It broke.")

        r = try json(await send(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#))
        result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "text is required (a string).")

        r = try json(await send(s, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    /// A tool's schema names its arguments (additionalProperties false):
    /// a call with another is refused before the tool runs or anyone is
    /// asked, so an argument nothing reads cannot fill the approval panel.
    func testArgumentsTheSchemaDoesNotNameAreRefused() async throws {
        let share = MCPTool(name: "share", description: "Shares.",
                            schema: .object(["type": .string("object"),
                                             "properties": .object(["path": .object(["type": .string("string")])]),
                                             "additionalProperties": .bool(false)]),
                            risk: .read) { call in MCPResult(text: "shared \(try call.string("path"))") }
        let s = MCPServer(name: "monad", version: "1.0", tools: { _ in [share] })
        var r = try json(await send(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"share","arguments":{"path":"/x","\nread_only":"true"}}}"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNil(r["result"], "the tool never ran")
        r = try json(await send(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"share","arguments":{"path":"/x"}}}"#))
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "shared /x")
    }

    /// Malformed input: the JSON-RPC errors where an id can be read,
    /// otherwise nothing; never a crash, never more than the bound.
    func testMalformedMessages() async throws {
        let s = server()
        var r = try json(await send(s, "{not json"))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32700)
        r = try json(await send(s, #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32600)
        r = try json(await send(s, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32600, "no batches (MCP 2025-06-18)")
        r = try json(await send(s, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32601)
        r = try json(await send(s, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32600, "an id is a string or a number")
        r = try json(await send(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1,2]}"#))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32602)
        r = try json(await send(s, String(repeating: "[", count: 100_000)))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32700)
        let huge = #"{"jsonrpc":"2.0","id":1,"method":"ping","x":""# + String(repeating: "a", count: MCP.maxMessageBytes) + #""}"#
        r = try json(await send(s, huge))
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32600)
    }

    /// Arguments are read strictly: a missing or mistyped one is said.
    func testArgumentsAreReadStrictly() throws {
        let call = MCPCall(caller: .mac, arguments: ["n": .number(3), "s": .string("x"), "b": .bool(true),
                                                       "f": .number(2.5), "list": .array([.string("a"), .number(1)])])
        XCTAssertEqual(try call.int("n"), 3)
        XCTAssertEqual(try call.string("s"), "x")
        XCTAssertEqual(try call.bool("b"), true)
        XCTAssertNil(try call.optionalString("missing"))
        XCTAssertThrowsError(try call.int("f")) { XCTAssertEqual($0.localizedDescription, "f is a whole number.") }
        XCTAssertThrowsError(try call.string("n")) { XCTAssertEqual($0.localizedDescription, "n is required (a string).") }
        XCTAssertThrowsError(try call.strings("list")) { XCTAssertEqual($0.localizedDescription, "list is a list of strings.") }
    }
}
