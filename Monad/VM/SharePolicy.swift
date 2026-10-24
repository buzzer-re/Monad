//
//  SharePolicy.swift — which Mac folders a VM may get (F-14), judged by where
//  a path really leads (links resolved). MonadHost checks every share it is
//  sent and stores the resolved path; Monad's window asks the user first
//  where a share needs it and marks the share as confirmed.
//
//  Never: Monad's own folder or anything in it (keys, settings, every VM's
//  disk), nor the other build's (release or debug), a writable share
//  holding one, and a folder above the home folder ("/", "/Users"). With the
//  user's word: the home folder itself, read-only, which reaches the VM as
//  its visible folders only (homeFolders: no dot folder, no ~/Library), and
//  anything outside it, ~/.ssh and ~/Library.
//

import Foundation

enum SharePolicy {
    struct Places: Equatable {
        var home: String
        var monad: String
        /// The other builds' folders (Flavor), guarded the same way.
        var others: [String] = []
        static var mac: Places {
            Places(home: Paths.home.path, monad: Paths.root.path,
                   others: Flavor.allDataFolders.filter { $0 != Flavor.current.dataFolder }
                       .map { Paths.home.appendingPathComponent($0).path })
        }
    }

    enum Verdict: Equatable {
        case fine
        case needsConfirmation
        case refused(String)
    }

    /// `path` as resolved by `resolve`.
    static func verdict(_ path: String, readOnly: Bool, places: Places) -> Verdict {
        let home = resolve(places.home)
        for monad in ([places.monad] + places.others).map(resolve) {
            if inside(path, monad) {
                return .refused("“\(path)” is Monad's own folder. A VM must not see its keys and settings.")
            }
            if !readOnly && inside(monad, path) {
                return .refused("“\(path)” holds Monad's own folder (\(monad)), so it can only be shared read-only.")
            }
            if inside(monad, path) && path != home {
                return .refused("“\(path)” holds Monad's own folder deeper than Monad can leave it out. "
                                + "Share your home folder, or folders in it, instead.")
            }
        }
        for sensitive in [".ssh", "Library"] where inside(path, home + "/" + sensitive) { return .needsConfirmation }
        if path == home || !inside(path, home) { return .needsConfirmation }
        return .fine
    }

    /// A share of the home folder as the VM gets it: one share per visible
    /// folder in it (not a dot folder, not ~/Library, not a link), each at
    /// the same place under the share's guest path. Loose files at the top
    /// of the home folder are not shared; a folder made later comes at the
    /// VM's next start.
    static func homeFolders(_ share: SharedFolder, home: String) -> [SharedFolder] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.sorted().compactMap { name -> SharedFolder? in
            guard !name.hasPrefix("."), name != "Library" else { return nil }
            let path = home + "/" + name
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeDirectory else { return nil }
            let guest = share.guestPath.hasSuffix("/") ? share.guestPath + name : share.guestPath + "/" + name
            return SharedFolder(hostPath: path, guestPath: guest, readOnly: share.readOnly, confirmed: share.confirmed)
        }
    }

    /// Where a path really leads: absolute, without "." or "..", links resolved.
    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// MonadHost, on create and update: every share resolved and checked.
    /// `known`: host paths the VM already had (accepted before, by an older
    /// Monad that did not mark confirmations).
    static func apply(_ config: inout InstanceConfig, places: Places, known: Set<String> = []) throws {
        for i in config.sharing.shares.indices {
            var share = config.sharing.shares[i]
            guard share.hostPath.hasPrefix("/") else { continue } // validate() says why
            share.hostPath = resolve(share.hostPath)
            switch verdict(share.hostPath, readOnly: share.readOnly, places: places) {
            case .fine: break
            case .refused(let why): throw MonadError(why)
            case .needsConfirmation:
                guard share.confirmed == true || known.contains(share.hostPath) else {
                    throw MonadError("Sharing “\(share.hostPath)” needs your confirmation in Monad's VM settings.")
                }
            }
            config.sharing.shares[i] = share
        }
    }

    /// At load: a file changed outside Monad must not share what is never allowed.
    static func checkStored(_ config: InstanceConfig, places: Places) throws {
        for share in config.sharing.shares where share.hostPath.hasPrefix("/") {
            if case .refused(let why) = verdict(resolve(share.hostPath), readOnly: share.readOnly, places: places) {
                throw MonadError(why)
            }
        }
    }

    static func inside(_ path: String, _ dir: String) -> Bool {
        path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }
}
