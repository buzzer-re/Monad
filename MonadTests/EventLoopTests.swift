//
//  EventLoopTests.swift — mnd_loop on its macOS backend (kqueue); the C
//  tests cover the Linux backend (epoll).
//

import XCTest
@testable import Monad

private final class Probe {
    var calls = 0
    var lastEvents: UInt32 = 0
    var drain = true
    var loop: OpaquePointer?
    var unwatch: Int32 = -1
    var rewatch: Probe?
}

private func onEvent(_ ctx: UnsafeMutableRawPointer?, _ fd: Int32, _ events: UInt32) {
    guard let ctx else { return }
    let p = Unmanaged<Probe>.fromOpaque(ctx).takeUnretainedValue()
    p.calls += 1
    p.lastEvents = events
    if p.drain, events & MND_LOOP_READ != 0 {
        var buf = [UInt8](repeating: 0, count: 64)
        while read(fd, &buf, buf.count) > 0 {}
    }
    if p.unwatch >= 0 {
        mnd_loop_watch(p.loop, p.unwatch, 0, nil, nil)
        if let again = p.rewatch {
            mnd_loop_watch(p.loop, p.unwatch, MND_LOOP_READ, onEvent, Unmanaged.passUnretained(again).toOpaque())
        }
    }
}

final class EventLoopTests: XCTestCase {
    private var loop: OpaquePointer!
    private var open: [Int32] = []

    override func setUp() {
        loop = mnd_loop_create()
    }

    override func tearDown() {
        mnd_loop_destroy(loop)
        open.forEach { close($0) }
    }

    private func pipePair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        open += fds
        return (fds[0], fds[1])
    }

    /// The loop keeps an unretained pointer: the caller keeps `probe` alive.
    private func watch(_ fd: Int32, _ events: UInt32, _ probe: Probe) {
        XCTAssertEqual(mnd_loop_watch(loop, fd, events, onEvent, Unmanaged.passUnretained(probe).toOpaque()), 0)
    }

    /// One turn of the loop (not `run`: XCTestCase.spin() would start the test again).
    private func spin(_ ms: UInt64 = 1000) -> Int32 { mnd_loop_run_once(loop, mnd_loop_now() + ms) }

    func testReadableWritableAndDeadline() {
        let (r, w) = pipePair()
        let p = Probe()
        watch(r, MND_LOOP_READ, p)
        let t0 = mnd_loop_now()
        XCTAssertEqual(spin(50), 0)
        XCTAssertGreaterThanOrEqual(mnd_loop_now(), t0 + 50)
        XCTAssertEqual(write(w, "x", 1), 1)
        XCTAssertEqual(spin(), 1)
        XCTAssertEqual(p.lastEvents, MND_LOOP_READ)
        // Level-triggered: unread data is reported again.
        p.drain = false
        XCTAssertEqual(write(w, "y", 1), 1)
        XCTAssertEqual(spin(), 1)
        XCTAssertEqual(spin(), 1)
        p.drain = true
        let q = Probe()
        watch(w, MND_LOOP_WRITE, q)
        XCTAssertEqual(spin(), 2)
        XCTAssertEqual(q.lastEvents, MND_LOOP_WRITE)
        XCTAssertEqual(mnd_loop_watch(loop, w, 0, nil, nil), 0)
        XCTAssertEqual(mnd_loop_watch(loop, r, 0, nil, nil), 0)
        XCTAssertEqual(write(w, "z", 1), 1)
        XCTAssertEqual(spin(30), 0)
    }

    func testHangUpReportsWhatIsWatched() {
        let (r, w) = pipePair()
        let p = Probe()
        watch(r, MND_LOOP_READ, p)
        close(w)
        open.removeAll { $0 == w }
        XCTAssertEqual(spin(), 1)
        XCTAssertEqual(p.lastEvents, MND_LOOP_READ)
    }

    func testStaleEventsInABatchAreDropped() {
        let (a, aw) = pipePair()
        let (b, bw) = pipePair()
        let newcomer = Probe()
        let pa = Probe()
        pa.loop = loop
        pa.unwatch = b
        pa.rewatch = newcomer
        let pb = Probe()
        pb.drain = false
        watch(a, MND_LOOP_READ, pa)
        watch(b, MND_LOOP_READ, pb)
        XCTAssertEqual(write(aw, "x", 1), 1)
        XCTAssertEqual(write(bw, "x", 1), 1)
        _ = spin()
        XCTAssertEqual(pa.calls, 1)
        XCTAssertEqual(newcomer.calls, 0)
        XCTAssertEqual(mnd_loop_watch(loop, a, 0, nil, nil), 0)
        XCTAssertEqual(spin(), 1)
        XCTAssertEqual(newcomer.calls, 1)
        // The loop holds bare pointers: keep every probe alive until here.
        withExtendedLifetime(pb) {}
    }

    func testManyDescriptors() {
        let p = Probe()
        for _ in 0..<200 {
            let (r, w) = pipePair()
            watch(r, MND_LOOP_READ, p)
            XCTAssertEqual(write(w, "x", 1), 1)
        }
        var total: Int32 = 0
        for _ in 0..<10 where total < 200 { total += spin() }
        XCTAssertEqual(total, 200)
        XCTAssertEqual(p.calls, 200)
    }
}
