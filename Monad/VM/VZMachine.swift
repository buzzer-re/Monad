//
//  VZMachine.swift — VirtualMachineControlling backed by Virtualization.framework
//  (through the Objective-C MNDVirtualMachine).
//

import Foundation
import Virtualization

@MainActor
final class VZMachineFactory: VirtualMachineFactory {
    /// Apple refused to start a macOS VM: the Mac runs as many as macOS
    /// allows at once (two), in any app.
    nonisolated static func isMacOSLimit(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == VZErrorDomain && e.code == VZError.Code.virtualMachineLimitExceeded.rawValue
    }

    func makeMachine(config: InstanceConfig, paths: InstancePaths, nic: FileHandle?) throws -> VirtualMachineControlling {
        try VZMachine(config: config, paths: paths, nic: nic)
    }

    func makeRecoveryMachine(config: InstanceConfig, paths: InstancePaths,
                             nic: FileHandle?) throws -> VirtualMachineControlling & MacRecoveryInput {
        try VZMachine(config: config, paths: paths, nic: nic, recovery: true)
    }

    func makeDiskMachine(config: InstanceConfig, paths: InstancePaths,
                         nic: FileHandle?) throws -> VirtualMachineControlling & DiskAttaching {
        try VZMachine(config: config, paths: paths, nic: nic, takesDisks: true)
    }
}

@MainActor
final class VZMachine: NSObject, VirtualMachineControlling, MacRecoveryInput, DiskAttaching, MNDVirtualMachineDelegate {
    private let vm: MNDVirtualMachine
    var onEvent: ((VMRuntimeEvent) -> Void)?

    init(config: InstanceConfig, paths: InstancePaths, nic: FileHandle?, recovery: Bool = false, takesDisks: Bool = false) throws {
        vm = try MNDVirtualMachine(config: Self.vmConfig(for: config, paths: paths, nic: nic, recovery: recovery,
                                                         takesDisks: takesDisks))
        super.init()
        vm.delegate = self
    }

    /// The backend description of `config`. Pure apart from checking whether
    /// the seed ISO exists; DeviceModelTests builds the real VZ configuration
    /// from it. `nic` is the VM's socket to monad-netd (Monad networks only);
    /// `takesDisks`: Repair Disk's temporary VM (a USB controller).
    nonisolated static func vmConfig(for config: InstanceConfig, paths: InstancePaths,
                                     nic: FileHandle? = nil, recovery: Bool = false, takesDisks: Bool = false) -> MNDVMConfig {
        let c = MNDVMConfig()
        c.usbDisks = takesDisks
        if config.guestOS == .macos {
            // Its desktop (opened from Monad); recovery is driven on it.
            c.recovery = recovery
            c.displayWidth = UInt(MacRecovery.displayWidth)
            c.displayHeight = UInt(MacRecovery.displayHeight)
            c.displayPixelsPerInch = UInt(MacRecovery.displayPixelsPerInch)
        }
        c.diskPath = config.disk(in: paths).path
        c.efiVariableStorePath = paths.efiVars.path
        if config.guestOS == .macos {
            c.macOS = true
            c.auxiliaryStoragePath = paths.auxStorage.path
            c.hardwareModelPath = paths.hardwareModel.path
            c.machineIdentifierPath = paths.macMachineID.path
        } else {
            c.seedISOPath = FileManager.default.fileExists(atPath: paths.seed.path) ? paths.seed.path : nil
            c.machineIdentifierPath = paths.machineID.path
        }
        c.serialLogPath = paths.serialLog.path
        c.cpuCount = UInt(max(1, config.cpus))
        c.memoryBytes = UInt64(max(1, config.memoryGiB)) << 30
        c.networkEnabled = !config.networks.isEmpty
        c.macAddress = config.primaryMACAddress
        if let first = config.networks.first, !first.isAppleNAT {
            c.networkThroughSocket = true
            c.networkFileHandle = nic
        }
        c.runtimeSharingEnabled = config.sharing.runtimeEnabled
        c.sharedDirectories = directories(config.deviceShares(paths: paths))
        return c
    }

