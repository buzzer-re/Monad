//
//  MCPProtocol.swift — the Model Context Protocol subset Monad serves
//  (agents phase): JSON-RPC 2.0 over whatever carries it (stdio through the
//  `MonadHost --mcp` shim for agents on the Mac, HTTP for agents in VMs),
//  with `initialize` (version negotiation), `ping`, `tools/list` and
//  `tools/call`. Messages are parsed strictly: bounded, one message (no
//  batches), exact shapes; a notification gets no answer, a malformed
//  message the JSON-RPC error when it has a readable id. Written here, like
//  everything in Monad: no SDK.
//

import Foundation

enum MCP {
    /// Newest first; a client asking for another gets the newest.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let maxMessageBytes = 1 << 20

    enum ErrorCode: Int {
        case parse = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
    }
}

/// Any JSON value.
enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// From what JSONSerialization or a Codable value gives.
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value), let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return v
    }

    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }
}

/// Who calls (the access rules and the audit log go by it).
enum MCPCaller: Equatable, Sendable {
    /// An agent on the Mac, through `MonadHost --mcp`.
    case mac
    /// An agent in this VM, through its endpoint.
    case vm(String)

    var label: String {
        switch self {
        case .mac: return "An agent on this Mac"
        case .vm(let name): return "The VM “\(name)”"
        }
    }
}

/// A tool's arguments, read strictly.
struct MCPCall: Sendable {
    let caller: MCPCaller
    let arguments: [String: JSONValue]

    struct Problem: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func string(_ key: String) throws -> String {
        guard case .string(let s)? = arguments[key] else { throw Problem(message: "\(key) is required (a string).") }
        return s
    }

    func optionalString(_ key: String) throws -> String? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .string(let s)?: return s
        default: throw Problem(message: "\(key) is a string.")
        }
    }

    func int(_ key: String) throws -> Int {
        guard let v = try optionalInt(key) else { throw Problem(message: "\(key) is required (a whole number).") }
        return v
    }

    func optionalInt(_ key: String) throws -> Int? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .number(let n)? where n.rounded() == n && abs(n) < 1e12: return Int(n)
        default: throw Problem(message: "\(key) is a whole number.")
        }
    }

    func optionalNumber(_ key: String) throws -> Double? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .number(let n)? where n.isFinite: return n
        default: throw Problem(message: "\(key) is a number.")
        }
    }

    func bool(_ key: String) throws -> Bool {
        guard let v = try optionalBool(key) else { throw Problem(message: "\(key) is required (true or false).") }
        return v
    }

    func optionalBool(_ key: String) throws -> Bool? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .bool(let b)?: return b
        default: throw Problem(message: "\(key) is true or false.")
        }
    }

    func strings(_ key: String) throws -> [String] {
        switch arguments[key] {
        case nil, .null?: return []
        case .array(let a)?:
            return try a.map { v in
                guard case .string(let s) = v else { throw Problem(message: "\(key) is a list of strings.") }
                return s
            }
        default: throw Problem(message: "\(key) is a list of strings.")
        }
    }
}

/// What a tool says back: text for the model, and the same as structured
/// content when there is some.
struct MCPResult: Sendable {
    var text: String
    var structured: JSONValue?
    var isError = false
    /// PNG pictures, given after the text.
    var images: [Data] = []

    init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    /// A value as pretty JSON text and as structured content.
    static func json<T: Encodable>(_ value: T) -> MCPResult {
        let v = JSONValue.from(value)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let text = String(decoding: (try? enc.encode(v)) ?? Data(), as: UTF8.self)
        if case .object = v { return MCPResult(text: text, structured: v) }
        return MCPResult(text: text, structured: .object(["result": v]))
    }
}

/// A tool: what an agent sees, how risky it is, and what it does.
struct MCPTool: Sendable {
    enum Risk: String, Sendable {
        /// Reads only.
        case read
        /// Changes something, within what the caller may do.
        case normal
        /// Asks the user first (from the Mac; a VM beyond its scope too).
        case risky
    }

    let name: String
    let description: String
    let schema: JSONValue
    let risk: Risk
    let run: @Sendable @MainActor (MCPCall) async throws -> MCPResult

    init(name: String, description: String, schema: JSONValue, risk: Risk,
         run: @escaping @Sendable @MainActor (MCPCall) async throws -> MCPResult) {
        self.name = name
        self.description = description
        self.schema = schema
        self.risk = risk
        self.run = run
    }
}

/// Decides, before a tool runs, whether it may (agents phase step 4 makes
/// it ask the user). Throws to refuse, with the reason the model sees.
typealias MCPGate = @MainActor (MCPCaller, MCPTool, MCPCall) async throws -> Void

