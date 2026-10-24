//
//  SharePolicyTests.swift — which Mac folders a VM may get, judged by where
//  the path really leads (F-14).
//

import XCTest
@testable import Monad

final class SharePolicyTests: XCTestCase {
    private let places = SharePolicy.Places(home: "/Users/x", monad: "/Users/x/.monad")

    private func verdict(_ path: String, readOnly: Bool = true) -> SharePolicy.Verdict {
        SharePolicy.verdict(path, readOnly: readOnly, places: places)
    }

    func testMonadsOwnFilesAreNeverShared() {
        guard case .refused = verdict("/Users/x/.monad") else { return XCTFail("~/.monad") }
        guard case .refused = verdict("/Users/x/.monad/instances/dev", readOnly: false) else { return XCTFail("inside") }
        // A writable share holding ~/.monad would give the guest its files.
        guard case .refused = verdict("/Users/x", readOnly: false) else { return XCTFail("the home folder, writable") }
        guard case .refused = verdict("/", readOnly: false) else { return XCTFail("/, writable") }
    }

    /// The other build's folder (release or debug) is never shared either.
    func testNoMonadsFilesAreShared() {
        let both = SharePolicy.Places(home: "/Users/x", monad: "/Users/x/.monad-debug", others: ["/Users/x/.monad"])
        guard case .refused = SharePolicy.verdict("/Users/x/.monad/instances/web", readOnly: true, places: both) else {
            return XCTFail("the release build's VMs")
        }
        guard case .refused = SharePolicy.verdict("/Users/x/.monad-debug", readOnly: true, places: both) else {
            return XCTFail("its own")
        }
        XCTAssertEqual(SharePolicy.Places.mac.others.map { URL(fileURLWithPath: $0).lastPathComponent }, [".monad"],
                       "a debug build guards the release build's folder")
    }

    func testKeysTheWholeHomeAndOutsideItNeedTheUsersWord() {
        XCTAssertEqual(verdict("/Users/x"), .needsConfirmation)
        XCTAssertEqual(verdict("/Users/x/.ssh"), .needsConfirmation)
        XCTAssertEqual(verdict("/Users/x/.ssh", readOnly: false), .needsConfirmation)
        XCTAssertEqual(verdict("/Users/x/Library/Keychains"), .needsConfirmation)
        XCTAssertEqual(verdict("/etc"), .needsConfirmation)
        XCTAssertEqual(verdict("/Users/xy/src"), .needsConfirmation)
    }

    /// A folder above the home folder holds ~/.monad deeper than Monad can
    /// leave it out: refused, read-only too. The home folder itself is shared
    /// as its visible folders (`homeFolders`), so it stays possible.
    func testFoldersAboveTheHomeFolderAreRefused() {
        for path in ["/", "/Users"] {
            guard case .refused(let why) = verdict(path) else { return XCTFail(path) }
            XCTAssertTrue(why.contains("home folder"), why)
        }
        XCTAssertEqual(verdict("/Users/x"), .needsConfirmation)
    }

    /// The home folder reaches a VM as its visible folders: never ~/.monad,
    /// any other dot folder (~/.ssh, ~/.aws), ~/Library, loose files or links.
    func testTheHomeFolderIsSharedAsItsVisibleFolders() throws {
        let tmp = TempDir()
        let home = tmp.url.appendingPathComponent("home")
        let fm = FileManager.default
        for dir in [".monad/instances/dev", ".ssh", ".aws", "Library/Keychains", "Documents", "Projects/demo", "Creative Files"] {
            try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: home.appendingPathComponent(".zshrc"))
        try Data("x".utf8).write(to: home.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Elsewhere"), withDestinationURL: URL(fileURLWithPath: "/etc"))

        var c = InstanceConfig.defaults(name: "dev")
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [
            SharedFolder(hostPath: home.path, guestPath: "/mnt/home", readOnly: true, confirmed: true),
            SharedFolder(hostPath: home.appendingPathComponent("Projects").path, guestPath: "/src", readOnly: false),
        ])
        let shares = c.deviceShares(paths: InstancePaths(name: "dev", root: home.appendingPathComponent(".monad/instances")))
        let resolved = SharePolicy.resolve(home.path)
        XCTAssertEqual(shares.dropLast().map(\.guestPath),
                       ["/mnt/home/Creative Files", "/mnt/home/Documents", "/mnt/home/Projects", "/src"])
        XCTAssertEqual(shares.prefix(3).map(\.hostPath),
                       ["Creative Files", "Documents", "Projects"].map { resolved + "/" + $0 })
        XCTAssertTrue(shares.prefix(3).allSatisfy(\.readOnly), "as the home folder's share")
        XCTAssertEqual(shares.last?.guestPath.hasSuffix("/.monad/exchange"), true, "the exchange folder, as always")
        XCTAssertFalse(shares.dropLast().contains { $0.hostPath.contains("/.monad") || $0.hostPath.contains("/.ssh") })
    }

    /// The home folder a VM's shares are judged against is the one the
    /// share rules use (both builds keep their folder right in it).
    func testTheHomeFolderIsTheOneTheRulesUse() {
        XCTAssertEqual(InstanceConfig.macHome(InstancePaths(name: "dev")), SharePolicy.resolve(SharePolicy.Places.mac.home))
    }

    func testFoldersInTheHomeFolderAreFine() {
        XCTAssertEqual(verdict("/Users/x/src", readOnly: false), .fine)
        XCTAssertEqual(verdict("/Users/x/.sshkeys-backup"), .fine, "not inside ~/.ssh")
        XCTAssertEqual(verdict("/Users/x/.monadic", readOnly: false), .fine, "not inside ~/.monad")
    }
}
