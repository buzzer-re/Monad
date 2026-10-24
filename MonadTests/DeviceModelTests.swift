//
//  DeviceModelTests.swift — the virtual hardware a guest can touch is attack
//  surface. These tests inspect the real VZVirtualMachineConfiguration that
//  would be handed to Virtualization.framework (nothing is booted).
//

import Virtualization
import XCTest
@testable import Monad

@MainActor
final class DeviceModelTests: XCTestCase {
    private var tmp: TempDir!
    private var paths: InstancePaths!

    override func setUp() async throws {
        tmp = TempDir()
        paths = InstancePaths(name: "unit", root: tmp.url)
        try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
        try Data(count: 1 << 20).write(to: paths.disk)
    }

    private func build(_ config: InstanceConfig) throws -> VZVirtualMachineConfiguration {
        try MNDVirtualMachine.virtualMachineConfiguration(for: VZMachine.vmConfig(for: config, paths: paths))
    }

    /// Apple's NAT, which needs no socket: these tests are about the devices.
    /// A Monad network's NIC is covered by its own tests below.
    private var defaults: InstanceConfig {
        var c = InstanceConfig.defaults(name: "unit")
        c.cpus = 2
        c.memoryGiB = 2
        c.networks = [NetworkAttachment(network: NetworkAttachment.defaultNAT, macAddress: nil)]
        return c
    }

    /// A macOS guest (Phase 14) boots Apple's platform from the files its
    /// install wrote in the VM's folder: no seed, nothing of Linux's EFI.
    /// Without them there is nothing to boot, and it says so.
    func testAMacOSGuestBootsItsInstalledPlatform() throws {
        var c = defaults
        c.guestOS = .macos
        let m = VZMachine.vmConfig(for: c, paths: paths)
        XCTAssertTrue(m.macOS)
        XCTAssertEqual(m.auxiliaryStoragePath, paths.auxStorage.path)
        XCTAssertEqual(m.hardwareModelPath, paths.hardwareModel.path)
        XCTAssertEqual(m.machineIdentifierPath, paths.macMachineID.path)
        XCTAssertNil(m.seedISOPath)
        XCTAssertThrowsError(try build(c)) { error in
            XCTAssertTrue(error.localizedDescription.contains("install"), error.localizedDescription)
        }
        XCTAssertFalse(VZMachine.vmConfig(for: defaults, paths: paths).macOS)
    }

    /// A macOS VM has a display, a keyboard and a pointer (its desktop can
    /// be opened, and recovery is driven through them); a boot into
    /// recovery starts there. A Linux VM has none of them.
    func testAMacOSVMHasADisplayAndInput() throws {
        var c = defaults
        c.guestOS = .macos
        let normal = VZMachine.vmConfig(for: c, paths: paths)
        XCTAssertFalse(normal.recovery)
        XCTAssertEqual([normal.displayWidth, normal.displayHeight, normal.displayPixelsPerInch],
                       [UInt(MacRecovery.displayWidth), UInt(MacRecovery.displayHeight), UInt(MacRecovery.displayPixelsPerInch)])
        let recovery = VZMachine.vmConfig(for: c, paths: paths, recovery: true)
        XCTAssertTrue(recovery.recovery)
        XCTAssertEqual(recovery.displayWidth, normal.displayWidth)
        XCTAssertEqual(VZMachine.vmConfig(for: defaults, paths: paths).displayWidth, 0, "Linux: no display")
        // The devices, on a platform these tests can build.
        let linux = VZMachine.vmConfig(for: defaults, paths: paths)
        linux.displayWidth = 1920
        linux.displayHeight = 1200
        linux.displayPixelsPerInch = 80
        let vz = try MNDVirtualMachine.virtualMachineConfiguration(for: linux)
        XCTAssertEqual(vz.graphicsDevices.count, 1)
        XCTAssertTrue(vz.graphicsDevices.first is VZMacGraphicsDeviceConfiguration)
        XCTAssertEqual((vz.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration)?.displays.first?.widthInPixels, 1920)
        XCTAssertEqual(vz.keyboards.count, 1)
        XCTAssertEqual(vz.pointingDevices.count, 1)
        XCTAssertTrue(vz.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
    }

    func testALimaVMBootsLimasOwnDisk() {
        var c = defaults
        c.attached = AttachedDisk(lima: "default", dir: "/Users/dev/.lima/default")
        XCTAssertEqual(VZMachine.vmConfig(for: c, paths: paths).diskPath, "/Users/dev/.lima/default/diffdisk")
        XCTAssertEqual(VZMachine.vmConfig(for: c, paths: paths).efiVariableStorePath, paths.efiVars.path,
                       "Monad's own EFI store, never Lima's")
    }

    func testOnlyTheAllowedDevicesExist() throws {
        let vz = try build(defaults)
        XCTAssertNoThrow(try vz.validate())

        // Allowed: one root disk, NIC per attachment, vsock, entropy, balloon, console.
        XCTAssertEqual(vz.storageDevices.count, 1)
        XCTAssertTrue(vz.storageDevices.allSatisfy { $0 is VZVirtioBlockDeviceConfiguration })
        XCTAssertEqual(vz.networkDevices.count, 1)
        XCTAssertTrue(vz.networkDevices.allSatisfy { $0 is VZVirtioNetworkDeviceConfiguration })
        XCTAssertEqual(vz.socketDevices.count, 1)
        XCTAssertTrue(vz.socketDevices.first is VZVirtioSocketDeviceConfiguration)
        XCTAssertEqual(vz.entropyDevices.count, 1)
        XCTAssertEqual(vz.memoryBalloonDevices.count, 1)
        XCTAssertEqual(vz.serialPorts.count, 1)
        XCTAssertTrue(vz.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)

        // Forbidden: anything that gives the guest more host-facing code paths.
        XCTAssertTrue(vz.graphicsDevices.isEmpty, "no GPU")
        XCTAssertTrue(vz.keyboards.isEmpty, "no keyboard")
        XCTAssertTrue(vz.pointingDevices.isEmpty, "no pointing device")
        XCTAssertTrue(vz.audioDevices.isEmpty, "no audio")
        XCTAssertTrue(vz.consoleDevices.isEmpty, "no spice/clipboard console ports")
        XCTAssertTrue(vz.directorySharingDevices.isEmpty, "no filesystem device unless runtime sharing is on")
        if #available(macOS 15.0, *) {
            XCTAssertTrue(vz.usbControllers.isEmpty, "no USB")
        }

        XCTAssertTrue(vz.platform is VZGenericPlatformConfiguration)
        XCTAssertTrue(vz.bootLoader is VZEFIBootLoader)
    }

