//
//  GuestPictureTests.swift — what a Linux program's window shows on the
//  Mac (GuestPicture): the pixels the guest's window manager sent, put
//  where it said in memory the Mac's screen is drawn from. The guest says
//  where; nothing of it lands outside the picture.
//

import XCTest
@testable import Monad

final class GuestPictureTests: XCTestCase {
    private func pixels(_ words: [UInt32]) -> Data {
        var data = Data()
        for word in words { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// Pixels land where the window manager said, row by row from the top;
    /// the rest of the picture stays as it was (nothing, at first).
    func testPixelsAreKeptWhereTheyWereSaid() throws {
        let picture = try XCTUnwrap(GuestPicture(width: 4, height: 3))
        XCTAssertEqual(picture.pixel(x: 0, y: 0), 0, "nothing of it is there until something is drawn")
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 1, y: 1, width: 2, height: 2,
                                              data: pixels([0xff112233, 0x80402010, 0xffaabbcc, 0x00000000]))))
        XCTAssertEqual([picture.pixel(x: 1, y: 1), picture.pixel(x: 2, y: 1)], [0xff112233, 0x80402010])
        XCTAssertEqual([picture.pixel(x: 1, y: 2), picture.pixel(x: 2, y: 2)], [0xffaabbcc, 0])
        XCTAssertEqual([picture.pixel(x: 0, y: 1), picture.pixel(x: 3, y: 1), picture.pixel(x: 1, y: 0)], [0, 0, 0])
        // Drawn over: the newest stays.
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 0, y: 0, width: 4, height: 3, data: pixels(Array(repeating: 0xff010203, count: 12)))))
        XCTAssertEqual([picture.pixel(x: 0, y: 0), picture.pixel(x: 2, y: 1), picture.pixel(x: 3, y: 2)], [0xff010203, 0xff010203, 0xff010203])
    }

    /// Parts put one after another are all in the picture: each lands in
    /// the memory the screen is not showing, which is first given what
    /// the one before it lacks.
    func testPartsPutOneAfterAnotherAllStay() throws {
        let picture = try XCTUnwrap(GuestPicture(width: 4, height: 2))
        var surfaces: [ObjectIdentifier] = []
        for i in 0..<8 {
            XCTAssertTrue(picture.put(GuestPixels(window: 1, x: i % 4, y: i / 4, width: 1, height: 1, data: pixels([0xff000000 | UInt32(i + 1)]))))
            surfaces.append(ObjectIdentifier(picture.surface))
            for j in 0...i { XCTAssertEqual(picture.pixel(x: j % 4, y: j / 4), 0xff000000 | UInt32(j + 1), "part \(j) after part \(i)") }
        }
        XCTAssertEqual(Set(surfaces).count, 2)
        XCTAssertTrue(zip(surfaces, surfaces.dropFirst()).allSatisfy { $0 != $1 }, "the screen is shown another memory after each part")
    }

    /// Fewer bytes than the pixels are: packed, as the window manager
    /// packs what is flat or repeats (GuestWM/mwm_pack.h). What does not
    /// unpack to exactly that part leaves the picture as it was.
    func testPackedPixelsAreMadeWhole() throws {
        let picture = try XCTUnwrap(GuestPicture(width: 4, height: 3))
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 0, y: 0, width: 4, height: 3, data: pixels(Array(repeating: 0xff010203, count: 12)))))
        // 3 × 2 at (1, 1): a row of three as they are, then "as above" for the next.
        let packed = pixels([3 << 2 | 1, 0xffaa0001, 0xffaa0002, 0xffaa0003, 3 << 2 | 2])
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 1, y: 1, width: 3, height: 2, data: packed)))
        XCTAssertEqual((0..<4).map { picture.pixel(x: $0, y: 1) }, [0xff010203, 0xffaa0001, 0xffaa0002, 0xffaa0003])
        XCTAssertEqual((0..<4).map { picture.pixel(x: $0, y: 2) }, [0xff010203, 0xffaa0001, 0xffaa0002, 0xffaa0003])
        XCTAssertEqual(picture.pixel(x: 1, y: 0), 0xff010203)
        // One colour for all six, said once.
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 1, y: 1, width: 3, height: 2, data: pixels([6 << 2 | 0, 0xff445566]))))
        XCTAssertEqual([picture.pixel(x: 1, y: 1), picture.pixel(x: 3, y: 2), picture.pixel(x: 0, y: 2)], [0xff445566, 0xff445566, 0xff010203])
        // Nonsense: more pixels than the part has, after some that fit. Nothing of it stays, now or after the next part.
        XCTAssertFalse(picture.put(GuestPixels(window: 1, x: 0, y: 0, width: 4, height: 3, data: pixels([5 << 2 | 0, 0xffffffff, 9 << 2 | 0, 0xffffffff]))))
        XCTAssertEqual([picture.pixel(x: 0, y: 0), picture.pixel(x: 3, y: 0), picture.pixel(x: 1, y: 1)], [0xff010203, 0xff010203, 0xff445566])
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 3, y: 2, width: 1, height: 1, data: pixels([0xff000009]))))
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 3, y: 2, width: 1, height: 1, data: pixels([0xff00000a]))))
        XCTAssertEqual([picture.pixel(x: 0, y: 0), picture.pixel(x: 1, y: 0), picture.pixel(x: 3, y: 2)], [0xff010203, 0xff010203, 0xff00000a])
    }

    /// What does not fit the picture, or is not as many bytes as it says, changes nothing.
    func testPixelsThatDoNotFitAreNotKept() throws {
        let picture = try XCTUnwrap(GuestPicture(width: 4, height: 3))
        let four = pixels([1, 2, 3, 4])
        for (x, y, w, h) in [(3, 0, 2, 2), (0, 2, 2, 2), (-1, 0, 2, 2), (0, 0, 0, 4), (0, 0, 4, 0), (0, 0, 1, 1), (0, 0, 2, 1), (0, 0, 8, 8)] {
            XCTAssertFalse(picture.put(GuestPixels(window: 1, x: x, y: y, width: w, height: h, data: four)), "\(x) \(y) \(w) \(h)")
        }
        for y in 0..<3 { for x in 0..<4 { XCTAssertEqual(picture.pixel(x: x, y: y), 0) } }
        XCTAssertNil(picture.pixel(x: 4, y: 0))
        XCTAssertNil(picture.pixel(x: 0, y: -1))
    }

    /// A picture is of a size a window can have, and no other.
    func testAPictureHasAWindowsSize() {
        XCTAssertNil(GuestPicture(width: 0, height: 10))
        XCTAssertNil(GuestPicture(width: 10, height: -1))
        XCTAssertNil(GuestPicture(width: GuestWindowReader.maxSide + 1, height: 10))
        XCTAssertNotNil(GuestPicture(width: 1, height: 1))
    }

    /// A window that changed size is whole again when the last row of its
    /// new picture came: the window manager sends all of it from the top.
    func testAPictureIsWholeWhenItsLastRowCame() throws {
        let picture = try XCTUnwrap(GuestPicture(width: 2, height: 4))
        XCTAssertFalse(picture.isWhole)
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 0, y: 0, width: 2, height: 2, data: pixels([1, 2, 3, 4]))))
        XCTAssertFalse(picture.isWhole, "its top only")
        XCTAssertTrue(picture.put(GuestPixels(window: 1, x: 0, y: 2, width: 2, height: 2, data: pixels([5, 6, 7, 8]))))
        XCTAssertTrue(picture.isWhole)
    }
}
