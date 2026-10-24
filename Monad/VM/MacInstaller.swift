//
//  MacInstaller.swift — Apple's macOS installer for a VM (Phase 14): from a
//  restore image, the VM's platform files (hardware model, auxiliary
//  storage, machine identifier) and a sparse disk in its folder, then
//  VZMacOSInstaller onto that disk, headless. The machine that installs has
//  no network device: the Mac itself talks to Apple during the install.
//

import Foundation
import Virtualization

final class VZMacInstaller: MacInstalling, @unchecked Sendable {
    /// What the installing machine is given at least.
    static let minimumCPUs = 2
    static let minimumMemory: UInt64 = 4 << 30

    /// A machine identifier of its own, for a new VM or a copy of one.
    static func newMachineIdentifier() -> Data { VZMacMachineIdentifier().dataRepresentation }

    func install(restoreImage: URL, paths: InstancePaths, diskBytes: UInt64,
                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let image = try await Self.load(restoreImage)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw MonadError("This Mac cannot run the macOS in \(restoreImage.lastPathComponent). "
                + "Choose a newer restore image (or the latest for this Mac).")
        }
        let model = requirements.hardwareModel
        try model.dataRepresentation.write(to: paths.hardwareModel, options: .atomic)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: paths.auxStorage, hardwareModel: model, options: [.allowOverwrite])
        try Self.newMachineIdentifier().write(to: paths.macMachineID, options: .atomic)
        try Self.createSparseDisk(paths.disk, bytes: diskBytes)

        let c = MNDVMConfig()
        c.macOS = true
        c.diskPath = paths.disk.path
        c.efiVariableStorePath = paths.efiVars.path
        c.auxiliaryStoragePath = paths.auxStorage.path
        c.hardwareModelPath = paths.hardwareModel.path
        c.machineIdentifierPath = paths.macMachineID.path
        c.cpuCount = UInt(max(requirements.minimumSupportedCPUCount, Self.minimumCPUs))
        c.memoryBytes = max(requirements.minimumSupportedMemorySize, Self.minimumMemory)
        c.networkEnabled = false
        let configuration = try MNDVirtualMachine.virtualMachineConfiguration(for: c)
        try configuration.validate()
        try await Self.run(configuration, restoreImage: restoreImage, progress: progress)
    }

    private static func load(_ url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.load(from: url) { cont.resume(with: $0) }
        }
    }

    /// A disk of `bytes` that takes no room until written.
    static func createSparseDisk(_ url: URL, bytes: UInt64) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MonadError.posix(errno, "Cannot create the disk") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(bytes)) == 0 else { throw MonadError.posix(errno, "Cannot size the disk") }
    }

    /// The install, on a queue of its own (Virtualization's rule: one queue
    /// per machine); the machine is kept until it ends.
    private static func run(_ configuration: VZVirtualMachineConfiguration, restoreImage: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let queue = DispatchQueue(label: "dev.monad.mac-install")
        let job = InstallJob()
        // Made here, used only on the install's queue from now on.
        let built = Handoff(configuration)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let vm = VZVirtualMachine(configuration: built.value, queue: queue)
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImage)
                job.keep(vm, installer, installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                    progress(p.fractionCompleted)
                })
                installer.install { result in
                    job.end()
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: MonadError("Installing macOS failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    /// A configuration handed to the install's queue, which alone uses it.
    private struct Handoff: @unchecked Sendable {
        let value: VZVirtualMachineConfiguration
        init(_ value: VZVirtualMachineConfiguration) { self.value = value }
    }

    /// What must stay alive while Apple's installer runs.
    private final class InstallJob: @unchecked Sendable {
        private var held: [AnyObject] = []
        private var observation: NSKeyValueObservation?

        func keep(_ vm: VZVirtualMachine, _ installer: VZMacOSInstaller, _ observation: NSKeyValueObservation) {
            held = [vm, installer]
            self.observation = observation
        }

        func end() {
            observation?.invalidate()
            observation = nil
            held = []
        }
    }
}