    nonisolated static func directories(_ shares: [SharedFolder]) -> [MNDSharedDirectory] {
        SharingSettings.named(shares).map { MNDSharedDirectory(name: $0.name, path: $0.share.hostPath, readOnly: $0.share.readOnly) }
    }

    var macAddress: String? { vm.config.macAddress }

    func start() async throws { try await vm.start() }

    var canStart: Bool { vm.canStart }

    func requestStop() async throws { try await vm.requestStop() }

    func forceStop() async { try? await vm.forceStop() }

    func setMemoryTarget(bytes: UInt64) { vm.setMemoryTarget(bytes: bytes) }

    func attachDisk(_ url: URL) async throws { try await vm.attachDisk(atPath: url.path) }

    func detachDisk() async throws { try await vm.detachDisk() }

    func setShares(_ shares: [SharedFolder]) async throws {
        try await vm.setSharedDirectories(Self.directories(shares))
    }

    func startBridge(socketPath: String, port: UInt32) throws {
        try vm.startBridge(atPath: socketPath, port: port)
    }

    // MARK: Desktop

    func showDesktop(title: String, actions: [DesktopAction], paste: @escaping @MainActor (String) async -> Void) throws {
        guard vm.config.displayWidth > 0 else {
            throw MonadError("\(title) was started without a display. Restart it to open its desktop.")
        }
        try MacDesktop.shared.show(vm.machine, title: title, owner: ObjectIdentifier(self), actions: actions, paste: paste)
    }

    // MARK: Recovery input

    func press(keyCode: UInt16, modifiers: [UInt16]) async throws {
        let codes = (modifiers + [keyCode]).map { NSNumber(value: $0) }
        try vm.pressKeys(codes, down: true)
        try? await Task.sleep(nanoseconds: 15_000_000)
        try vm.pressKeys(codes.reversed(), down: false)
        try? await Task.sleep(nanoseconds: 15_000_000)
    }

    func release(keyCodes: [UInt16]) async throws {
        try vm.pressKeys(keyCodes.map { NSNumber(value: $0) }, down: false)
    }

    func click(x: Double, y: Double) async throws {
        try vm.point(x: x, y: y, buttons: 0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        try vm.point(x: x, y: y, buttons: 1)
        try? await Task.sleep(nanoseconds: 80_000_000)
        try vm.point(x: x, y: y, buttons: 0)
    }

    /// Read once recovery asks (its machine has the display).
    private var screenReader: MacScreenReader?

    /// Recovery's steps read the screen: from then on Monad types into this
    /// machine, so its desktop only watches.
    func screen() async -> MacRecovery.Screen? {
        if screenReader == nil {
            screenReader = MacScreenReader(machine: vm.machine)
            MacDesktop.shared.setDriven(true, owner: ObjectIdentifier(self))
        }
        return screenReader?.screen()
    }

    var screenInfo: String { screenReader?.info ?? "no reader" }

    func picture() async -> Data? { screenReader?.picture() }

    func stopBridge() { vm.stopBridge() }

    func probe(port: UInt32, timeout: TimeInterval) async -> Bool {
        let vm = self.vm
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: vm.probeVsockPort(port, timeout: timeout))
            }
        }
    }

    func openChannel(port: UInt32, timeout: TimeInterval) async throws -> ByteChannel {
        let vm = self.vm
        let channel: MNDVsockChannel? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: vm.openVsockPort(port, timeout: timeout))
            }
        }
        guard let channel else { throw MonadError("The guest did not accept a connection on vsock port \(port).") }
        return channel
    }

    nonisolated func virtualMachine(_ vm: MNDVirtualMachine, didChange newState: MNDVirtualMachineState, error: Error?) {
        MainActor.assumeIsolated {
            switch newState {
            case .stopped, .error:
                MacDesktop.shared.close(owner: ObjectIdentifier(self))
                screenReader?.close()
                screenReader = nil
            default: break
            }
            switch newState {
            case .stopped: onEvent?(.stopped)
            case .error: onEvent?(.failed(error?.localizedDescription ?? "The virtual machine stopped unexpectedly."))
            default: break
            }
        }
    }
}

extension MNDVsockChannel: ByteChannel {}
