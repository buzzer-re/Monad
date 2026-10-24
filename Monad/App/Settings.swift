//
//  Settings.swift — user preferences backed by UserDefaults.
//

import AppKit

extension Notification.Name {
    static let monadSettingsChanged = Notification.Name("dev.monad.settingsChanged")
}

enum SettingsKey {
    static let fontSize = "fontSize"
    static let optionAsMeta = "optionAsMeta"
    static let allowOSC52 = "allowOSC52"
    static let scrollbackLines = "scrollbackLines"
    static let cursorBlink = "cursorBlink"
    static let defaultCPUs = VMDefaults.cpusKey
    static let defaultMemoryGiB = VMDefaults.memoryKey
    static let defaultDiskGiB = VMDefaults.diskKey
}

enum Settings {
    static func registerDefaults() {
        VMDefaults.register()
        UserDefaults.standard.register(defaults: [
            SettingsKey.fontSize: 13.0,
            SettingsKey.optionAsMeta: true,
            SettingsKey.allowOSC52: true,
            SettingsKey.scrollbackLines: 10_000,
            SettingsKey.cursorBlink: false,
        ])
    }

    static var fontSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: SettingsKey.fontSize)
        return CGFloat(min(max(v, 8), 36))
    }

    static func setFontSize(_ size: CGFloat) {
        UserDefaults.standard.set(Double(min(max(size, 8), 36)), forKey: SettingsKey.fontSize)
        NotificationCenter.default.post(name: .monadSettingsChanged, object: nil)
    }

    static var optionAsMeta: Bool { UserDefaults.standard.bool(forKey: SettingsKey.optionAsMeta) }
    static var allowOSC52: Bool { UserDefaults.standard.bool(forKey: SettingsKey.allowOSC52) }
    static var cursorBlink: Bool { UserDefaults.standard.bool(forKey: SettingsKey.cursorBlink) }
    static var scrollbackLines: Int {
        min(max(UserDefaults.standard.integer(forKey: SettingsKey.scrollbackLines), 0), 200_000)
    }
}
