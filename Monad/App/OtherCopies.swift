//
//  OtherCopies.swift — one copy of Monad per flavor. Each copy points
//  launchd at the MonadHost inside its own bundle when it cannot reach the
//  one running; two copies of different builds then take turns replacing it,
//  and each turn powers off every VM (seen with two Debug copies, a VM shut
//  down every half minute, 2026-11-01). So the newest copy asks the older
//  ones to quit. Quitting an app leaves its VMs running: MonadHost keeps them.
//

import AppKit
import os

struct RunningCopy: Equatable {
    let pid: pid_t
    let launched: Date?
}

enum OtherCopies {
    /// The copies `me` asks to quit: the ones launched before it (the lower
    /// pid when in the same instant). A copy without a launch date is left
    /// alone, and leaves the others alone.
    static func toQuit(_ copies: [RunningCopy], me: pid_t) -> [pid_t] {
        guard let mine = copies.first(where: { $0.pid == me })?.launched else { return [] }
        return copies.compactMap { other in
            guard other.pid != me, let theirs = other.launched else { return nil }
            return theirs < mine || (theirs == mine && other.pid < me) ? other.pid : nil
        }
    }

    /// Asks the older copies of this flavor (same bundle identifier) to quit.
    @MainActor
    static func quitOlder(log: DebugLog = .shared) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        let me = ProcessInfo.processInfo.processIdentifier
        let older = Set(toQuit(apps.map { RunningCopy(pid: $0.processIdentifier, launched: $0.launchDate) }, me: me))
        for app in apps where older.contains(app.processIdentifier) {
            let path = app.bundleURL?.path ?? "?"
            let asked = app.terminate()
            let text = "another copy of Monad was running (pid \(app.processIdentifier), \(path)): "
                + (asked ? "asked it to quit" : "it could not be asked to quit")
                + "; two copies replace each other's VM service, which stops its VMs"
            Log.app.notice("\(text, privacy: .public)")
            log.log("app", text)
        }
    }
}
