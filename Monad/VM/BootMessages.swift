//
//  BootMessages.swift — Settings › Virtual Machines › Full boot messages:
//  what a Linux VM's console (its boot tab, serial.log) shows while it
//  boots. Quiet by default: only the errors of the kernel, systemd and the
//  services, so a boot that works shows next to nothing and one that fails
//  still says why. Full is every message. Guest/monad-console.sh sets it in
//  the guest, for the guest's next boot.
//
//  The choice is a small file the app writes and MonadHost reads at each
//  boot; a Darwin notification tells a running MonadHost to set it at once
//  in the VMs that run.
//

import Foundation

enum BootMessages: String, Equatable {
    case quiet, full

    /// Per flavor: a Debug build's choice is nothing to the Release MonadHost.
    static func notification(debug: Bool) -> String {
        Flavor.names(debug: debug).hostLabel + ".boot-messages.changed"
    }

    static let changedNotification = notification(debug: Flavor.isDebug)

    private struct Setting: Codable { var full: Bool }

    static func load(settings: URL = Paths.bootMessagesSettings) -> BootMessages {
        (try? JSONDecoder().decode(Setting.self, from: Data(contentsOf: settings)))?.full == true ? .full : .quiet
    }

    /// Saves the choice (Settings) and tells MonadHost.
    static func save(_ messages: BootMessages, settings: URL = Paths.bootMessagesSettings,
                     notification: String = changedNotification) throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Setting(full: messages == .full)).write(to: settings, options: .atomic)
        notify_post(notification)
    }

    /// Calls `changed` on the main actor each time the choice is saved; nil
    /// when the notification cannot be watched.
    @discardableResult
    static func watch(notification: String = changedNotification,
                      _ changed: @escaping @MainActor () -> Void) -> Int32? {
        var token: Int32 = -1
        let status = notify_register_dispatch(notification, &token, DispatchQueue.main) { _ in
            MainActor.assumeIsolated { changed() }
        }
        return status == NOTIFY_STATUS_OK ? token : nil
    }
}
