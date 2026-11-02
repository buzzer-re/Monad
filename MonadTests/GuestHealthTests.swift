//
//  GuestHealthTests.swift — what a Linux guest's health lines (health.log,
//  Guest/monad-health.sh) make Monad tell the user: its kernel crashed, it
//  ran out of memory, its disk is full. Said once per boot, in plain words;
//  the lines are the guest's, so hostile ones change nothing else.
//

import XCTest
@testable import Monad

final class GuestHealthTests: XCTestCase {
    /// Seen on the Mac: AppArmor's find_attach crashed on every exec, so
    /// every command "segfaulted" and ssh could not start a session.
    func testAKernelCrashSaysWhereAndWhoAndToRestart() {
        var h = GuestHealth()
        XCTAssertEqual(h.read(["boot id=1 kernel=7.0.0 cpus=2 mem=1997472",
                               "snap up=1441 mem=1657516/1997472 swap=0/0 psi=0.00,0.00 load=0.01 procs=141 dstate=0 top=fwupd:82084 disk=/:6175080/19221248"]), [])
        XCTAssertNil(h.summary)
        let new = h.read(["kern 1 Unable to handle kernel NULL pointer dereference at virtual address 0000000000000008",
                          "kern 0 Internal error: Oops: 0000000096000004 [#1]  SMP",
                          "kern 4 CPU: 1 UID: 0 PID: 17297 Comm: agent Not tainted 7.0.0-38-generic #38-Ubuntu",
                          "kern 4 pc : find_attach+0x13c/0x4f8",
                          "kern 4 Call trace:"])
        XCTAssertEqual(new.count, 1, "said once")
        let said = new.first ?? ""
        XCTAssertTrue(said.contains("kernel crashed"), said)
        XCTAssertTrue(said.contains("Restart"), said)
        XCTAssertEqual(h.summary, "The VM's kernel crashed (in find_attach, running agent): programs in it fail, and their "
                       + "shells say “Segmentation fault”, until it restarts. Restart the VM.")
        XCTAssertEqual(h.read(["kern 0 Internal error: Oops: 0000000096000004 [#9612]  SMP",
                               "kern 4 CPU: 0 UID: 0 PID: 177881 Comm: sh Tainted: G D W"]), [], "not again")
        XCTAssertTrue(h.summary?.contains("running agent") ?? false, "the first crash is the one named")
        // A new boot starts clean.
        XCTAssertEqual(h.read(["boot id=2 kernel=7.0.0 cpus=2 mem=1997472"]), [])
        XCTAssertNil(h.summary)
    }

    func testOutOfMemorySaysWhatWasStoppedAndWhatToDo() {
        var h = GuestHealth()
        let new = h.read(["kern 4 python3 invoked oom-killer: gfp_mask=0x140cca, order=0",
                          "kern 3 Out of memory: Killed process 3730 (python3) total-vm:1745300kB, anon-rss:1730916kB"])
        XCTAssertEqual(new, ["The VM ran out of memory: Linux stopped python3 to free some. Give it more memory (its settings › Resources)."])
        XCTAssertEqual(h.read(["kern 3 Memory cgroup out of memory: Killed process 4100 (node) total-vm:1kB"]), [])
        XCTAssertEqual(h.summary, "The VM ran out of memory: Linux stopped python3, node to free some. Give it more memory (its settings › Resources).")
    }

    func testANearlyFullDiskIsSaidAndClearsWhenFreed() {
        var h = GuestHealth()
        XCTAssertEqual(h.read(["snap up=9 mem=1/2 top= disk=/:19300000/20000000,/mnt/w:1/2"]),
                       ["The VM's disk is 96% full: programs in it may fail to write. Free some space in it."])
        XCTAssertEqual(h.read(["snap up=24 mem=1/2 top= disk=/:19400000/20000000"]), [], "said once")
        XCTAssertEqual(h.read(["snap up=39 mem=1/2 top= disk=/:10000000/20000000"]), [])
        XCTAssertNil(h.summary, "freed")
    }

    /// Like VMware's: a VM that stays low on memory is warned about before
    /// Linux starts stopping programs. One snapshot can be a spike; the
    /// warning holds until use falls below 85%, so it does not flicker.
    func testAVMThatStaysLowOnMemoryIsWarned() {
        var h = GuestHealth()
        _ = h.read(["snap up=1 mem=150000/2000000 swap=0/0 top= disk=/:1/10"])
        XCTAssertEqual(h.warnings, [], "one snapshot can be a spike")
        _ = h.read(["snap up=16 mem=140000/2000000 swap=0/0 top= disk=/:1/10"])
        XCTAssertEqual(h.warnings, [GuestWarning(kind: .lowMemory, percent: 93)])
        _ = h.read(["snap up=31 mem=260000/2000000 swap=0/0 top= disk=/:1/10"])
        XCTAssertEqual(h.warnings, [GuestWarning(kind: .lowMemory, percent: 87)], "still above 85%")
        _ = h.read(["snap up=46 mem=400000/2000000 swap=0/0 top= disk=/:1/10"])
        XCTAssertEqual(h.warnings, [], "cleared")
        XCTAssertNil(h.summary, "a warning is not a problem")
    }

    func testADiskAlmostFullIsWarnedBeforeItIsFull() {
        var h = GuestHealth()
        XCTAssertEqual(h.read(["snap up=1 mem=1/2 top= disk=/:18000000/20000000"]), [], "not full yet")
        XCTAssertEqual(h.warnings, [GuestWarning(kind: .lowDisk, percent: 90, mount: "/")])
        _ = h.read(["snap up=16 mem=1/2 top= disk=/:17600000/20000000"])
        XCTAssertEqual(h.warnings, [GuestWarning(kind: .lowDisk, percent: 88, mount: "/")], "still above 85%")
        _ = h.read(["snap up=31 mem=1/2 top= disk=/:16000000/20000000"])
        XCTAssertEqual(h.warnings, [])
        _ = h.read(["snap up=46 mem=1/2 top= disk=/:19000000/20000000",
                    "boot id=2 kernel=7 cpus=2 mem=2"])
        XCTAssertEqual(h.warnings, [], "a new boot starts clean")
    }

    /// The guest writes these lines: names are cut and plain, and nonsense
    /// makes no problem.
    func testHostileLinesChangeNothingElse() {
        var h = GuestHealth()
        XCTAssertEqual(h.read(["", "kern", "kern x", "snap disk=/:a/b", "snap disk=/:5/0", "boot",
                               String(repeating: "kern 3 x", count: 10_000)]), [])
        for _ in 0..<3 { _ = h.read(["snap mem=5/0 disk=/:1/2", "snap mem=9/5 disk=/:1/2", "snap mem=-1/5 disk=/:1/2"]) }
        XCTAssertEqual(h.warnings, [], "impossible memory numbers warn of nothing")
        _ = h.read(["kern 3 Out of memory: Killed process 1 (\u{202E}evil\u{1B}[31m" + String(repeating: "a", count: 200) + ") x"])
        let s = h.summary ?? ""
        XCTAssertFalse(s.contains("\u{202E}") || s.contains("\u{1B}"), s)
        XCTAssertLessThan(s.count, 200, s)
    }
}
