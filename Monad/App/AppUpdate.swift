//
//  AppUpdate.swift — Monad › Check for Updates: which GitHub release is the
//  latest, whether it is newer than this Monad, and the download made ready
//  to install. A download is used only when it matches the release's
//  SHA-256, holds Monad's Release build (bundle id) of that version, and its
//  signature still holds: the checks scripts/install.sh makes. monad-update.sh
//  then swaps it in once this copy has quit. AppUpdater asks the user.
//

import CryptoKit
import Foundation

/// A release's version: up to four numbers joined by dots ("1.2", "v1.2.3").
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let numbers: [Int]

    init?(_ text: String) {
        let s = text.hasPrefix("v") ? Substring(text.dropFirst()) : Substring(text)
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 9, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            numbers.append(n)
        }
        self.numbers = numbers
    }

    /// This Monad's version (CFBundleShortVersionString).
    static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    var text: String { numbers.map(String.init).joined(separator: ".") }
    var description: String { text }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// A published release: its tag, page and the two files install.sh uses too.
struct AppRelease: Equatable, Sendable {
    let tag: String
    let version: AppVersion
    let page: URL
    let zip: URL
    let checksum: URL

    func isNewer(than current: AppVersion) -> Bool { current < version }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum UpdateCheck {
    /// Monad's releases; `latest` there lands on the latest one's page.
    static let releases = URL(string: "https://github.com/buzzer-re/Monad/releases")!
    /// How often Monad checks by itself.
    static let interval: TimeInterval = 24 * 3600

    /// The release whose page `/latest` landed on: …/releases/tag/v<version>
    /// on the same site and repository, over https. nil when it landed
    /// anywhere else (no release published yet lands on …/releases).
    static func release(landed: URL, releases: URL = releases) -> AppRelease? {
        guard landed.scheme == "https", releases.scheme == "https", landed.host == releases.host,
              landed.port == nil, landed.query == nil, landed.fragment == nil, landed.user == nil else { return nil }
        let prefix = releases.path + "/tag/"
        guard landed.path.hasPrefix(prefix) else { return nil }
        let tag = String(landed.path.dropFirst(prefix.count))
        guard tag.hasPrefix("v"), let version = AppVersion(tag) else { return nil }
        let download = releases.appendingPathComponent("download").appendingPathComponent(tag)
        return AppRelease(tag: tag, version: version, page: landed,
                          zip: download.appendingPathComponent("Monad.zip"),
                          checksum: download.appendingPathComponent("Monad.zip.sha256"))
    }

    /// A check is due a day after the last one (or when the clock went back).
    static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || last > now
    }

    /// Why the copy at `app` cannot be replaced in place (nil: it can).
    static func cannotReplace(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "Monad runs from a temporary copy macOS made of it. Move Monad to your Applications folder, open it from there, and check again."
        }
        let folder = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else {
            return "Monad cannot write to \(folder). An administrator account can, or install it with scripts/install.sh --dest ~/Applications."
        }
        return nil
    }
}

/// Where releases come from (GitHub; a fake in tests).
protocol ReleaseFetching: Sendable {
    /// Where `url` lands after its redirects.
    func landing(of url: URL) async throws -> URL
    /// `url`'s body, saved at `file`.
    func download(_ url: URL, to file: URL) async throws
}

struct GitHubFetcher: ReleaseFetching {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: c)
    }()

    func landing(of url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await Self.session.data(for: request)
        try Self.check(response, url)
        return response.url ?? url
    }

    func download(_ url: URL, to file: URL) async throws {
        let (temporary, response) = try await Self.session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.check(response, url)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private static func check(_ response: URLResponse, _ url: URL) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError("\(url.host ?? "GitHub") answered \(code) for \(url.lastPathComponent)")
        }
        guard response.url?.scheme ?? "https" == "https" else { throw UpdateError("\(url.lastPathComponent) was not served over https") }
    }
}

/// A release downloaded into `work` and checked, ready for monad-update.sh.
struct UpdateDownload {
    let fetcher: ReleaseFetching
    let runner: CommandRunning
    let work: URL
    /// The bundle id the update must have (this flavor's).
    let appIdentifier: String

    /// The checked Monad.app, unpacked in `work`.
    func fetch(_ release: AppRelease) async throws -> URL {
        let zip = work.appendingPathComponent("Monad.zip")
        let sums = work.appendingPathComponent("Monad.zip.sha256")
        for (url, file) in [(release.zip, zip), (release.checksum, sums)] {
            do {
                try await fetcher.download(url, to: file)
            } catch {
                throw UpdateError("Cannot download \(url.lastPathComponent) of Monad \(release.version): \(error.localizedDescription)")
            }
        }
        guard let want = Self.hash(inChecksumFile: sums) else {
            throw UpdateError("Monad.zip.sha256 of Monad \(release.version) holds no SHA-256: not installed.")
        }
        let got = try Self.sha256(of: zip)
        guard got == want else {
            throw UpdateError("Monad.zip does not match its SHA-256 (got \(got), the release says \(want)): not installed.")
        }

        let unpacked = work.appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        let r = try await runner.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 300)
        guard r.status == 0 else { throw UpdateError("Cannot unpack Monad.zip: \(r.stderrString.plain(limit: 200))") }
        let app = unpacked.appendingPathComponent("Monad.app")
        let info = (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        guard let info else { throw UpdateError("Monad.zip of Monad \(release.version) holds no Monad.app: not installed.") }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == appIdentifier else {
            throw UpdateError("The update is not Monad's Release build (bundle id '\(id.plain(limit: 200))', not \(appIdentifier)): not installed.")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard AppVersion(version) == release.version else {
            throw UpdateError("Monad.zip of \(release.tag) holds Monad \(version.plain(limit: 200)): not installed.")
        }
        let sign = try await runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 300)
        guard sign.status == 0 else {
            throw UpdateError("The update's signature does not hold (\(sign.stderrString.plain(limit: 200))): not installed.")
        }
        return app
    }

    /// monad-update.sh, run from a copy in `work`: the bundle it came in is
    /// the one it replaces.
    static func swapCommand(script: URL, work: URL, app: URL, dest: URL, pid: pid_t) throws
        -> (executable: String, arguments: [String]) {
        let copy = work.appendingPathComponent("monad-update.sh")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: script, to: copy)
        return ("/bin/sh", [copy.path, String(pid), app.path, dest.path, work.path])
    }

    /// The first word of a .sha256 file, when it is a SHA-256 (lowercased).
    static func hash(inChecksumFile file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        guard let word = head.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first else { return nil }
        let hash = word.lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return hash
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
