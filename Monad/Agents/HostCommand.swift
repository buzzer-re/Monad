//
//  HostCommand.swift — a Mac command a VM may run (agents phase): a
//  program the user chose, fixed arguments the VM never
//  sees, and the arguments the VM may give, each with an anchored pattern
//  it must match. The VM never names a program. Its request is parsed by
//  Monad (quotes as a shell has them, nothing else: no expansion, no
//  shell), every value checked before anything runs, and the program runs
//  in a folder this VM shares, under a time limit, one run at a time
//  (HostCommandServer). An MCP tool too (one per command).
//

import Foundation

struct HostCommand: Codable, Equatable, Hashable, Identifiable {
    struct Argument: Codable, Equatable, Hashable {
        var name: String
        /// An anchored regular expression over printable ASCII.
        var pattern: String
        var required: Bool = true
        var summary: String = ""
    }

    var id: UUID = UUID()
    /// Also its tool's name: `[a-z][a-z0-9-]{0,31}`.
    var name: String
    var summary: String
    /// Full path.
    var program: String
    var fixedArguments: [String] = []
    var arguments: [Argument] = []
    /// Full path, inside a folder this VM shares.
    var workingDirectory: String
    var timeoutSeconds: Int = 3600
    /// Each run gets a folder in the VM's exchange folder.
    var results: Bool = true
    var environment: [String: String] = [:]
    var guestPort: Int?
    var guestSocket: String?
    var enabled: Bool = true

    init(id: UUID = UUID(), name: String, summary: String, program: String, fixedArguments: [String] = [],
         arguments: [Argument] = [], workingDirectory: String, timeoutSeconds: Int = 3600, results: Bool = true,
         environment: [String: String] = [:], guestPort: Int? = nil, guestSocket: String? = nil, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.summary = summary
        self.program = program
        self.fixedArguments = fixedArguments
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.results = results
        self.environment = environment
        self.guestPort = guestPort
        self.guestSocket = guestSocket
        self.enabled = enabled
    }

    static let maxArguments = 16
    static let maxPatternBytes = 256
    static let maxSummary = 300
    static let maxFixedArguments = 32
    static let maxRequestBytes = 16 << 10
    /// Never set by a host command: they decide what the program loads, or
    /// where it thinks home is.
    static let forbiddenVariables: Set<String> = ["HOME", "SHELL", "IFS", "ENV", "BASH_ENV", "PS4"]

    // MARK: Places

    /// Where the VM reaches it: "127.0.0.1:<port>" or the socket's path.
    var guestEndpoint: String { guestPort.map { "127.0.0.1:\($0)" } ?? guestSocket ?? "" }

    /// Short, for the 104 bytes of a unix socket path.
    private var fileStem: String { "cmd-" + id.uuidString.prefix(8).lowercased() }

    func socket(in paths: InstancePaths) -> URL { paths.dir.appendingPathComponent(fileStem + ".sock") }
    func log(in paths: InstancePaths) -> URL { paths.dir.appendingPathComponent(fileStem + ".log") }

    /// The remote forward that takes the VM's connections to the socket.
    func spec(in paths: InstancePaths) -> SSHMux.Spec {
        SSHMux.Spec(flag: "-R", value: "\(guestEndpoint):\(socket(in: paths).path)")
    }

    // MARK: Rules

