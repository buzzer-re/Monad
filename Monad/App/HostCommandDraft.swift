//
//  HostCommandDraft.swift — the form behind the VM window's Add Host
//  Command…: text fields in, a HostCommand out, each problem in the user's
//  words (HostCommand.problem), and what the VM can then do, asked before
//  it is added.
//

import Foundation

struct HostCommandDraft: Equatable {
    struct ArgumentRow: Equatable, Identifiable {
        var id = UUID()
        var name = ""
        var pattern = "^$"
        var required = true
        var summary = ""
    }

    var name = ""
    var summary = ""
    /// The program, by full path (or a name found on `searchPath`).
    var program = ""
    /// Arguments always passed first, separated by spaces.
    var fixedArguments = ""
    var arguments: [ArgumentRow] = []
    var workingDirectory = ""
    var timeoutMinutes = 60
    var results = true
    /// "NAME=value" lines.
    var environment = "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    var usesSocket = false
    var guestPort = ""
    var guestSocket = ""

    /// A draft for a VM: working in its first shared folder.
    init(shares: [SharedFolder] = []) {
        workingDirectory = shares.first?.hostPath ?? ""
    }

    /// The command, if its fields make one, and otherwise why not.
    func command(shares: [SharedFolder], searchPath: String = HostCommandDraft.searchPath) -> (HostCommand?, String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (nil, "Give it a name: the tool's name for agents.") }
        guard let resolved = VMSettingsDraft.resolveProgram(program, path: searchPath) else {
            return (nil, program.trimmingCharacters(in: .whitespaces).isEmpty ? "Which program?" : "No program by that name.")
        }
        var env: [String: String] = [:]
        for line in environment.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let eq = text.firstIndex(of: "="), eq != text.startIndex else {
                return (nil, "“\(text)” is not NAME=value.")
            }
            env[String(text[..<eq])] = String(text[text.index(after: eq)...])
        }
        let command = HostCommand(
            name: trimmed, summary: summary.trimmingCharacters(in: .whitespaces), program: resolved,
            fixedArguments: VMSettingsDraft.arguments(fixedArguments),
            arguments: arguments.map { .init(name: $0.name.trimmingCharacters(in: .whitespaces),
                                             pattern: $0.pattern.trimmingCharacters(in: .whitespaces),
                                             required: $0.required, summary: $0.summary.trimmingCharacters(in: .whitespaces)) },
            workingDirectory: workingDirectory.trimmingCharacters(in: .whitespaces),
            timeoutSeconds: timeoutMinutes * 60, results: results, environment: env,
            guestPort: usesSocket ? nil : Int(guestPort.trimmingCharacters(in: .whitespaces)) ?? -1,
            guestSocket: usesSocket ? guestSocket.trimmingCharacters(in: .whitespaces) : nil)
        if let why = command.problem(shares: shares) { return (nil, why) }
        return (command, nil)
    }

    /// Where a program typed by name is looked for (GUI apps get a short PATH).
    static let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        + ":/opt/homebrew/bin:/usr/local/bin"

    /// Asked before it is added: the program, what the VM varies and how,
    /// and the patterns that let anything through.
    static func confirmation(for command: HostCommand) -> String {
        var text = "The VM will be able to run “\(([command.program] + command.fixedArguments).joined(separator: " "))” "
            + "on this Mac, as you, in \(command.workingDirectory)"
        if command.arguments.isEmpty {
            text += ", with no values of its own."
        } else {
            text += ", adding " + command.arguments.map { "\($0.name) (\($0.pattern))" }.joined(separator: ", ") + "."
        }
        text += " One run at a time, ended after \(Self.duration(command.timeoutSeconds))."
        for warning in command.warnings { text += " " + warning }
        return text
    }

    static func duration(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return seconds == 3600 ? "1 hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return "\(seconds) seconds"
    }
}