    func testRootDiskIsWritableAndSeedIsReadOnly() throws {
        try Data(count: 2048).write(to: paths.seed)
        let vz = try build(defaults)
        XCTAssertEqual(vz.storageDevices.count, 2)
        let attachments = vz.storageDevices.compactMap { $0.attachment as? VZDiskImageStorageDeviceAttachment }
        XCTAssertEqual(attachments.map(\.isReadOnly), [false, true])
        XCTAssertEqual(attachments.first?.url.path, paths.disk.path)
    }

    func testNoNetworkMeansNoNIC() throws {
        var c = defaults
        c.networks = []
        XCTAssertTrue(try build(c).networkDevices.isEmpty)
    }

    func testConfiguredMACIsUsed() throws {
        var c = defaults
        c.networks = [NetworkAttachment(network: NetworkAttachment.defaultNAT, macAddress: "52:54:00:12:34:56")]
        let nic = try XCTUnwrap(build(c).networkDevices.first)
        XCTAssertEqual(nic.macAddress.string, "52:54:00:12:34:56")
    }

    func testAppleNATStaysAppleNAT() throws {
        for name in [NetworkDefinition.appleNATName, "nat"] { // "nat": configs from before Monad networks
            var c = defaults
            c.networks = [NetworkAttachment(network: name, macAddress: "52:54:00:12:34:56")]
            let nic = try XCTUnwrap(build(c).networkDevices.first)
            XCTAssertTrue(nic.attachment is VZNATNetworkDeviceAttachment, name)
        }
    }

