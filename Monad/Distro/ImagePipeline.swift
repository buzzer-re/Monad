//
//  ImagePipeline.swift — from a distro configuration to a verified raw base
//  disk that new VMs are cloned from. Generic: every step is selected by the
//  distro's configuration (see DistroConfig.swift).
//
//    1. find the checksum file (fixed URL, or a directory listing + glob)
//    2. check its signature with the distro's pinned keys (or note that the
//       distro publishes checksums over HTTPS only)
//    3. pick the image entry by glob; reuse a cached base with that digest
//    4. otherwise take a local copy with the same digest (Debug builds: the
//       Lima download cache) or download it, and check the digest
//    5. convert (qcow2 → raw, raw, tar.xz → member) into the cache, read-only
//
//  Without network access the newest cached base of the release is used.
//

import CryptoKit
import Foundation
import os

// MARK: - Fetching

enum ImageFetchError: Error, Equatable, LocalizedError {
    case http(Int, URL)
    case tooLarge(URL, Int)

    var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "Downloading \(url.absoluteString) failed with HTTP \(code)."
        case .tooLarge(let url, let limit): return "\(url.absoluteString) is larger than \(limit) bytes."
        }
    }
}

protocol ImageFetching: Sendable {
    /// A small file (checksums, signature, listing), at most `limit` bytes.
    func data(from url: URL, limit: Int, staysOnSite: Bool) async throws -> Data
    /// A large file, written to `file`.
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    /// Whether a large file is there, without downloading it.
    func reachable(_ url: URL) async throws
}

struct URLSessionFetcher: ImageFetching {
    /// Whether a redirect from `from` stays on its site: HTTPS (or plain
    /// http from a plain http address, a mirror the user chose), and the
    /// same host or another under its domain (its last two labels:
    /// cloud.debian.org → cdimage.debian.org).
    static func staysOnSite(from: URL, to: URL) -> Bool {
        let scheme = to.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && from.scheme?.lowercased() == "http"),
              let a = from.host?.lowercased(), let b = to.host?.lowercased() else {
            return false
        }
        let site = a.split(separator: ".").suffix(2).joined(separator: ".")
        return b == site || b.hasSuffix("." + site)
    }

    func data(from url: URL, limit: Int, staysOnSite: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let guardian: URLSessionTaskDelegate? = staysOnSite ? SiteGuard(origin: url) : nil
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: guardian)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ImageFetchError.http(http.statusCode, url) }
        if response.expectedContentLength > Int64(limit) { throw ImageFetchError.tooLarge(url, limit) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw ImageFetchError.tooLarge(url, limit) }
        }
        return data
    }

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await Downloader.download(url, to: file, progress: progress)
    }

    func reachable(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession.shared.data(for: request)
        // A server that does not answer HEAD (405, 501) may still serve it.
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode),
           http.statusCode != 405, http.statusCode != 501 {
            throw ImageFetchError.http(http.statusCode, url)
        }
    }
}

/// Refuses redirects off the site (the 3xx is then the answer, and fails).
private final class SiteGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let to = request.url, URLSessionFetcher.staysOnSite(from: origin, to: to) else {
            Log.image.error("refused a redirect from \(self.origin.absoluteString, privacy: .public) to \(request.url?.absoluteString ?? "?", privacy: .public)")
            return completionHandler(nil)
        }
        completionHandler(request)
    }
}

/// URLSession download with byte progress, moved to a destination file.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReport = Date.distantPast

    private init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(_ url: URL, to dst: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let d = Downloader(destination: dst, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            d.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns: move it now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = ImageFetchError.http(http.statusCode, downloadTask.originalRequest?.url ?? destination)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = continuation
        continuation = nil
        if let error = error ?? moveError { cont?.resume(throwing: error) } else { cont?.resume() }
    }
}

// MARK: - Local copies (development)

/// Files on this Mac that might be a published image (only ever read).
protocol LocalImageSource: Sendable {
    func candidates(named file: String) -> [URL]
}

