//
//  FlavorTests.swift — Release and Debug builds side by side: a Debug build
//  (Xcode, these tests) has its own MonadHost, bundle identifiers, data
//  folder and log subsystem, so it never touches the Monad in use, its VMs
//  or its files.
//

import Security
import XCTest
@testable import Monad

final class FlavorTests: XCTestCase {
    func testReleaseKeepsItsNamesAndDebugSharesNone() {
        let release = Flavor.names(debug: false), debug = Flavor.names(debug: true)
        XCTAssertEqual(release, Flavor.Names(hostLabel: "dev.monad.host", appIdentifier: "dev.monad.Monad",
                                             hostIdentifier: "dev.monad.MonadHost", dataFolder: ".monad",
                                             logSubsystem: "dev.monad"),
                       "the Monad in use keeps its MonadHost and its VMs")
        XCTAssertEqual(debug, Flavor.Names(hostLabel: "dev.monad.debug.host", appIdentifier: "dev.monad.Monad.debug",
                                           hostIdentifier: "dev.monad.MonadHost.debug", dataFolder: ".monad-debug",
                                           logSubsystem: "dev.monad.debug"))
        XCTAssertEqual(Set(Flavor.allDataFolders), [".monad", ".monad-debug"])
    }

    /// These tests run in a Debug build: everything they could reach is the
    /// debug flavor's.
    func testADebugBuildUsesItsOwnHostAndFolder() {
        XCTAssertTrue(Flavor.isDebug)
        XCTAssertEqual(Flavor.current, Flavor.names(debug: true))
        XCTAssertEqual(HostXPCSecurity.machServiceName, "dev.monad.debug.host")
        XCTAssertEqual(LaunchctlAgent.label, "dev.monad.debug.host")
        XCTAssertEqual(Paths.root.lastPathComponent, ".monad-debug")
    }

    /// The project's bundle identifiers match the flavor's: the app and its
    /// MonadHost pin each other by these signing identifiers.
    func testTheBuildIsSignedWithTheFlavorsIdentifiers() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, Flavor.current.appIdentifier)
        let host = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "MonadHost"))
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(host as CFURL, [], &code), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(code), SecCSFlags(rawValue: kSecCSSigningInformation),
                                                     &info), errSecSuccess)
        let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        XCTAssertEqual(identifier, Flavor.current.hostIdentifier)
        let requirement = try XCTUnwrap(HostXPCSecurity.peerRequirement())
        XCTAssertTrue(requirement.contains("\"dev.monad.MonadHost.debug\""), requirement)
        XCTAssertFalse(requirement.contains("\"dev.monad.MonadHost\""), "the release host is not a peer")
    }

    /// About Monad says which build is running: release or debug, when it
    /// was built and the start of its build id (as the logs print it).
    func testAboutSaysWhichBuildThisIs() throws {
        let built = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 23, minute: 30)))
        XCTAssertEqual(Flavor.aboutVersion(debug: false, built: built, build: "FA2769A0-6C6B-3F50-86BC-3DC0D1E4D459"),
                       "release, built 2026-10-09 23:30, FA2769A0")
        XCTAssertEqual(Flavor.aboutVersion(debug: true, built: built, build: nil), "debug, built 2026-10-09 23:30")
        XCTAssertEqual(Flavor.aboutVersion(debug: false, built: nil, build: nil), "release")
        XCTAssertTrue(Flavor.currentAboutVersion.hasPrefix("debug, built "), "the tests run in a debug build")
    }
}
