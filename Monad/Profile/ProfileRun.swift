//
//  ProfileRun.swift — one profile being set up in a VM, as the VM's page and
//  tab show it: each step's state, the reason a step failed, and the last
//  lines the script printed. Built from the script's output, line by line.
//

import Foundation

struct ProfileRun: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case waiting, running, done, failed }

    struct Step: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var state: State
    }

    /// Output lines kept (the latest), and the longest kept line.
    static let logLines = 40
    static let maxLineLength = 300

    var profile: String
    var name: String
    var state: State = .waiting
    var steps: [Step]
    /// Why it failed.
    var message: String?
    var log: [String] = []

    init(profile: ProfileConfig) {
        self.profile = profile.id
        name = profile.name
        steps = profile.steps.map { Step(id: $0.id, title: $0.title, state: .waiting) }
    }

    /// The step running now, for one-line progress ("Node.js LTS, 2 of 3").
    var current: (index: Int, step: Step)? {
        steps.firstIndex { $0.state == .running }.map { ($0, steps[$0]) }
    }

    mutating func apply(_ line: String) {
        guard let p = ProfileProgress.parse(line) else {
            log.append(String(line.prefix(Self.maxLineLength)))
            if log.count > Self.logLines { log.removeFirst(log.count - Self.logLines) }
            return
        }
        func set(_ id: String, _ s: State) -> Bool {
            guard let i = steps.firstIndex(where: { $0.id == id }) else { return false }
            steps[i].state = s
            return true
        }
        switch p {
        case .started(let id):
            if set(id, .running) { state = .running }
        case .finished(let id):
            _ = set(id, .done)
        case .failed(let id, let reason):
            if set(id, .failed) {
                state = .failed
                message = reason
            }
        case .allDone:
            if state != .failed { state = .done }
        case .pid:
            break // the runner's business
        }
    }

    /// The script ended with `status`: anything short of every step done is
    /// a failure.
    mutating func finish(status: Int32) {
        guard state != .failed else { return }
        let finished = state == .done
        if finished && status == 0 { return }
        state = .failed
        message = finished ? "The setup ended with status \(status)." : "The setup ended early (status \(status))."
        for i in steps.indices where steps[i].state == .running { steps[i].state = .failed }
    }

    /// It could not be run at all.
    mutating func fail(_ reason: String) {
        state = .failed
        message = reason
    }
}

/// The whole output of a profile's latest run, in the VM's folder (the page
/// keeps only the last lines): private to the user, and bounded.
struct ProfileLogFile {
    static let defaultLimit = 4 << 20
    let url: URL
    let limit: Int
    private var handle: FileHandle?
    private var written = 0
    private var full = false

    init(url: URL, limit: Int = defaultLimit) {
        self.url = url
        self.limit = limit
    }

    /// A new run: the file starts empty.
    mutating func start() {
        close()
        written = 0
        full = false
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { return }
        handle = try? FileHandle(forWritingTo: url)
    }

    mutating func append(_ line: String) {
        guard let handle, !full else { return }
        let data = Data((line + "\n").utf8)
        guard written + data.count <= limit else {
            full = true
            try? handle.write(contentsOf: Data("[The log stops here: it reached its size limit.]\n".utf8))
            return
        }
        try? handle.write(contentsOf: data)
        written += data.count
    }

    mutating func close() {
        try? handle?.close()
        handle = nil
    }
}

/// The profiles a VM has finished setting up (profiles.json in its folder):
/// they are not run again at boot.
struct AppliedProfiles: Codable, Equatable {
    var applied: [String: Date] = [:]

    static func load(_ url: URL) -> AppliedProfiles {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AppliedProfiles.self, from: $0) } ?? AppliedProfiles()
    }

    func save(_ url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// One line about a VM's profiles, for the banner over its tab: the one being
/// set up, else the one waiting, else how the last one ended.
struct ProfileBanner: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case working, done, failed }

    let text: String
    let kind: Kind
    /// While it works: the latest line the script printed.
    var detail: String? = nil

    static func of(_ runs: [ProfileRun]) -> ProfileBanner? {
        if let run = runs.first(where: { $0.state == .running }) {
            guard let (i, step) = run.current else {
                return ProfileBanner(text: "Setting up \(run.name)", kind: .working, detail: run.log.last)
            }
            return ProfileBanner(text: "Setting up \(run.name): \(step.title) (\(i + 1) of \(run.steps.count))",
                                 kind: .working, detail: run.log.last)
        }
        if let run = runs.first(where: { $0.state == .waiting }) {
            return ProfileBanner(text: "\(run.name): waiting to start", kind: .working)
        }
        guard let last = runs.last else { return nil }
        if last.state == .done { return ProfileBanner(text: "\(last.name) is set up.", kind: .done) }
        return ProfileBanner(text: "\(last.name) could not be set up: \(last.message ?? "unknown reason")", kind: .failed)
    }
}
