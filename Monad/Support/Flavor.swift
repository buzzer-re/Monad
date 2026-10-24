//
//  Flavor.swift — Release and Debug builds side by side. Each has its own
//  MonadHost (launchd label and Mach service), bundle identifiers, data
//  folder and log subsystem, so a Debug build from Xcode never touches the
//  Monad in use, its VMs or its files. The bundle identifiers are also set
//  per configuration in the project (FlavorTests checks they match).
//

import Foundation

enum Flavor {
    struct Names: Equatable {
        let hostLabel: String
        let appIdentifier: String
        let hostIdentifier: String
        /// Under the home folder.
        let dataFolder: String
        let logSubsystem: String
    }

    static func names(debug: Bool) -> Names {
        debug
            ? Names(hostLabel: "dev.monad.debug.host", appIdentifier: "dev.monad.Monad.debug",
                    hostIdentifier: "dev.monad.MonadHost.debug", dataFolder: ".monad-debug", logSubsystem: "dev.monad.debug")
            : Names(hostLabel: "dev.monad.host", appIdentifier: "dev.monad.Monad",
                    hostIdentifier: "dev.monad.MonadHost", dataFolder: ".monad", logSubsystem: "dev.monad")
    }

    #if DEBUG
        static let isDebug = true
    #else
        static let isDebug = false
    #endif

    static let current = names(debug: isDebug)

    /// Every flavor's data folder: none is ever shared into a VM.
    static let allDataFolders = [false, true].map { names(debug: $0).dataFolder }

    /// About Monad's build line: the flavor, when it was built and the start
    /// of its build id, as the logs print it ("release, built 2026-10-09
    /// 23:30, FA2769A0").
    static func aboutVersion(debug: Bool, built: Date?, build: String?) -> String {
        var text = debug ? "debug" : "release"
        if let built {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            text += ", built " + f.string(from: built)
        }
        if let build { text += ", " + build.prefix(8) }
        return text
    }

    /// This build's line: built when its executable was written.
    static var currentAboutVersion: String {
        let built = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return aboutVersion(debug: isDebug, built: built, build: HostBuild.current)
    }
}
