//
//  DiskLockTests.swift — one Lima disk, one Monad at a time: the release
//  and the debug build each take the lock before booting or copying it.
//

import XCTest
@testable import Monad

final class DiskLockTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() { tmp = TempDir() }

    func testOnlyOneHolderAtATime() throws {
        let file = tmp.url.appendingPathComponent("monad.lock")
        let first = try XCTUnwrap(try DiskLock.take(file))
        XCTAssertNil(try DiskLock.take(file), "another Monad holds it")
        first.release()
        let second = try XCTUnwrap(try DiskLock.take(file), "free again")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        second.release()
    }

    func testALockGoesWithItsHolder() throws {
        let file = tmp.url.appendingPathComponent("monad.lock")
        do {
            let held = try DiskLock.take(file)
            XCTAssertNotNil(held)
            XCTAssertNil(try DiskLock.take(file))
        }
        XCTAssertNotNil(try DiskLock.take(file), "released when its holder goes")
    }

    func testAFolderThatIsGoneIsAnError() {
        XCTAssertThrowsError(try DiskLock.take(tmp.url.appendingPathComponent("missing/monad.lock")))
    }
}
