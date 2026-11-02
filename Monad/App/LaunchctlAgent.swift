//
//  LaunchctlAgent.swift — loads MonadHost as a per-user launchd agent with
//  launchctl, from a generated plist. Used when Monad is signed ad hoc (no
//  Team ID, i.e. development builds): an SMAppService agent is pinned to the
//  code hash it was registered with, so a rebuilt MonadHost would be killed
//  at launch ("Launch Constraint Violation"). Team-signed builds use
//  SMAppService, whose constraint names the team and survives updates.
//

import Foundation

struct LaunchctlAgent {
    static let label = HostXPCSecurity.machServiceName
    /// Bootstraps before giving up, a little further apart each time.
    static let bootstrapTries = 4
    /// Looks, 0.25 s apart, for the old job to be gone after a bootout.
    static let goneChecks = 20

    let program: URL
    let directory: URL
    let uid: uid_t
    let runner: CommandRunning
    var clock: MonadClock = SystemClock()

    var plistURL: URL { directory.appendingPathComponent("\(Self.label).plist") }
    private var target: String { "gui/\(uid)/\(Self.label)" }

    func writePlist() throws {
        try Paths.ensurePrivateDirectory(directory)
        let plist: [String: Any] = [
            "Label": Self.label,
            "Program": program.path,
            "MachServices": [Self.label: true],
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    /// Load the job unless launchd already has it.
    func ensureLoaded() async throws {
        if try await loaded() { return }
        try await bootstrap()
    }

    /// Replace the job (a new MonadHost build), never while its MonadHost
    /// runs VMs: a bootout ends it and powers them off. "This app cannot
    /// reach it" does not mean "nothing runs there": another copy of Monad's
    /// host, or one an updated app no longer passes the check of (seen: two
    /// Debug copies taking turns, every VM shut down at each turn). Running
    /// alone says nothing: this app's own connections start it on demand.
    /// launchd takes the old job down in the background after a bootout, and
    /// a bootstrap before it is gone fails ("Bootstrap failed: 5: Input/output
    /// error"), which left no job at all.
    func reload(vmsRunning: Bool) async throws {
        let job = try await runner.run("/bin/launchctl", ["print", target], timeout: 10)
        if job.status == 0, Self.isRunning(job.stdoutString), vmsRunning {
            throw MonadError("MonadHost from another copy of Monad is still running, with its VMs. "
                             + "Quit that copy of Monad (or stop its VMs) and this one connects.")
        }
        _ = try await runner.run("/bin/launchctl", ["bootout", target], timeout: 20)
        for _ in 0..<Self.goneChecks {
            if try await !loaded() { break }
            await clock.sleep(seconds: 0.25)
        }
        try await bootstrap()
    }

    /// Whether a VM of this flavor runs: MonadHost keeps a mark in the
    /// folder of each VM whose machine runs (InstancePaths.runningMark).
    static func vmsRunning(in instances: URL = Paths.instances) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: instances.path)) ?? []
        return names.contains { FileManager.default.fileExists(atPath: InstancePaths(name: $0, root: instances).runningMark.path) }
    }

    /// Whether `launchctl print` says the job's process is up.
    static func isRunning(_ printed: String) -> Bool {
        printed.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "state = running" }
    }

    private func loaded() async throws -> Bool {
        try await runner.run("/bin/launchctl", ["print", target], timeout: 10).status == 0
    }

    /// Tried again while launchd may still be taking an old job down; a job
    /// loaded meanwhile (by another copy of Monad) is fine.
    private func bootstrap() async throws {
        try writePlist()
        var detail = ""
        for attempt in 1...Self.bootstrapTries {
            let r = try await runner.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path], timeout: 20)
            if r.status == 0 { return }
            detail = (r.stderrString + r.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty { detail = "status \(r.status)" }
            if try await loaded() { return }
            if attempt < Self.bootstrapTries { await clock.sleep(seconds: 0.5 * Double(attempt)) }
        }
        throw MonadError("launchctl could not load MonadHost: \(detail)")
    }
}