#if DEBUG
    /// Lima's download cache (by-url-sha256/<hash>/{url,data}). Debug builds
    /// only: a development shortcut on slow connections. A candidate is used
    /// only if its digest matches the verified checksum entry.
    struct LimaCacheSource: LocalImageSource {
        var root = Paths.home.appendingPathComponent("Library/Caches/lima/download/by-url-sha256")

        func candidates(named file: String) -> [URL] {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return dirs.compactMap { dir in
                guard let url = try? String(contentsOf: dir.appendingPathComponent("url"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    URL(string: url)?.lastPathComponent == file else { return nil }
                let data = dir.appendingPathComponent("data")
                return FileManager.default.fileExists(atPath: data.path) ? data : nil
            }
        }
    }
#endif

// MARK: - Results

struct BaseImage: Codable, Equatable, Sendable {
    enum Verification: Codable, Equatable, Sendable {
        /// The checksum file was signed by this pinned key.
        case signature(fingerprint: String)
        /// The distro publishes no signature; checksums came over HTTPS.
        case checksumOverHTTPS
        /// An image by its link alone (a distro the user added): nothing to
        /// check it against.
        case unverified
    }

    let url: URL
    /// Human-readable, e.g. "Ubuntu 26.04 LTS".
    let name: String
    let distro: String
    let release: String
    /// Digest of the published file the disk was made from.
    let digest: String
    let verification: Verification
}

enum FileDigest {
    static func hex(of url: URL, algorithm: ChecksumFile.Algorithm) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var s256 = SHA256(), s512 = SHA512()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
            if algorithm == .sha256 { s256.update(data: chunk) } else { s512.update(data: chunk) }
        }
        let bytes = algorithm == .sha256 ? Array(s256.finalize()) : Array(s512.finalize())
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Pipeline

final class ImagePipeline: @unchecked Sendable {
    typealias Progress = @Sendable (_ message: String) -> Void

    enum Problem: Error, Equatable, LocalizedError {
        case unknownDistro(String)
        case catalog(String)
        case digestMismatch(file: String)
        case conversion(String)

        var errorDescription: String? {
            switch self {
            case .unknownDistro(let d): return "Monad does not know a distribution called \(d)."
            case .catalog(let m): return "The distribution list could not be loaded: \(m)"
            case .digestMismatch(let f): return "\(f) does not match its published checksum, so it was deleted."
            case .conversion(let m): return "Preparing the disk image failed: \(m)"
            }
        }
    }

    static let smallFileLimit = 1 << 20
    static let signatureLimit = 64 << 10
    static let xzMemoryLimit: UInt64 = 256 << 20

    /// Read for each image: a distro added meanwhile is there.
    private let catalog: @Sendable () -> Result<DistroCatalog, Error>
    private let cache: URL
    private let fetcher: ImageFetching
    private let hostArch: String
    private let localSources: [LocalImageSource]
    private let now: @Sendable () -> Date
    /// Where the latest macOS restore image is (Apple, through Virtualization).
    private let macRestore: MacRestoreSource
    private let lock = NSLock()
    private var inFlight: [String: Task<BaseImage, Error>] = [:]

    init(catalog: DistroCatalog, cache: URL, fetcher: ImageFetching, hostArch: String,
         localSources: [LocalImageSource], now: @escaping @Sendable () -> Date = Date.init,
         macRestore: MacRestoreSource = NoMacRestore()) {
        self.catalog = { .success(catalog) }
        self.cache = cache
        self.fetcher = fetcher
        self.hostArch = hostArch
        self.localSources = localSources
        self.now = now
        self.macRestore = macRestore
    }

    private init(source: @escaping @Sendable () -> Result<DistroCatalog, Error>, cache: URL, fetcher: ImageFetching,
                 hostArch: String, localSources: [LocalImageSource], macRestore: MacRestoreSource) {
        self.catalog = source
        self.cache = cache
        self.fetcher = fetcher
        self.hostArch = hostArch
        self.localSources = localSources
        self.now = Date.init
        self.macRestore = macRestore
    }

    static var hostArchitecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }

    /// The bundled catalog, the user's image cache and the network.
    static let live: ImagePipeline = {
        var local: [LocalImageSource] = []
        #if DEBUG
            local.append(LimaCacheSource())
        #endif
        return ImagePipeline(source: {
            DistroCatalog.live.map { .success($0) } ?? .failure(DistroConfig.Invalid("the bundled distro catalog is invalid"))
        }, cache: Paths.imageCache, fetcher: URLSessionFetcher(), hostArch: hostArchitecture, localSources: local,
           macRestore: AppleRestoreSource())
    }()

    /// What Settings' Check found: the image a VM would use, from a checksum
    /// file whose signature was verified. The image is not downloaded.
    struct Found: Equatable, Sendable {
        let file: String
        let imageURL: URL
        let digest: String
        let verification: BaseImage.Verification
    }

    /// Fetch and verify `config`'s checksum file and find its image, as a
    /// download would, without downloading the image.
    func check(distro config: DistroConfig, release releaseID: String? = nil) async throws -> Found {
        let catalog: DistroCatalog
        switch self.catalog() {
        case .success(let c): catalog = c
        case .failure(let e): throw Problem.catalog(e.localizedDescription)
        }
        if config.guestOS == .macos {
            // Apple's latest, or the restore image's own address or file.
            let url: URL
            if config.image.url == DistroConfig.appleLatest {
                url = try await macRestore.latest().url
            } else {
                guard let u = URL(string: config.image.url) else { throw MonadError("Not a restore image: \(config.image.url).") }
                url = u.isFileURL ? URL(fileURLWithPath: u.path) : u
                if url.isFileURL { _ = try Self.localImage(url) } else { try await fetcher.reachable(url) }
            }
            return Found(file: url.lastPathComponent, imageURL: url, digest: "", verification: .unverified)
        }
        let arch = config.architectures[hostArch] != nil ? hostArch : "arm64"
        let plan = try config.plan(release: releaseID ?? config.defaultRelease.id, hostArch: arch)
        if case .direct(let url) = plan.checksums {
            if url.isFileURL { _ = try Self.localImage(url) } else { try await fetcher.reachable(url) }
            return Found(file: url.lastPathComponent, imageURL: url, digest: "", verification: .unverified)
        }
        let checked = try await fetchChecksums(plan, keys: { try catalog.trustedKeys(for: config) })
        let entry = try ChecksumFile(text: checked.text, format: plan.checksumFormat, algorithm: plan.algorithm)
            .entry(matching: plan.filePattern)
        return Found(file: entry.file, imageURL: try plan.imageURL(file: entry.file, checksums: checked.url),
                     digest: entry.digest, verification: checked.verification)
    }

    /// The raw base disk for `distro` (`release` nil: the default release).
    /// Concurrent callers for the same release share one preparation.
    func baseImage(distro: String, release: String?, progress: @escaping Progress) async throws -> BaseImage {
        let key = "\(distro)/\(release ?? "")"
        let task: Task<BaseImage, Error> = lock.withLock {
            if let t = inFlight[key] { return t }
            let t = Task.detached(priority: .userInitiated) { [self] in
                try await self.prepare(distro: distro, release: release, progress: progress)
            }
            inFlight[key] = t
            return t
        }
        defer { lock.withLock { if inFlight[key] == task { inFlight[key] = nil } } }
        return try await task.value
    }

    // MARK: Steps

    private func prepare(distro id: String, release releaseID: String?, progress: @escaping Progress) async throws -> BaseImage {
        let catalog: DistroCatalog
        switch self.catalog() {
        case .success(let c): catalog = c
        case .failure(let e): throw Problem.catalog(e.localizedDescription)
        }
        guard let config = catalog.distro(id) else { throw Problem.unknownDistro(id) }
        let release = try releaseID.flatMap { rid in
            try config.releases.first { $0.id == rid } ?? { throw DistroConfig.Invalid("\(config.name) has no release \(rid).") }()
        } ?? config.defaultRelease
        if config.guestOS == .macos { return try await prepareRestoreImage(config, release: release, progress: progress) }
        let plan = try config.plan(release: release.id, hostArch: hostArch)
        try Paths.ensurePrivateDirectory(cache)
        if case .direct(let url) = plan.checksums {
            return try await prepareDirect(url, plan: plan, release: release, progress: progress)
        }

        progress("Checking \(release.name) checksums…")
        let checked: (url: URL, text: String, verification: BaseImage.Verification)
        do {
            checked = try await fetchChecksums(plan, keys: { try catalog.trustedKeys(for: config) })
        } catch where Self.isOffline(error) {
            if let cached = newestCached(plan) {
                progress("Offline — using the cached \(cached.name)")
                Log.image.notice("offline: using cached \(cached.url.lastPathComponent, privacy: .public)")
                return cached
            }
            throw error
        }
        let entry = try ChecksumFile(text: checked.text, format: plan.checksumFormat, algorithm: plan.algorithm)
            .entry(matching: plan.filePattern)
        let stem = "\(plan.distro)-\(plan.release)-\(plan.arch)-\(entry.digest.prefix(16))"
        let rawURL = cache.appendingPathComponent(stem + ".raw")
        let metaURL = cache.appendingPathComponent(stem + ".json")
        let result = BaseImage(url: rawURL, name: release.name, distro: plan.distro, release: plan.release,
                               digest: entry.digest, verification: checked.verification)
        if FileManager.default.fileExists(atPath: rawURL.path), let meta = try? loadMeta(metaURL), meta.digest == entry.digest {
            return result
        }

        let downloads = cache.appendingPathComponent("downloads", isDirectory: true)
        try Paths.ensurePrivateDirectory(downloads)
        var source: URL?
        var ownsSource = false
        for local in localSources {
            for candidate in local.candidates(named: entry.file) {
                progress("Checking local copy of \(entry.file)…")
                if (try? FileDigest.hex(of: candidate, algorithm: plan.algorithm)) == entry.digest {
                    Log.image.notice("using local copy \(candidate.path, privacy: .public)")
                    source = candidate
                    break
                }
            }
            if source != nil { break }
        }
        if source == nil {
            let url = try plan.imageURL(file: entry.file, checksums: checked.url)
            let part = downloads.appendingPathComponent(stem + ".download")
            try? FileManager.default.removeItem(at: part)
            let name = release.name
            try await fetcher.download(url, to: part) { done, total in
                let mb = Double(done) / 1_048_576
                if total > 0 {
                    progress(String(format: "Downloading %@ — %.0f%% (%.0f MB)", name, Double(done) / Double(total) * 100, mb))
                } else {
                    progress(String(format: "Downloading %@ — %.0f MB", name, mb))
                }
            }
            progress("Verifying \(entry.file)…")
            guard (try? FileDigest.hex(of: part, algorithm: plan.algorithm)) == entry.digest else {
                try? FileManager.default.removeItem(at: part)
                throw Problem.digestMismatch(file: entry.file)
            }
            source = part
            ownsSource = true
        }
        guard let source else { throw Problem.conversion("no source") }
        defer { if ownsSource { try? FileManager.default.removeItem(at: source) } }
        try await finish(source, plan: plan, release: release, stem: stem, result: result, progress: progress)
        return result
    }

    /// An image by its link alone: downloaded (or read where it is on this
    /// Mac) as it is, once; its digest recorded. A file on this Mac that
    /// changes is read again.
    private func prepareDirect(_ url: URL, plan: DistroConfig.Plan, release: DistroConfig.Release,
                               progress: @escaping Progress) async throws -> BaseImage {
        var key = url.absoluteString
        if url.isFileURL {
            let (size, modified) = try Self.localImage(url)
            key += " \(size) \(modified.timeIntervalSince1970)"
        }
        let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let stem = "\(plan.distro)-\(plan.release)-\(plan.arch)-link-\(id)"
        let rawURL = cache.appendingPathComponent(stem + ".raw")
        if FileManager.default.fileExists(atPath: rawURL.path),
           let meta = try? loadMeta(cache.appendingPathComponent(stem + ".json")) {
            return meta
        }
        let downloads = cache.appendingPathComponent("downloads", isDirectory: true)
        try Paths.ensurePrivateDirectory(downloads)
        var source = url.resolvingSymlinksInPath()
        var ownsSource = false
        if !url.isFileURL {
            let part = downloads.appendingPathComponent(stem + ".download")
            try? FileManager.default.removeItem(at: part)
            let name = release.name
            try await fetcher.download(url, to: part) { done, total in
                let mb = Double(done) / 1_048_576
                if total > 0 {
                    progress(String(format: "Downloading %@ — %.0f%% (%.0f MB)", name, Double(done) / Double(total) * 100, mb))
                } else {
                    progress(String(format: "Downloading %@ — %.0f MB", name, mb))
                }
            }
            source = part
            ownsSource = true
        }
        defer { if ownsSource { try? FileManager.default.removeItem(at: source) } }
        progress("Reading \(url.lastPathComponent)…")
        let digest = try FileDigest.hex(of: source, algorithm: .sha256)
        let result = BaseImage(url: rawURL, name: release.name, distro: plan.distro, release: plan.release,
                               digest: digest, verification: .unverified)
        try await finish(source, plan: plan, release: release, stem: stem, result: result, progress: progress)
        return result
    }

    /// A disk image on this Mac: a file (a link to one is followed), its
    /// size and when it changed.
    // MARK: macOS restore images

    /// Kept restore images: `<cache>/macos/<Apple's file name>.ipsw`.
    private var restoreCache: URL { Self.restoreCache(in: cache) }
    static func restoreCache(in cache: URL) -> URL { cache.appendingPathComponent("macos", isDirectory: true) }

    struct RestoreImageFile: Equatable, Sendable {
        let file: String
        let bytes: Int64
    }

    /// The restore images kept here (Settings › Distributions › macOS).
    func restoreImages() -> [RestoreImageFile] { Self.restoreImages(in: cache) }

    static func restoreImages(in cache: URL = Paths.imageCache) -> [RestoreImageFile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: restoreCache(in: cache),
                                                                  includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "ipsw" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            RestoreImageFile(file: $0.lastPathComponent,
                             bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
    }

    /// Frees a kept restore image (VMs installed from it do not need it).
    func removeRestoreImage(_ file: String) throws { try Self.removeRestoreImage(file, in: cache) }

    static func removeRestoreImage(_ file: String, in cache: URL = Paths.imageCache) throws {
        guard ChecksumFile.isSafeFileName(file), file.hasSuffix(".ipsw"),
              restoreImages(in: cache).contains(where: { $0.file == file }) else {
            throw MonadError("There is no kept macOS restore image called \(file).")
        }
        try FileManager.default.removeItem(at: restoreCache(in: cache).appendingPathComponent(file))
    }

    /// The restore image for `config`: the latest for this Mac (downloaded
    /// once, kept), or one by its link (the same) or file (used where it is).
    /// Offline, the latest falls back to the newest one kept.
    private func prepareRestoreImage(_ config: DistroConfig, release: DistroConfig.Release,
                                     progress: @escaping Progress) async throws -> BaseImage {
        try Paths.ensurePrivateDirectory(restoreCache)
        var link: URL
        var build = release.id, version = ""
        if config.image.url == DistroConfig.appleLatest {
            progress("Asking Apple for the latest macOS for this Mac…")
            do {
                let latest = try await macRestore.latest()
                link = latest.url
                build = latest.build
                version = latest.version
            } catch {
                guard let kept = restoreImages().last else {
                    throw MonadError("Monad could not reach Apple to find the latest macOS (\(error.localizedDescription)), "
                        + "and no macOS restore image is kept on this Mac. Try again online, or choose an IPSW file.")
                }
                let url = restoreCache.appendingPathComponent(kept.file)
                return BaseImage(url: url, name: "macOS (\(kept.file))", distro: config.id, release: release.id,
                                 digest: "", verification: .unverified)
            }
        } else {
            guard let url = URL(string: config.image.url) else { throw MonadError("Not a restore image: \(config.image.url).") }
            link = url
        }
        if link.isFileURL {
            return try Self.restoreImageFile(URL(fileURLWithPath: link.path), distro: config.id, release: release.id)
        }
        let name = ChecksumFile.isSafeFileName(link.lastPathComponent) && link.pathExtension == "ipsw"
            ? link.lastPathComponent : "macOS-\(build).ipsw"
        let kept = restoreCache.appendingPathComponent(name)
        let title = version.isEmpty ? "macOS (\(name))" : "macOS \(version) (\(build))"
        if !FileManager.default.fileExists(atPath: kept.path) {
            let part = restoreCache.appendingPathComponent(name + ".download")
            try? FileManager.default.removeItem(at: part)
            try await fetcher.download(link, to: part) { done, total in
                let gb = Double(done) / 1_073_741_824
                if total > 0 {
                    progress(String(format: "Downloading %@ — %.0f%% (%.1f GB)", title, Double(done) / Double(total) * 100, gb))
                } else {
                    progress(String(format: "Downloading %@ — %.1f GB", title, gb))
                }
            }
            try FileManager.default.moveItem(at: part, to: kept)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kept.path)
        }
        return BaseImage(url: kept, name: title, distro: config.id, release: build, digest: "", verification: .unverified)
    }

    /// A restore image file on this Mac, used where it is.
    static func restoreImageFile(_ file: URL, distro: String, release: String) throws -> BaseImage {
        _ = try localImage(file)
        return BaseImage(url: file, name: "macOS (\(file.lastPathComponent))", distro: distro, release: release,
                         digest: "", verification: .unverified)
    }

    static func localImage(_ url: URL) throws -> (size: UInt64, modified: Date) {
        let path = url.resolvingSymlinksInPath().path
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              a[.type] as? FileAttributeType == .typeRegular else {
            throw MonadError("\(url.lastPathComponent) is not there (\(url.path)).")
        }
        return ((a[.size] as? NSNumber)?.uint64Value ?? 0, a[.modificationDate] as? Date ?? .distantPast)
    }

    /// The source converted into the cache as `result.url`, read-only, with
    /// its record beside it.
    private func finish(_ source: URL, plan: DistroConfig.Plan, release: DistroConfig.Release, stem: String,
                        result: BaseImage, progress: @escaping Progress) async throws {
        let rawURL = result.url
        let metaURL = cache.appendingPathComponent(stem + ".json")
        let downloads = cache.appendingPathComponent("downloads", isDirectory: true)
        try Paths.ensurePrivateDirectory(downloads)
        var image = source
        if let compression = plan.compression {
            progress("Unpacking \(release.name)…")
            image = downloads.appendingPathComponent(stem + ".unpacked")
            try await Self.unpack(source, compression, to: image) { done, total in
                progress(String(format: "Unpacking %@ — %.0f%%", release.name, Double(done) / Double(max(total, 1)) * 100))
            }
        }
        defer { if image != source { try? FileManager.default.removeItem(at: image) } }
        progress("Preparing \(release.name) disk…")
        let raw = downloads.appendingPathComponent(stem + ".raw.part")
        try? FileManager.default.removeItem(at: raw)
        do {
            try await Self.convert(image, format: plan.format, member: plan.member, to: raw) { done, total in
                progress(String(format: "Preparing %@ disk — %.0f%%", release.name, Double(done) / Double(max(total, 1)) * 100))
            }
            try? FileManager.default.removeItem(at: rawURL)
            try FileManager.default.moveItem(at: raw, to: rawURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: rawURL.path)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(result).write(to: metaURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: raw)
            throw error
        }
        Log.image.notice("prepared \(rawURL.lastPathComponent, privacy: .public)")
    }

    /// The form's Simple view: next to an image, a checksum file that lists
    /// it (the names in the folder's listing that look like one, then the
    /// usual names) and that file's signature. Nothing found, or a file on
    /// this Mac: nothing to check it against. Read only to fill in the form;
    /// a download verifies everything again.
    func discover(_ link: ImageLink) async -> ImageDiscovery {
        guard !link.isLocal else { return ImageDiscovery(checksums: nil) }
        let listing = try? await fetcher.data(from: link.directory, limit: Self.smallFileLimit, staysOnSite: true)
        for candidate in link.checksumCandidates(listing: listing.map { String(decoding: $0, as: UTF8.self) }) {
            guard let data = try? await fetcher.data(from: candidate, limit: Self.smallFileLimit, staysOnSite: true) else {
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            guard let layout = ImageDiscovery.layout(of: text), layout.file.entries.contains(where: { $0.file == link.file }) else {
                continue
            }
            var found = ImageDiscovery.Checksums(url: candidate, format: layout.format, algorithm: layout.algorithm,
                                                 signature: .none, signatureURL: nil)
            if text.contains("-----BEGIN PGP SIGNED MESSAGE-----") {
                found.signature = .clearsigned
                return ImageDiscovery(checksums: found)
            }
            for suffix in ImageLink.signatureSuffixes {
                guard let sig = URL(string: candidate.absoluteString + suffix) else { continue }
                if (try? await fetcher.data(from: sig, limit: Self.signatureLimit, staysOnSite: false)) != nil {
                    found.signature = .detached
                    found.signatureURL = sig
                    break
                }
            }
            return ImageDiscovery(checksums: found)
        }
        return ImageDiscovery(checksums: nil)
    }

    /// The checksum file as it is, not verified: Settings' form reads it to
    /// learn its layout and the images it lists, then checks it for real.
    func peek(distro config: DistroConfig) async throws -> String {
        let arch = config.architectures[hostArch] != nil ? hostArch : "arm64"
        let plan = try config.plan(release: config.defaultRelease.id, hostArch: arch)
        return String(decoding: try await checksumFile(plan).data, as: UTF8.self)
    }

    private func checksumFile(_ plan: DistroConfig.Plan) async throws -> (url: URL, data: Data) {
        // Checksums only HTTPS vouches for come from their own site; signed
        // ones may come from any mirror.
        let onSite = plan.signature == .none
        let url: URL
        switch plan.checksums {
        case .url(let u):
            url = u
        case .index(let dir, let pattern):
            let listing = try await fetcher.data(from: dir, limit: Self.smallFileLimit, staysOnSite: onSite)
            url = dir.appendingPathComponent(try DirectoryIndex.file(in: String(decoding: listing, as: UTF8.self),
                                                                     matching: pattern))
        case .direct:
            throw DistroConfig.Invalid("\(plan.distro) has no checksum file")
        }
        return (url, try await fetcher.data(from: url, limit: Self.smallFileLimit, staysOnSite: onSite))
    }

    private func fetchChecksums(_ plan: DistroConfig.Plan, keys: () throws -> [OpenPGPKey]) async throws
        -> (url: URL, text: String, verification: BaseImage.Verification) {
        let (url, data) = try await checksumFile(plan)
        switch plan.signature {
        case .detached:
            guard let sigURL = try plan.signatureURL(checksums: url) else { throw DistroConfig.Invalid("no signature URL") }
            let sig = try await fetcher.data(from: sigURL, limit: Self.signatureLimit, staysOnSite: false)
            let v = try OpenPGP.verifyDetached(data, signature: sig, keys: try keys(), now: now())
            try checkFreshness(plan, signed: v.created)
            return (url, String(decoding: data, as: UTF8.self), .signature(fingerprint: v.primaryFingerprint))
        case .clearsigned:
            let (text, v) = try OpenPGP.verifyClearsigned(data, keys: try keys(), now: now())
            try checkFreshness(plan, signed: v.created)
            return (url, text, .signature(fingerprint: v.primaryFingerprint))
        case .none:
            return (url, String(decoding: data, as: UTF8.self), .checksumOverHTTPS)
        }
    }

    /// A validly signed but older checksum file (a stale or hostile mirror
    /// serving an old release with its old image) is refused once a newer one
    /// was seen for that distro and release; the newest date is kept in the
    /// cache.
    private func checkFreshness(_ plan: DistroConfig.Plan, signed: Date) throws {
        let file = cache.appendingPathComponent("signature-dates.json")
        let key = "\(plan.distro) \(plan.release)"
        try lock.withLock {
            var seen = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: file))) ?? [:]
            if let newest = seen[key], signed < newest {
                let f = ISO8601DateFormatter()
                throw MonadError("The signed checksum file for \(plan.distro) \(plan.release) is older (signed \(f.string(from: signed))) "
                                 + "than one Monad saw before (\(f.string(from: newest))). A mirror may be serving an old "
                                 + "release. Nothing was downloaded.")
            }
            guard seen[key].map({ signed > $0 }) ?? true else { return }
            seen[key] = signed
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try JSONEncoder().encode(seen).write(to: file, options: .atomic)
        }
    }

    // MARK: Cache

    private func loadMeta(_ url: URL) throws -> BaseImage {
        try JSONDecoder().decode(BaseImage.self, from: Data(contentsOf: url))
    }

    /// The most recently prepared base for this distro, release and arch.
    private func newestCached(_ plan: DistroConfig.Plan) -> BaseImage? {
        let prefix = "\(plan.distro)-\(plan.release)-\(plan.arch)-"
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .compactMap { url -> (Date, BaseImage)? in
                guard let meta = try? loadMeta(url), FileManager.default.fileExists(atPath: meta.url.path) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (date, meta)
            }
            .max { $0.0 < $1.0 }?.1
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff].contains(e.code)
    }

    // MARK: Conversion

    /// Throttled progress sink passed through C callback contexts.
    private final class ProgressSink: @unchecked Sendable {
        let report: @Sendable (UInt64, UInt64) -> Void
        var last = Date.distantPast
        init(_ report: @escaping @Sendable (UInt64, UInt64) -> Void) { self.report = report }

        func tick(_ done: UInt64, _ total: UInt64) {
            let t = Date()
            if t.timeIntervalSince(last) > 0.25 || done == total {
                last = t
                report(done, total)
            }
        }
    }

    /// A compressed image (.xz, .gz) into `dst`, holes kept.
    static func unpack(_ src: URL, _ compression: DistroConfig.Compression, to dst: URL,
                       progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let sink = ProgressSink(progress)
                let ctx = Unmanaged.passRetained(sink).toOpaque()
                defer { Unmanaged<ProgressSink>.fromOpaque(ctx).release() }
                let kind = compression == .xz ? Int32(MND_UNPACK_XZ) : Int32(MND_UNPACK_GZIP)
                let rc = mnd_unpack(src.path, dst.path, kind, xzMemoryLimit, { ctx, done, total in
                    if let ctx { Unmanaged<ProgressSink>.fromOpaque(ctx).takeUnretainedValue().tick(done, total) }
                    return true
                }, ctx)
                if rc == 0 { cont.resume() } else {
                    let what = compression == .xz ? ".xz" : ".gz"
                    cont.resume(throwing: Problem.conversion("unpacking the \(what) image: \(String(cString: mnd_unpack_last_error()))"))
                }
            }
        }
    }

    /// Starts with qcow2's magic, "QFI\xfb".
    static func isQcow2(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x51, 0x46, 0x49, 0xFB])
    }

    static func convert(_ src: URL, format: DistroConfig.ImageFormat, member: String?, to dst: URL,
                        progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let sink = ProgressSink(progress)
                let ctx = Unmanaged.passRetained(sink).toOpaque()
                defer { Unmanaged<ProgressSink>.fromOpaque(ctx).release() }
                // A ".img" said to be qcow2 may be a raw disk: look.
                switch format == .qcow2 && !Self.isQcow2(src) ? .raw : format {
                case .qcow2:
                    let rc = mnd_qcow2_to_raw(src.path, dst.path, { ctx, done, total in
                        if let ctx { Unmanaged<ProgressSink>.fromOpaque(ctx).takeUnretainedValue().tick(done, total) }
                        return true
                    }, ctx)
                    if rc == 0 { cont.resume() } else {
                        cont.resume(throwing: Problem.conversion(String(cString: mnd_qcow2_last_error())))
                    }
                case .ipsw:
                    cont.resume(throwing: Problem.conversion("a macOS restore image is not a disk"))
                case .raw:
                    let rc = mnd_disk_clone(src.path, dst.path)
                    if rc == 0 { cont.resume() } else {
                        cont.resume(throwing: Problem.conversion(String(cString: strerror(rc))))
                    }
                case .tarXz:
                    let fd = open(src.path, O_RDONLY | O_CLOEXEC)
                    guard fd >= 0 else {
                        cont.resume(throwing: Problem.conversion(String(cString: strerror(errno))))
                        return
                    }
                    defer { close(fd) }
                    guard let xz = mnd_xz_file_open(fd, xzMemoryLimit) else {
                        cont.resume(throwing: Problem.conversion("out of memory"))
                        return
                    }
                    defer { mnd_xz_file_close(xz) }
                    var size: UInt64 = 0
                    let rc = mnd_tar_extract({ ctx, buf, n in
                        let r = mnd_xz_file_read(OpaquePointer(ctx), buf, n)
                        return r < 0 ? -1 : r
                    }, UnsafeMutableRawPointer(xz), member ?? "", dst.path, { ctx, done, total in
                        if let ctx { Unmanaged<ProgressSink>.fromOpaque(ctx).takeUnretainedValue().tick(done, total) }
                        return true
                    }, ctx, &size)
                    if rc == 0 {
                        cont.resume()
                    } else {
                        let xzError = String(cString: mnd_xz_file_error(xz))
                        let detail = xzError.isEmpty ? String(cString: mnd_tar_last_error()) : xzError
                        cont.resume(throwing: Problem.conversion(detail))
                    }
                }
            }
        }
    }
}
