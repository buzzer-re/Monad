//
//  InvariantTests.swift — properties of the source the security model rests
//  on, checked where a test cannot reach them at run time (F-19). The rest
//  of the brief's invariants live with their code: netd closes a port until
//  its firewall arrives (test_netd_ctl.c), a name never opens the LAN
//  (test_net_fw.c), VMs on a network are kept apart (test_net_gateway.c),
//  every config field is validated (ConfigV2Tests), and netd's sandbox
//  refuses files, processes, listening and unix sockets (NetdProcessTests).
//

import XCTest
@testable import Monad

final class InvariantTests: XCTestCase {
    /// The Monad sources, found from this file's own path.
    private var sources: [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Monad")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { ["swift", "m", "h", "c"].contains($0.pathExtension) }
    }

    /// Monad's own folder in the guest (~/.monad: shots, uploads, the
    /// exchange folder) is never a share's mount point: a share cannot hide
    /// the exchange folder or stand in for it.
    func testNoShareMountsOverMonadsGuestFolder() {
        var c = InstanceConfig.defaults(name: "inv")
        c.sharing.runtimeEnabled = true
        for path in ["\(c.home)/.monad", "\(c.home)/.monad/exchange", "\(c.home)/.monad/exchange/runs", "\(c.home)/.monad/"] {
            c.sharing.shares = [SharedFolder(hostPath: "/tmp", guestPath: path, readOnly: true)]
            XCTAssertThrowsError(try c.validate(maxCPUs: 8, maxMemoryGiB: 16), path)
        }
        c.sharing.shares = [SharedFolder(hostPath: "/tmp", guestPath: "\(c.home)/.monadic", readOnly: true)]
        XCTAssertNoThrow(try c.validate(maxCPUs: 8, maxMemoryGiB: 16))
    }

    /// The host dials the guest over vsock, never the other way round: no
    /// listener a guest could connect to exists anywhere in Monad.
    func testTheHostNeverListensOnVsock() throws {
        let files = sources
        XCTAssertGreaterThan(files.count, 50, "the sources were found")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["VZVirtioSocketListener", "setSocketListener"] {
                XCTAssertFalse(text.contains(forbidden), "\(file.lastPathComponent) uses \(forbidden)")
            }
        }
    }
}
