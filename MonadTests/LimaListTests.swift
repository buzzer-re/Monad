//
//  LimaListTests.swift — the Lima tab of the Virtual Machines window: each
//  Lima VM with what it is, or why Monad cannot use it, or the Monad VM that
//  uses it; and the settings of a Monad VM that boots one in place or a copy
//  of it, all taken from Lima, its shared folders included.
//

import XCTest
@testable import Monad

final class LimaListTests: XCTestCase {
    private let ubuntuImage = "https://cloud-images.ubuntu.com/releases/24.04/release-20250115/ubuntu-24.04-server-cloudimg-arm64.img"
    /// 8 cores, 16 GB: a VM gets up to 8 CPUs and 14 GB.
    private let capacity = HostCapacity(cores: 8, memoryBytes: 16 << 30, vmMaxCPUs: 8, vmMaxMemoryBytes: 16 << 30)

    private func lima(_ name: String, image: String? = nil, cpus: Int? = 4, memory: Int64? = 4 << 30,
                      mounts: [LimaInstance.Mount] = []) -> LimaInstance {
        LimaInstance(name: name, dir: URL(fileURLWithPath: "/Users/dev/.lima/\(name)", isDirectory: true), status: .stopped,
                     vmType: "vz", arch: "aarch64", cpus: cpus, memoryBytes: memory, imageLocations: [image ?? ubuntuImage],
                     user: "dev", home: "/home/dev.linux", mounts: mounts, diskBytes: 100 << 30)
    }

    /// Folders that exist on this "Mac": everything but /tmp/gone.
    private func list() throws -> LimaList {
        LimaList(catalog: try DistroCatalog.bundled(), places: .init(home: "/Users/dev", monad: "/Users/dev/.monad"),
                 folderExists: { $0 != "/tmp/gone" })
    }

    private func config(_ l: LimaList, _ id: String, _ mode: LimaList.Mode = .inPlace,
                        taken: Set<String> = []) -> InstanceConfig? {
        l.plan(id, mode, taken: taken, capacity: capacity)?.config
    }

    func testEachLimaVMSaysWhatItIsOrWhyItCannotBeUsed() throws {
        var l = try list()
        XCTAssertFalse(l.loaded)
        l.setFound([(lima("default"), nil),
                    (lima("busy"), "Lima is running “busy”. Stop it first with limactl stop busy."),
                    (lima("custom", image: "/Users/dev/images/custom.img"), nil),
                    (lima("work"), nil)])
        l.inMonad = ["/Users/dev/.lima/work": "lima-work"]
        XCTAssertTrue(l.loaded)
        XCTAssertEqual(l.rows.map(\.id), ["default", "busy", "custom", "work"])
        XCTAssertEqual(l.rows[0].detail, "Ubuntu 24.04 LTS · 4 CPUs · 4 GB memory · 100 GB disk")
        XCTAssertNil(l.rows[0].problem)
        XCTAssertNil(l.rows[0].monadVM)
        XCTAssertEqual(l.rows[1].problem, "Lima is running “busy”. Stop it first with limactl stop busy.")
        XCTAssertEqual(l.rows[2].detail, "Unknown distribution · 4 CPUs · 4 GB memory · 100 GB disk")
        XCTAssertEqual(l.rows[2].problem, "Monad does not recognize the distribution of “custom” from its image.")
        XCTAssertEqual(l.rows[3].monadVM, "lima-work")
        XCTAssertNil(l.rows[3].problem)
        XCTAssertFalse(l.rows.contains { ($0.problem ?? "").contains(";") })

        XCTAssertNotNil(config(l, "default"))
        XCTAssertNil(config(l, "busy"))
        XCTAssertNil(config(l, "custom"), "no distribution, no VM")
        XCTAssertNil(config(l, "work"), "in Monad already")
        XCTAssertNotNil(config(l, "work", .copy), "but it can be copied")
        XCTAssertNil(config(l, "busy", .copy), "not while Lima runs it")
        XCTAssertNil(config(l, "nope"))
    }