/// The engine: one JSON-RPC message in, one (or none) out. `tools` lists
/// what a caller sees.
@MainActor
final class MCPServer {
    private let name: String
    private let version: String
    private let tools: @MainActor (MCPCaller) -> [MCPTool]
    private let gate: MCPGate
    /// Every call, after it ended (the audit log).
    var onCall: ((MCPCaller, String, [String: JSONValue], MCPResult, Duration) -> Void)?

    init(name: String, version: String, tools: @escaping @MainActor (MCPCaller) -> [MCPTool],
         gate: @escaping MCPGate = { _, _, _ in }) {
        self.name = name
        self.version = version
        self.tools = tools
        self.gate = gate
    }

    static let instructions = """
        Monad runs Linux virtual machines on this Mac, each a sandbox for code you do not fully trust. \
        These tools list, create, start, stop and delete VMs, run commands and move text files in them, \
        and change their settings (forwards, firewall, bridges, host commands). Changes that could reach \
        the Mac ask the user first; a refusal is final for that call.
        """

    func handle(_ data: Data, caller: MCPCaller) async -> Data? {
        guard data.count <= MCP.maxMessageBytes else { return Self.error(nil, .invalidRequest, "The message is too large.") }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return Self.error(nil, .parse, "Not JSON.")
        }
        guard case .object(let m) = message else {
            return Self.error(nil, .invalidRequest, "One message at a time, a JSON object.")
        }
        // An id is a string or a number; anything else cannot be answered by it.
        let id: JSONValue?
        switch m["id"] {
        case nil: id = nil
        case .string?, .number?: id = m["id"]
        default: return Self.error(nil, .invalidRequest, "An id is a string or a number.")
        }
        guard m["jsonrpc"] == .string("2.0") else { return Self.error(id, .invalidRequest, "jsonrpc must be \"2.0\".") }
        guard case .string(let method)? = m["method"] else {
            // A response (result or error) from the client: Monad asked nothing.
            return nil
        }
        let params: [String: JSONValue]
        switch m["params"] {
        case nil, .null?: params = [:]
        case .object(let p)?: params = p
        default: return id == nil ? nil : Self.error(id, .invalidParams, "params is an object.")
        }
        guard let id else { return nil } // a notification
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string
            let version = asked.flatMap { MCP.supportedVersions.contains($0) ? $0 : nil } ?? MCP.supportedVersions[0]
            return Self.result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(name), "version": .string(self.version)]),
                "instructions": .string(Self.instructions),
            ]))
        case "ping":
            return Self.result(id, .object([:]))
        case "tools/list":
            let list = tools(caller).map { t -> JSONValue in
                .object(["name": .string(t.name), "description": .string(t.description), "inputSchema": t.schema,
                         "annotations": .object(["readOnlyHint": .bool(t.risk == .read),
                                                 "destructiveHint": .bool(t.risk == .risky)])])
            }
            return Self.result(id, .object(["tools": .array(list)]))
        case "tools/call":
            guard case .string(let toolName)? = params["name"] else {
                return Self.error(id, .invalidParams, "name is the tool's name.")
            }
            guard let tool = tools(caller).first(where: { $0.name == toolName }) else {
                return Self.error(id, .invalidParams, "There is no tool called \(toolName).")
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let a)?: arguments = a
            default: return Self.error(id, .invalidParams, "arguments is an object.")
            }
            // Only what the schema names: an argument nothing reads must not
            // reach the approval panel.
            if case .bool(false)? = tool.schema.object?["additionalProperties"], let named = tool.schema.object?["properties"]?.object,
               let odd = arguments.keys.sorted().first(where: { named[$0] == nil }) {
                return Self.error(id, .invalidParams, "\(toolName) takes no argument \(String(decoding: JSONValue.string(odd).encoded(), as: UTF8.self)).")
            }
            let call = MCPCall(caller: caller, arguments: arguments)
            let start = ContinuousClock.now
            var result: MCPResult
            do {
                try await gate(caller, tool, call)
                result = try await tool.run(call)
            } catch {
                result = MCPResult(text: error.localizedDescription, isError: true)
            }
            onCall?(caller, tool.name, arguments, result, ContinuousClock.now - start)
            let pictures = result.images.map {
                JSONValue.object(["type": .string("image"), "data": .string($0.base64EncodedString()), "mimeType": .string("image/png")])
            }
            var out: [String: JSONValue] = [
                "content": .array([.object(["type": .string("text"), "text": .string(result.text)])] + pictures),
                "isError": .bool(result.isError),
            ]
            if let s = result.structured, !result.isError { out["structuredContent"] = s }
            return Self.result(id, .object(out))
        default:
            return Self.error(id, .methodNotFound, "Monad does not serve \(method).")
        }
    }

    static func result(_ id: JSONValue, _ result: JSONValue) -> Data {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encoded()
    }

    static func error(_ id: JSONValue?, _ code: MCP.ErrorCode, _ message: String) -> Data {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id ?? .null,
                          "error": .object(["code": .number(Double(code.rawValue)), "message": .string(message)])]).encoded()
    }
}