    func testAMonadNetworkGoesThroughItsSocket() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds), 0)
        defer { close(fds[1]) }
        let handle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        var c = defaults
        c.networks = [NetworkAttachment(network: "default", macAddress: "02:4d:4f:4e:00:10")]
        let vz = try MNDVirtualMachine.virtualMachineConfiguration(for: VZMachine.vmConfig(for: c, paths: paths, nic: handle))
        XCTAssertNoThrow(try vz.validate())
        let nic = try XCTUnwrap(vz.networkDevices.first)
        let attachment = try XCTUnwrap(nic.attachment as? VZFileHandleNetworkDeviceAttachment)
        XCTAssertEqual(attachment.fileHandle.fileDescriptor, fds[0])
        XCTAssertEqual(nic.macAddress.string, "02:4d:4f:4e:00:10")
    }

    func testAMonadNetworkWithoutItsSocketIsRefused() {
        // Never a silent fall back to Apple's NAT, which reaches the LAN.
        var c = defaults
        c.networks = [NetworkAttachment(network: "default", macAddress: "02:4d:4f:4e:00:10")]
        XCTAssertThrowsError(try build(c))
    }

    func testGeneratedMACsAreSafe() {
        var seen = Set<String>()
        for _ in 0..<2000 {
            let mac = NetworkAttachment.randomMAC()
            let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            XCTAssertEqual(bytes.count, 6, mac)
            XCTAssertEqual(bytes[0] & 0x03, 0x02, "locally administered, unicast: \(mac)")
            XCTAssertFalse(mac.hasPrefix("02:4d:4e:47:00:"), "netd's gateway range: \(mac)")
            XCTAssertEqual(mac, mac.lowercased())
            seen.insert(mac)
        }
        XCTAssertGreaterThan(seen.count, 1990)
    }

    func testRuntimeSharingAddsOneFilesystemDeviceEvenWithoutShares() throws {
        var c = defaults
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [])
        let devices = try build(c).directorySharingDevices
        XCTAssertEqual(devices.count, 1)
        let fs = try XCTUnwrap(devices.first as? VZVirtioFileSystemDeviceConfiguration)
        XCTAssertEqual(fs.tag, "monad")
        let share = try XCTUnwrap(fs.share as? VZMultipleDirectoryShare)
        XCTAssertEqual(Array(share.directories.keys), ["home-\(c.user)-.monad-exchange"],
                       "only the exchange folder: shares are added at runtime")
    }

    func testSharesMapToNamedDirectoriesWithReadOnlyFlags() throws {
        let src = tmp.url.appendingPathComponent("src"), data = tmp.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var c = defaults
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [
            SharedFolder(hostPath: src.path, guestPath: "/home/dev/src", readOnly: true),
            SharedFolder(hostPath: data.path, guestPath: "/mnt/data", readOnly: false),
        ])
        let fs = try XCTUnwrap(build(c).directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)
        let dirs = try XCTUnwrap(fs.share as? VZMultipleDirectoryShare).directories
        XCTAssertEqual(Set(dirs.keys), ["home-dev-src", "mnt-data", "home-\(c.user)-.monad-exchange"])
        XCTAssertEqual(dirs["home-dev-src"]?.url.path, src.path)
        XCTAssertEqual(dirs["home-dev-src"]?.isReadOnly, true)
        XCTAssertEqual(dirs["mnt-data"]?.isReadOnly, false)
    }

    func testSharesAreIgnoredWhenRuntimeSharingIsOff() throws {
        var c = defaults
        c.sharing = SharingSettings(runtimeEnabled: false,
                                    shares: [SharedFolder(hostPath: tmp.url.path, guestPath: "/mnt/x", readOnly: true)])
        XCTAssertTrue(try build(c).directorySharingDevices.isEmpty)
    }

    func testResourcesAreClampedToHostLimits() throws {
        var c = defaults
        c.cpus = 10_000
        c.memoryGiB = 1_000_000
        let vz = try build(c)
        XCTAssertLessThanOrEqual(vz.cpuCount, Int(MNDVirtualMachine.maximumCPUCount()))
        XCTAssertLessThanOrEqual(vz.memorySize, MNDVirtualMachine.maximumMemoryBytes())
        XCTAssertEqual(vz.memorySize % (1 << 20), 0)
    }

    func testShareNameIsStableAndSafe() {
        XCTAssertEqual(SharedFolder(hostPath: "/a", guestPath: "/home/dev/src/", readOnly: true).shareName, "home-dev-src")
        XCTAssertEqual(SharedFolder(hostPath: "/a", guestPath: "/mnt/My Stuff", readOnly: true).shareName, "mnt-My_Stuff")
    }

    func testCollidingShareNamesAreMadeUnique() throws {
        var c = defaults
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [
            SharedFolder(hostPath: tmp.url.path, guestPath: "/mnt/a-b", readOnly: true),
            SharedFolder(hostPath: tmp.url.path, guestPath: "/mnt/a/b", readOnly: true),
        ])
        let mapped = VZMachine.vmConfig(for: c, paths: paths).sharedDirectories
        XCTAssertEqual(mapped.map(\.name), ["mnt-a-b", "mnt-a-b-2", "home-\(c.user)-.monad-exchange"])
    }

    /// The exchange folder (where host commands leave their runs): every VM
    /// with the shared folder device has it, last, read-only, from the VM's
    /// own folder on the Mac, at ~/.monad/exchange in the guest.
    func testTheExchangeFolderIsOnTheSharingDevice() throws {
        var c = defaults
        XCTAssertEqual(VZMachine.vmConfig(for: c, paths: paths).sharedDirectories, [], "no device, no folders")
        c.sharing = SharingSettings(runtimeEnabled: true, shares: [
            SharedFolder(hostPath: tmp.url.path, guestPath: "/mnt/src", readOnly: false)])
        let mapped = VZMachine.vmConfig(for: c, paths: paths).sharedDirectories
        XCTAssertEqual(mapped.map(\.name), ["mnt-src", "home-\(c.user)-.monad-exchange"])
        XCTAssertEqual(mapped.last?.path, paths.exchange.path)
        XCTAssertEqual(mapped.last?.readOnly, true)
        XCTAssertEqual(paths.exchange.path, paths.dir.appendingPathComponent("exchange").path)
        let exchange = try XCTUnwrap(c.deviceShares(paths: paths).last)
        XCTAssertEqual(exchange.guestPath, "\(c.home)/.monad/exchange")
        XCTAssertEqual(GuestShares.entries(c.deviceShares(paths: paths)).last,
                       "home-\(c.user)-.monad-exchange\tro\t\(c.home)/.monad/exchange")
    }
}