    /// Using a Lima VM in Monad takes everything from Lima.
    func testALimaVMIsUsedWithLimasOwnSettings() throws {
        var l = try list()
        l.setFound([(lima("default", cpus: 12, memory: 32 << 30), nil)])
        let c = try XCTUnwrap(config(l, "default", taken: ["default"]))
        XCTAssertEqual(c.name, "lima-default", "Monad's own first VM is called default")
        XCTAssertEqual(c.attached, AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "/home/dev.linux"))
        XCTAssertEqual(c.user, "dev")
        XCTAssertEqual(c.distro, "ubuntu")
        XCTAssertEqual(c.release, "24.04")
        XCTAssertEqual(c.cpus, 8, "as much as this Mac gives a VM")
        XCTAssertEqual(c.memoryGiB, 14)
        XCTAssertEqual(c.diskGiB, 100)
        XCTAssertEqual(c.networks, [NetworkAttachment(network: NetworkDefinition.defaultName, macAddress: nil)])
        XCTAssertEqual(c.sharing.shares, [])
        XCTAssertNoThrow(try c.validate(maxCPUs: capacity.maxCPUs, maxMemoryGiB: capacity.maxMemoryGiB))
        XCTAssertNil(c.copiedFrom)
        XCTAssertEqual(config(l, "default", taken: ["lima-default"])?.name, "lima-default-2")
    }

    func testTheNameIsMadeFromLimas() throws {
        var l = try list()
        let long = String(repeating: "a", count: 40)
        l.setFound([(lima("My_VM.dev"), nil), (lima(long), nil)])
        XCTAssertEqual(config(l, "My_VM.dev")?.name, "lima-my-vm-dev")
        XCTAssertEqual(config(l, "My_VM.dev", .copy)?.name, "my-vm-dev-copy")
        let name = try XCTUnwrap(config(l, long)?.name)
        XCTAssertTrue(InstanceConfig.isValidName(name), name)
        let next = try XCTUnwrap(config(l, long, taken: [name])?.name)
        XCTAssertTrue(InstanceConfig.isValidName(next) && next != name, next)
        let copy = try XCTUnwrap(config(l, long, .copy)?.name)
        XCTAssertTrue(InstanceConfig.isValidName(copy), copy)
    }

    /// The folders Lima shares with the VM are shared by Monad too, as Lima
    /// shares them, within SharePolicy: one Monad never shares is left out,
    /// one it shares only read-only is shared so, and those that need the
    /// user's word are asked about once, for all of them.
    func testLimasFoldersAreSharedToo() throws {
        var l = try list()
        l.setFound([(lima("default", mounts: [
            .init(location: "/Users/dev", mountPoint: "/Users/dev", writable: false),
            .init(location: "/Users/dev/src", mountPoint: "/home/dev.linux/src", writable: true),
            .init(location: "/tmp/lima", mountPoint: "/tmp/lima", writable: true),
            .init(location: "/tmp/gone", mountPoint: "/tmp/gone", writable: true),
            .init(location: "/Users/dev/.monad", mountPoint: nil, writable: false),
            .init(location: "/Users/dev/etc", mountPoint: "/etc/x", writable: false),
            .init(location: "/Users/dev/other", mountPoint: "/tmp/lima", writable: false),
            .init(location: "/", mountPoint: "/mnt/mac", writable: false),
        ]), nil)])
        let plan = try XCTUnwrap(l.plan("default", .inPlace, taken: [], capacity: capacity))
        XCTAssertTrue(plan.config.sharing.runtimeEnabled)
        XCTAssertEqual(plan.config.sharing.shares, [
            SharedFolder(hostPath: "/Users/dev", guestPath: "/Users/dev", readOnly: true, confirmed: true),
            SharedFolder(hostPath: "/Users/dev/src", guestPath: "/home/dev.linux/src", readOnly: false),
            SharedFolder(hostPath: "/tmp/lima", guestPath: "/tmp/lima", readOnly: false, confirmed: true),
        ])
        XCTAssertTrue(plan.needsConfirmation, "the home folder and one outside it")
        XCTAssertEqual(plan.folders, ["~, read-only", "~/src, writable", "/tmp/lima, writable"])
        XCTAssertEqual(plan.notes, [
            "/tmp/gone is left out: it is not on this Mac.",
            "~/.monad is left out: it is Monad's own folder.",
            "~/etc is left out: Monad cannot mount it at /etc/x.",
            "~/other is left out: Monad cannot mount it at /tmp/lima.",
            "/ is left out: it holds your home folder. Monad shares your home folder, or folders in it, instead.",
        ])
        XCTAssertNoThrow(try plan.config.validate(maxCPUs: capacity.maxCPUs, maxMemoryGiB: capacity.maxMemoryGiB))
        XCTAssertFalse((plan.folders + plan.notes).contains { $0.contains(";") })

        // Home writable in Lima: Monad shares it read-only (it holds ~/.monad).
        l.setFound([(lima("rw", mounts: [.init(location: "/Users/dev", mountPoint: "/Users/dev", writable: true)]), nil)])
        let rw = try XCTUnwrap(l.plan("rw", .inPlace, taken: [], capacity: capacity))
        XCTAssertEqual(rw.config.sharing.shares,
                       [SharedFolder(hostPath: "/Users/dev", guestPath: "/Users/dev", readOnly: true, confirmed: true)])
        XCTAssertEqual(rw.folders, ["~, read-only (Lima lets the VM write there, but it holds Monad's own folder)"])

        // Folders inside the home folder need no word from the user.
        l.setFound([(lima("src", mounts: [.init(location: "/Users/dev/src", mountPoint: nil, writable: false)]), nil)])
        XCTAssertEqual(l.plan("src", .inPlace, taken: [], capacity: capacity)?.needsConfirmation, false)
        l.setFound([(lima("none"), nil)])
        let none = try XCTUnwrap(l.plan("none", .inPlace, taken: [], capacity: capacity))
        XCTAssertEqual(none.config.sharing, SharingSettings(), "nothing shared, sharing left as it was")
        XCTAssertEqual(none.folders, [])
    }

    /// "Copy to Monad": a VM of Monad's own, from a copy of the Lima VM's
    /// disk, with the user Lima made and its folders.
    func testACopyIsMonadsOwn() throws {
        var l = try list()
        l.setFound([(lima("default", mounts: [.init(location: "/Users/dev", mountPoint: "/Users/dev", writable: false)]), nil)])
        let plan = try XCTUnwrap(l.plan("default", .copy, taken: ["default"], capacity: capacity))
        let c = plan.config
        XCTAssertEqual(c.name, "default-copy")
        XCTAssertNil(c.attached, "not booted in place")
        XCTAssertEqual(c.copiedFrom, AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default", home: "/home/dev.linux"))
        XCTAssertEqual(c.user, "dev")
        XCTAssertEqual(c.home, "/home/dev.linux")
        XCTAssertEqual(c.distro, "ubuntu")
        XCTAssertEqual(c.diskGiB, 100)
        XCTAssertEqual(plan.folders, ["~, read-only"])
        XCTAssertNoThrow(try c.validate(maxCPUs: capacity.maxCPUs, maxMemoryGiB: capacity.maxMemoryGiB))
        XCTAssertEqual(l.plan("default", .copy, taken: ["default-copy"], capacity: capacity)?.config.name, "default-copy-2")
    }
}
