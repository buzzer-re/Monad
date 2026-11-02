//
//  AppUpdater.swift — the app's side of updates (AppUpdate.swift): once a
//  day, while Settings › Updates › Check for updates is on, and whenever the
//  user picks Monad › Check for Updates, it asks GitHub for the latest
//  release. A newer one is installed only when the user says so: it is
//  downloaded and checked, monad-update.sh is started, Monad quits, and the
//  script swaps the new copy in and opens it. VMs keep running in MonadHost
//  throughout. The Debug flavor never updates itself (Xcode builds it).
//

import AppKit

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    /// The Release flavor only.
    let isAvailable = !Flavor.isDebug
    private(set) var isBusy = false
    private let fetcher: ReleaseFetching = GitHubFetcher()
    private var timer: Timer?
    private var progress: NSWindow?

    /// Checks shortly after launch, then each hour whether a day has passed.
    func start() {
        guard isAvailable, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AppUpdater.shared.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.checkIfDue() }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: SettingsKey.lastUpdateCheck) as? Date
        guard Settings.checkForUpdates, UpdateCheck.isDue(last: last, now: Date()) else { return }
        check(byUser: false)
    }

    /// Monad › Check for Updates (`byUser`), or the daily check, which says
    /// nothing unless there is a newer release.
    func check(byUser: Bool) {
        guard isAvailable else { return }
        guard !isBusy else {
            if byUser { NSApp.activate(ignoringOtherApps: true); progress?.makeKeyAndOrderFront(nil) }
            return
        }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            let release: AppRelease?
            do {
                let landed = try await fetcher.landing(of: UpdateCheck.releases.appendingPathComponent("latest"))
                UserDefaults.standard.set(Date(), forKey: SettingsKey.lastUpdateCheck)
                release = UpdateCheck.release(landed: landed)
            } catch {
                DebugLog.shared.log("update", "cannot check for updates: \(error.localizedDescription)")
                if byUser { tell("Cannot check for updates", "Monad could not reach GitHub: \(error.localizedDescription)") }
                return
            }
            guard let current = AppVersion.current else { return }
            guard let release, release.isNewer(than: current) else {
                DebugLog.shared.log("update", "Monad \(current) is up to date (latest release: \(release?.tag ?? "none"))")
                if byUser {
                    tell("Monad is up to date", release == nil ? "No release of Monad is published yet."
                        : "You have Monad \(current), the latest release.")
                }
                return
            }
            DebugLog.shared.log("update", "Monad \(release.version) is available (this is \(current))")
            guard ask(release, current: current) else { return }
            do {
                try await install(release)
            } catch {
                progress?.close()
                progress = nil
                DebugLog.shared.log("update", "update to \(release.version) failed: \(error.localizedDescription)")
                tell("Monad was not updated", error.localizedDescription)
            }
        }
    }

    private func ask(_ release: AppRelease, current: AppVersion) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Monad \(release.version) is available"
        alert.informativeText = "You have Monad \(current). Update now? Monad downloads it, checks it against the release's "
            + "SHA-256 and its signature, then quits and opens the new version. Your VMs keep running."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page); return false
        default: return false
        }
    }

    private func install(_ release: AppRelease) async throws {
        let dest = Bundle.main.bundleURL
        if let why = UpdateCheck.cannotReplace(dest) { throw UpdateError(why) }
        showProgress("Downloading Monad \(release.version)…")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("monad-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let app = try await UpdateDownload(fetcher: fetcher, runner: SystemCommandRunner(), work: work,
                                               appIdentifier: Flavor.current.appIdentifier).fetch(release)
            guard let script = Bundle.main.url(forResource: "monad-update", withExtension: "sh") else {
                throw UpdateError("This copy of Monad has no monad-update.sh.")
            }
            let command = try UpdateDownload.swapCommand(script: script, work: work, app: app, dest: dest,
                                                         pid: ProcessInfo.processInfo.processIdentifier)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: command.executable)
            p.arguments = command.arguments
            p.standardInput = FileHandle.nullDevice
            if let log = Self.scriptLog() {
                p.standardOutput = log
                p.standardError = log
            }
            try p.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        DebugLog.shared.log("update", "Monad \(release.version) checked; quitting so monad-update.sh puts it in \(dest.path)")
        NSApp.terminate(nil)
    }

    /// Where monad-update.sh says what it did (next to the debug logs).
    private static func scriptLog() -> FileHandle? {
        let file = Paths.logs.appendingPathComponent("monad-update.log")
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: file) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }

    private func showProgress(_ text: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: text)
        let stack = NSStackView(views: [spinner, label])
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 24)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Updating Monad"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        progress = window
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
