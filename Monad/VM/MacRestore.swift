//
//  MacRestore.swift — where the latest macOS restore image (IPSW) for this
//  Mac is: Apple says, through Virtualization (Phase 14).
//

import Foundation
import Virtualization

/// One restore image Apple offers.
struct MacRestoreRelease: Equatable, Sendable {
    let url: URL
    /// The build ("26A100"), unique per restore image.
    let build: String
    /// "27.0".
    let version: String
}

protocol MacRestoreSource: Sendable {
    func latest() async throws -> MacRestoreRelease
}

/// No source: a pipeline without macOS (tests of Linux images).
struct NoMacRestore: MacRestoreSource {
    func latest() async throws -> MacRestoreRelease {
        throw MonadError("This Monad cannot look up macOS restore images.")
    }
}

/// Apple's own answer, the latest restore image this Mac can run.
struct AppleRestoreSource: MacRestoreSource {
    func latest() async throws -> MacRestoreRelease {
        let image = try await VZMacOSRestoreImage.latestSupported
        let v = image.operatingSystemVersion
        let version = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        guard image.url.scheme?.lowercased() == "https" else {
            throw MonadError("Apple gave a restore image address that is not https: \(image.url.absoluteString).")
        }
        return MacRestoreRelease(url: image.url, build: image.buildVersion, version: version)
    }
}