    /// What is wrong with it, in the user's words; nil when nothing is.
    /// `shares`: the VM's shared folders (the working folder is inside one).
    func problem(shares: [SharedFolder]) -> String? {
        if name.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) == nil {
            return "“\(name)” cannot be a tool name: lowercase letters, digits and dashes."
        }
        if summary.count > Self.maxSummary { return "The summary is at most \(Self.maxSummary) characters." }
        if Self.hasControl(summary) { return "The summary has a control character." }
        if !program.hasPrefix("/") || URL(fileURLWithPath: program).standardizedFileURL.path != program || Self.hasControl(program) {
            return "The program needs its full path, like /usr/bin/make."
        }
        if fixedArguments.count > Self.maxFixedArguments { return "At most \(Self.maxFixedArguments) fixed arguments." }
        if fixedArguments.contains(where: { Self.hasControl($0) || $0.utf8.count > 1024 }) {
            return "A fixed argument has a control character."
        }
        if arguments.count > Self.maxArguments { return "A host command takes at most \(Self.maxArguments) arguments." }
        var names = Set<String>()
        for a in arguments {
            if a.name.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) == nil {
                return "“\(a.name)” cannot be an argument's name: lowercase letters, digits and _."
            }
            guard names.insert(a.name).inserted else { return "Two arguments are called \(a.name)." }
            if let why = Self.patternProblem(a.pattern) { return "\(a.name): \(why)" }
            if a.summary.count > Self.maxSummary || Self.hasControl(a.summary) { return "\(a.name): the summary is too long or has a control character." }
        }
        let folder = SharePolicy.resolve(workingDirectory)
        if !workingDirectory.hasPrefix("/") || !shares.contains(where: { SharePolicy.inside(folder, SharePolicy.resolve($0.hostPath)) }) {
            return "The working folder must be inside a folder this VM shares."
        }
        if !(1...86_400).contains(timeoutSeconds) { return "The time limit is 1 second to 24 hours." }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            if key.range(of: "^[A-Z_][A-Z0-9_]{0,63}$", options: .regularExpression) == nil {
                return "“\(key)” is not a variable name (A-Z, 0-9, _)."
            }
            if Self.forbiddenVariables.contains(key) || key.hasPrefix("DYLD_") || key.hasPrefix("LD_") || key.hasPrefix("MONAD_") {
                return "\(key) cannot be set."
            }
            if !Self.isPrintableASCII(value) || value.utf8.count > 4096 { return "\(key): a value is printable ASCII." }
        }
        switch (guestPort, guestSocket) {
        case (let port?, nil) where (1024...65535).contains(port):
            break
        case (nil, let path?) where path.hasPrefix("/") && !path.contains(":") && !path.contains(where: \.isWhitespace)
            && !Self.hasControl(path) && path.utf8.count <= 100:
            break
        default:
            return "In the VM: a port from 1024 to 65535, or a socket's full path."
        }
        return nil
    }

    /// Patterns that admit anything, or that backtrack badly (a quantified
    /// group holding a quantifier), said when the command is added.
    var warnings: [String] {
        arguments.filter { $0.pattern.contains(".*") || $0.pattern.contains(".+") }
            .map { "\($0.name) takes anything (.*): the program gets whatever the VM sends." }
            + arguments.filter { $0.pattern.range(of: #"\([^()]*[+*}|][^()]*\)[+*{]"#, options: .regularExpression) != nil }
            .map { "\($0.name) has a nested repeat, which can take very long to check: such values are refused after a moment." }
    }

    private static func patternProblem(_ p: String) -> String? {
        guard isPrintableASCII(p) else { return "a pattern is printable ASCII." }
        guard p.utf8.count <= maxPatternBytes else { return "a pattern is at most \(maxPatternBytes) characters." }
        guard p.hasPrefix("^"), p.hasSuffix("$"), !p.hasSuffix("\\$"), p.count >= 2 else {
            return "a pattern starts with ^ and ends with $, so it covers the whole value."
        }
        guard (try? NSRegularExpression(pattern: p)) != nil else { return "the pattern does not compile." }
        return nil
    }

    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func isPrintableASCII(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    // MARK: Requests

    enum Request: Equatable {
        case run([String])
        case describe
    }

    struct Refused: Error, Equatable, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// One request line: `describe`, or `run` and its values quoted as a
    /// shell would (single quotes keep everything; double quotes keep all
    /// but `\"` and `\\`; words join where quotes meet), nothing expanded.
    static func parseRequest(_ line: String) throws -> Request {
        guard line.utf8.count <= maxRequestBytes else { throw Refused("The request is too long.") }
        var text = Substring(line)
        if text.hasSuffix("\r\n") { text = text.dropLast(2) } else if text.hasSuffix("\n") { text = text.dropLast() }
        for c in text.unicodeScalars {
            if c.properties.generalCategory == .control && c != "\t" { throw Refused("Control characters are not allowed.") }
            if c.value >= 0x7F { throw Refused("Only printable ASCII is allowed.") }
        }
        let words = try split(text)
        switch words.first {
        case "describe" where words.count == 1: return .describe
        case "run": return .run(Array(words.dropFirst()))
        default: throw Refused("Say run or describe.")
        }
    }

    private static func split(_ s: Substring) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            switch c {
            case " ", "\t":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                guard let end = s[s.index(after: i)...].firstIndex(of: "'") else { throw Refused("A quote is not closed.") }
                current += s[s.index(after: i)..<end]
                i = end
            case "\"":
                inWord = true
                var j = s.index(after: i)
                var closed = false
                while j < s.endIndex {
                    let d = s[j]
                    if d == "\"" { closed = true; break }
                    if d == "\\", s.index(after: j) < s.endIndex, "\"\\".contains(s[s.index(after: j)]) {
                        j = s.index(after: j)
                        current.append(s[j])
                    } else {
                        current.append(d)
                    }
                    j = s.index(after: j)
                }
                guard closed else { throw Refused("A quote is not closed.") }
                i = j
            default:
                inWord = true
                current.append(c)
            }
            i = s.index(after: i)
        }
        if inWord { words.append(current) }
        return words
    }

    /// The program's arguments for `values`: the fixed ones, then the
    /// values, each checked against its argument's pattern (whole value).
    func arguments(for values: [String]) throws -> [String] {
        guard values.count <= arguments.count else {
            throw Refused("\(name) takes at most \(arguments.count) value\(arguments.count == 1 ? "" : "s").")
        }
        for (i, a) in arguments.enumerated() {
            guard i < values.count else {
                if a.required { throw Refused("\(a.name) is required.") }
                continue
            }
            let v = values[i]
            guard v.utf8.count <= Self.maxValueBytes else { throw Refused("\(a.name) is longer than 1 KB.") }
            switch Self.match(v, a.pattern) {
            case .yes: break
            case .no: throw Refused("\(a.name) “\(v)” does not match \(a.pattern).")
            case .tooLong: throw Refused("\(a.name) took too long to check against \(a.pattern).")
            }
        }
        return fixedArguments + values
    }

    /// A value is at most this long (patterns are for arguments, not documents).
    static let maxValueBytes = 1 << 10
    /// How long one value may take to check: a pattern that backtracks
    /// without end (`^(a+)+$`) gives up instead of holding MonadHost.
    static let matchSeconds: TimeInterval = 0.25

    private enum Match { case yes, no, tooLong }

    /// The whole value against the pattern. ICU calls the block now and then
    /// while it works (`reportProgress`), which is where a long match stops.
    private static func match(_ value: String, _ pattern: String) -> Match {
        guard isPrintableASCII(value), let re = try? NSRegularExpression(pattern: pattern) else { return .no }
        let whole = NSRange(value.startIndex..., in: value)
        let deadline = Date().addingTimeInterval(matchSeconds)
        var found: NSRange?
        var late = false
        re.enumerateMatches(in: value, options: [.anchored, .reportProgress], range: whole) { m, _, stop in
            if let m {
                found = m.range
                stop.pointee = true
            } else if Date() > deadline {
                late = true
                stop.pointee = true
            }
        }
        if late { return .tooLong }
        return found == whole ? .yes : .no
    }

    /// `describe`: one JSON line with what an agent needs (not the program,
    /// its fixed arguments or environment).
    var describe: String {
        struct Out: Encodable {
            struct Arg: Encodable { let name, pattern: String; let required: Bool; let summary: String }
            let name, summary: String
            let arguments: [Arg]
            let timeoutSeconds: Int
            let results: Bool
        }
        let out = Out(name: name, summary: summary,
                      arguments: arguments.map { .init(name: $0.name, pattern: $0.pattern, required: $0.required, summary: $0.summary) },
                      timeoutSeconds: timeoutSeconds, results: results)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? enc.encode(out)) ?? Data("{}".utf8), as: UTF8.self)
    }

    // MARK: Decoding (fields added later stay optional)

    enum CodingKeys: String, CodingKey {
        case id, name, summary, program, fixedArguments, arguments, workingDirectory, timeoutSeconds, results,
             environment, guestPort, guestSocket, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        program = try c.decode(String.self, forKey: .program)
        fixedArguments = try c.decodeIfPresent([String].self, forKey: .fixedArguments) ?? []
        arguments = try c.decodeIfPresent([Argument].self, forKey: .arguments) ?? []
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 3600
        results = try c.decodeIfPresent(Bool.self, forKey: .results) ?? true
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        guestPort = try c.decodeIfPresent(Int.self, forKey: .guestPort)
        guestSocket = try c.decodeIfPresent(String.self, forKey: .guestSocket)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

extension HostCommand.Argument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pattern = try c.decode(String.self, forKey: .pattern)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}
