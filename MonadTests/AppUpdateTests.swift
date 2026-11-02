//
//  AppUpdateTests.swift — Check for updates: which GitHub release is newer
//  than this Monad, and that a download is installed only once it matches
//  its SHA-256, holds Monad's Release build of that version and its
//  signature holds (what scripts/install.sh checks too).
//

import CryptoKit
import XCTest
@testable import Monad

final class AppUpdateTests: XCTestCase {
    private let releases = URL(string: "https://github.com/buzzer-re/Monad/releases")!

    // MARK: Versions

    func testVersionsCompareNumberByNumber() throws {
        func v(_ s: String) throws -> AppVersion { try XCTUnwrap(AppVersion(s), s) }
        XCTAssertLessThan(try v("1.9"), try v("1.10"))
        XCTAssertLessThan(try v("v1.0"), try v("1.0.1"))
        XCTAssertLessThan(try v("1.2.3"), try v("2"))
        XCTAssertEqual(try v("1.0"), try v("v1.0.0"))
        XCTAssertEqual(try v("v1.2").text, "1.2")
        XCTAssertFalse(try v("1.1") < v("1.1"))
    }

    func testOnlyPlainVersionsAreRead() {
        for bad in ["", "v", "1.", ".1", "1..2", "1.x", "-1", "1.0-beta", "1.0 ", " 1.0", "１.０", "v1.0/x",
                    "99999999999999999999", String(repeating: "1.", count: 20) + "1"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    // MARK: Checking

    func testTheLatestReleaseIsWhereGitHubLands() throws {
        let landed = URL(string: "https://github.com/buzzer-re/Monad/releases/tag/v1.2")!
        let r = try XCTUnwrap(UpdateCheck.release(landed: landed, releases: releases))
        XCTAssertEqual(r.tag, "v1.2")
        XCTAssertEqual(r.version, AppVersion("1.2"))
        XCTAssertEqual(r.page, landed)
        XCTAssertEqual(r.zip.absoluteString, "https://github.com/buzzer-re/Monad/releases/download/v1.2/Monad.zip")
        XCTAssertEqual(r.checksum.absoluteString, "https://github.com/buzzer-re/Monad/releases/download/v1.2/Monad.zip.sha256")
    }

    func testALandingElsewhereIsNoRelease() {
        for s in ["https://github.com/buzzer-re/Monad/releases",            // none published yet
                  "https://github.com/buzzer-re/Monad/releases/latest",
                  "http://github.com/buzzer-re/Monad/releases/tag/v1.2",     // not https
                  "https://example.com/buzzer-re/Monad/releases/tag/v1.2",   // another site
                  "https://github.com/someone/Monad/releases/tag/v1.2",      // another repository
                  "https://github.com/buzzer-re/Monad/releases/tag/v1.2/x",
                  "https://github.com/buzzer-re/Monad/releases/tag/nightly",
                  "https://github.com/buzzer-re/Monad/releases/tag/v1.2%2F..%2Fx"] {
            XCTAssertNil(UpdateCheck.release(landed: URL(string: s)!, releases: releases), s)
        }
    }

    func testOnlyANewerReleaseIsOffered() throws {
        let landed = URL(string: "https://github.com/buzzer-re/Monad/releases/tag/v1.2")!
        let r = try XCTUnwrap(UpdateCheck.release(landed: landed, releases: releases))
        XCTAssertTrue(r.isNewer(than: try XCTUnwrap(AppVersion("1.1.9"))))
        XCTAssertFalse(r.isNewer(than: try XCTUnwrap(AppVersion("1.2"))))
        XCTAssertFalse(r.isNewer(than: try XCTUnwrap(AppVersion("1.10"))))
    }

    func testACheckIsDueOnceADay() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(UpdateCheck.isDue(last: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(last: now.addingTimeInterval(-UpdateCheck.interval), now: now))
        // A clock set back does not stop the checks for good.
        XCTAssertTrue(UpdateCheck.isDue(last: now.addingTimeInterval(3 * UpdateCheck.interval), now: now))
    }

    func testCheckingForUpdatesIsOnByDefault() {
        XCTAssertEqual(Settings.defaults[SettingsKey.checkForUpdates] as? Bool, true)
    }

    func testOnlyACopyInAFolderItCanWriteIsReplaced() throws {
        let dir = TempDir()
        let app = dir.url.appendingPathComponent("Monad.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(UpdateCheck.cannotReplace(app))
        XCTAssertNotNil(UpdateCheck.cannotReplace(URL(fileURLWithPath:
            "/private/var/folders/xy/abc/T/AppTranslocation/0A1B/d/Monad.app")))
        XCTAssertNotNil(UpdateCheck.cannotReplace(URL(fileURLWithPath: "/System/Applications/Monad.app")))
    }

    // MARK: Downloading

    private let zip = Data("the release's zip".utf8)
    private var zipHash: String { SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined() }

    private func release(_ tag: String = "v1.2") throws -> AppRelease {
        try XCTUnwrap(UpdateCheck.release(landed: releases.appendingPathComponent("tag/\(tag)"), releases: releases))
    }

    /// A fetcher with the release's two files, and a runner whose ditto
    /// unpacks an app with this bundle id and version.
    private func fixture(checksum: String? = nil, id: String = "dev.monad.Monad", version: String = "1.2",
                         codesign: ProcessRunner.Result = .ok()) -> (FakeReleaseFetcher, FakeCommandRunner, TempDir) {
        let fetcher = FakeReleaseFetcher(files: ["Monad.zip": zip,
                                                 "Monad.zip.sha256": Data((checksum ?? "\(zipHash)  Monad.zip\n").utf8)])
        let runner = FakeCommandRunner { call in
            switch call.executable {
            case "/usr/bin/ditto":
                let contents = URL(fileURLWithPath: call.arguments.last!).appendingPathComponent("Monad.app/Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                return .ok()
            case "/usr/bin/codesign": return codesign
            default: return .fail(1, "unexpected")
            }
        }
        return (fetcher, runner, TempDir())
    }

    private func download(_ f: (FakeReleaseFetcher, FakeCommandRunner, TempDir), _ r: AppRelease) async throws -> URL {
        try await UpdateDownload(fetcher: f.0, runner: f.1, work: f.2.url, appIdentifier: "dev.monad.Monad").fetch(r)
    }

    func testAGoodReleaseIsDownloadedCheckedAndUnpacked() async throws {
        let f = fixture()
        let r = try release()
        let app = try await download(f, r)
        XCTAssertEqual(app, f.2.url.appendingPathComponent("unpacked/Monad.app"))
        XCTAssertEqual(f.0.asked, [r.zip, r.checksum])
        XCTAssertEqual(f.1.calls.map(\.executable), ["/usr/bin/ditto", "/usr/bin/codesign"])
        XCTAssertEqual(f.1.calls[0].arguments, ["-x", "-k", f.2.url.appendingPathComponent("Monad.zip").path,
                                                f.2.url.appendingPathComponent("unpacked").path])
        XCTAssertEqual(f.1.calls[1].arguments, ["--verify", "--deep", "--strict", app.path])
    }

    func testAZipThatDoesNotMatchItsSHA256IsNotUnpacked() async throws {
        let f = fixture(checksum: String(repeating: "0", count: 64) + "  Monad.zip\n")
        await assertRefused(try await download(f, try release()), saying: "SHA-256")
        XCTAssertTrue(f.1.calls.isEmpty)
    }

    func testAChecksumFileWithoutAHashIsRefused() async throws {
        for text in ["", "not a hash", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            let f = fixture(checksum: text)
            await assertRefused(try await download(f, try release()), saying: "SHA-256")
            XCTAssertTrue(f.1.calls.isEmpty, text)
        }
    }

    func testAnUppercaseHashIsReadToo() async throws {
        let f = fixture(checksum: zipHash.uppercased() + "\n")
        _ = try await download(f, try release())
    }

    func testAnotherAppInTheZipIsRefused() async throws {
        let f = fixture(id: "dev.monad.Monad.debug")
        await assertRefused(try await download(f, try release()), saying: "dev.monad.Monad.debug")
        XCTAssertEqual(f.1.calls.map(\.executable), ["/usr/bin/ditto"], "not even its signature is read")
    }

    func testAZipOfAnotherVersionIsRefused() async throws {
        let f = fixture(version: "1.1")
        await assertRefused(try await download(f, try release()), saying: "1.1")
    }

    func testAnAppWhoseSignatureDoesNotHoldIsRefused() async throws {
        let f = fixture(codesign: .fail(1, "a sealed resource is missing or invalid"))
        await assertRefused(try await download(f, try release()), saying: "signature")
    }

    func testAFailedDownloadSaysSo() async throws {
        let f = fixture()
        f.0.files["Monad.zip"] = nil
        await assertRefused(try await download(f, try release()), saying: "Monad.zip")
        XCTAssertTrue(f.1.calls.isEmpty)
    }

    // MARK: Installing

    func testTheSwapRunsFromTheWorkFolderOnceThisCopyQuits() throws {
        let work = TempDir()
        let script = try XCTUnwrap(Bundle.main.url(forResource: "monad-update", withExtension: "sh"))
        let app = work.url.appendingPathComponent("unpacked/Monad.app")
        let dest = URL(fileURLWithPath: "/Applications/Monad.app")
        let run = try UpdateDownload.swapCommand(script: script, work: work.url, app: app, dest: dest, pid: 4242)
        let copy = work.url.appendingPathComponent("monad-update.sh")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: script),
                       "run from a copy: the bundle it came in is about to be replaced")
        XCTAssertEqual(run.executable, "/bin/sh")
        XCTAssertEqual(run.arguments, [copy.path, "4242", app.path, dest.path, work.url.path])
    }

    private func assertRefused(_ body: @autoclosure () async throws -> URL, saying text: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("installed", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), "\(error.localizedDescription)", file: file, line: line)
        }
    }
}

/// The release's files by name; what was asked for, in order.
final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [String: Data]
    private var _asked: [URL] = []
    var landed: URL?

    init(files: [String: Data]) { _files = files }

    var files: [String: Data] {
        get { lock.withLock { _files } }
        set { lock.withLock { _files = newValue } }
    }
    var asked: [URL] { lock.withLock { _asked } }

    func landing(of url: URL) async throws -> URL {
        guard let landed else { throw URLError(.cannotConnectToHost) }
        return landed
    }

    func download(_ url: URL, to file: URL) async throws {
        let data = lock.withLock { () -> Data? in
            _asked.append(url)
            return _files[url.lastPathComponent]
        }
        guard let data else { throw URLError(.fileDoesNotExist) }
        try data.write(to: file)
    }
}
