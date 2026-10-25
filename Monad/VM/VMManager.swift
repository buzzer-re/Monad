//
//  VMManager.swift — registry of instances: creation, deletion, ephemeral
//  VMs, their order (VMOrder: the top one is the default VM) and the
//  zero-configuration "default" VM made when there is none.
//

import Combine
import Foundation
import os

@MainActor
final class VMManager: ObservableObject {
    static let shared = VMManager()
    nonisolated static let defaultName = "default"

    /// In the user's order, ephemeral VMs last.
    @Published private(set) var instances: [VMInstance] = []
    /// The persistent VMs in the user's order: the first is the default VM.
    @Published private(set) var order: [String] = []
    /// The default VM chosen with Make Default (nil: none chosen, or it is
    /// gone; the top of the order is the default then).
    @Published private(set) var chosenDefault: String?
    private let orderStore: VMOrderStore
    private var sessionCounts: [String: Int] = [:]
    private var creating: [String: Task<VMInstance, Error>] = [:]

    /// Directory holding one sub-directory per instance.
    let root: URL
    let env: VMEnvironment
    /// Who asks the user for a macOS VM's setup (MonadHost's service);
    /// without one, the environment's.
    weak var macSetupAsker: MacSetupAuthorizing?
    private let images: BaseImageProviding
    /// Read when needed: a distro added meanwhile is there.
    private let distros: () -> DistroCatalog?
    private let minimumFreeBytes: UInt64
    /// Room a macOS install needs: the installed system (about 15 GB) and
    /// some to spare. With less, Apple's installer failed near its end.
    private let macMinimumFreeBytes: UInt64

    init(root: URL, environment: VMEnvironment, images: BaseImageProviding,
         distros: @escaping @autoclosure () -> DistroCatalog? = DistroCatalog.live,
         minimumFreeBytes: UInt64 = 4 << 30, macMinimumFreeBytes: UInt64 = 20 << 30) {
        self.root = root
        self.env = environment
        self.images = images
        self.distros = distros
        self.minimumFreeBytes = minimumFreeBytes
        self.macMinimumFreeBytes = macMinimumFreeBytes
        orderStore = VMOrderStore(url: root.appendingPathComponent("order.json"))
    }

    private func guest(for config: InstanceConfig) -> DistroConfig.GuestProfile? {
        distros()?.distro(config.distro)?.guest
    }

    private convenience init() {
        self.init(root: Paths.instances, environment: .live, images: ImagePipeline.live)
    }

    func paths(for name: String) -> InstancePaths { InstancePaths(name: name, root: root) }

    private func makeInstance(_ config: InstanceConfig) -> VMInstance {
        let vm = VMInstance(config: config, paths: paths(for: config.name), environment: env, guest: guest(for: config))
        vm.otherMacOSVMsRunning = { [weak self, weak vm] in
            self?.instances.filter { $0 !== vm && $0.config.guestOS == .macos && $0.isRunning }.map(\.name) ?? []
        }
        return vm
    }

    // MARK: Registry

    func load() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var loaded: [VMInstance] = []
        for name in names.sorted() where InstanceConfig.isValidName(name) {
            let p = paths(for: name)
            if let vm = existing(name), vm.creationFailed {
                loaded.append(vm)
                continue
            }
            guard let cfg = try? InstanceConfig.load(from: p.config),
                  cfg.attached != nil || fm.fileExists(atPath: p.disk.path) else {
                // A VM that could not be made before MonadHost started again
                // left its log only.
                if !fm.fileExists(atPath: p.config.path), let left = try? fm.contentsOfDirectory(atPath: p.dir.path),
                   !left.isEmpty, left.allSatisfy({ $0.hasPrefix("vm.log") }) {
                    try? fm.removeItem(at: p.dir)
                }
                continue
            }
            if cfg.ephemeral {
                // Leftover from a crash: ephemeral VMs never survive a restart.
                try? fm.removeItem(at: p.dir)
                continue
            }
            if let vm = existing(name) {
                loaded.append(vm)
                continue
            }
            let vm = makeInstance(cfg)
            vm.noteUncleanStop()
            // Checked as on create and update: the file may have been changed
            // outside Monad. Such a VM is listed but does not start.
            do {
                try cfg.validate(maxCPUs: .max, maxMemoryGiB: .max)
                try SharePolicy.checkStored(cfg, places: .mac)
                // A Lima VM removed in Lima is listed with why it cannot start.
                if let gone = vm.limaProblem(checkRunning: false) { vm.setFailed(gone) }
            } catch {
                vm.refuseConfig("\(p.config.path) is not valid: \(error.localizedDescription) "
                                + "Monad does not start this VM until its settings are saved again from Monad.")
            }
            loaded.append(vm)
        }
        arrange(loaded, saved: orderStore.load())
        chosenDefault = orderStore.loadDefault().flatMap { existing($0)?.config.ephemeral == false ? $0 : nil }
    }

    /// The default VM's name: the chosen one, else the top of the order.
    var defaultVMName: String? { chosenDefault ?? order.first }

    /// Make Default: `name` is opened first from now on.
    func setDefault(_ name: String) throws {
        guard let vm = existing(name), !vm.config.ephemeral else { throw MonadError("There is no VM called \(name) to make the default.") }
        chosenDefault = name
        saveOrder()
    }

    private func saveOrder() {
        do {
            try orderStore.save(order, defaultVM: chosenDefault)
        } catch {
            Log.vm.error("saving the VM order failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `list` in the order `saved` gives (VMOrder.arrange).
    private func arrange(_ list: [VMInstance], saved: [String]) {
        let names = VMOrder.arrange(list.map(\.name), ephemeral: Set(list.filter(\.config.ephemeral).map(\.name)),
                                    saved: saved)
        let byName = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = names.compactMap { byName[$0] }
        let persistent = ordered.filter { !$0.config.ephemeral }.map(\.name)
        if order != persistent { order = persistent }
        instances = ordered
    }

    /// Arrange again with `saved` (and `adding`, a VM just made) and keep
    /// the order on disk when it changed.
    private func setOrder(_ saved: [String], adding: VMInstance? = nil) {
        let before = order
        arrange(instances + (adding.map { [$0] } ?? []), saved: saved)
        if let d = chosenDefault, !order.contains(d) { chosenDefault = nil }
        guard order != before else { return }
        saveOrder()
    }

    /// The VMs in `names` first, the others after them: a drag in the
    /// Virtual Machines list or Make Default. Unknown and ephemeral names
    /// are ignored.
    func reorder(_ names: [String]) {
        setOrder(VMOrder.reordered(order, requested: names))
    }

    func existing(_ name: String) -> VMInstance? {
        instances.first { $0.name == name }
    }

    /// The VM whose name is `name` in any case: the Mac's disk does not tell
    /// "Web" from "web", so they would share a folder.
    func sameName(_ name: String) -> VMInstance? {
        instances.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func isNameTaken(_ name: String) -> Bool { sameName(name) != nil || isBeingCopied(name) }

    /// Names of copies whose files are being made.
    private var copying: Set<String> = []

    private func isBeingCopied(_ name: String) -> Bool {
        copying.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Traffic between VMs on the Monad networks (none without them).
    func traffic() async throws -> [VMTraffic] {
        try await env.networks?.traffic() ?? []
    }

    /// The default VM: the top of the order, or "default", made on first
    /// use, when there is no VM to open.
    func defaultInstance() -> VMInstance {
        defaultVMName.flatMap(existing) ?? instance(named: Self.defaultName)
    }

    /// Return the instance, creating it in the background when missing. The
    /// returned object reports progress through its `state`.
    func instance(named name: String, config: InstanceConfig? = nil) -> VMInstance {
        if let vm = existing(name) {
            guard vm.creationFailed else { return vm }
            // Made again by its name: tried afresh.
            discardFailedCreation(vm)
        }
        var cfg = config ?? InstanceConfig.defaults(name: name)
        // What runs in it comes from its distribution, once.
        if let os = guestOS(ofDistro: cfg.distro) { cfg.guestOS = os }
        let vm = makeInstance(cfg)
        // A new VM goes to the bottom.
        setOrder(order + (cfg.ephemeral ? [] : [name]), adding: vm)
        vm.setPreparing("Preparing VM \(name)…")
        creating[name] = Task { @MainActor in
            defer { self.creating[name] = nil }
            do {
                try await self.provision(vm, config: cfg)
                vm.setStopped()
                let asked = self.startWhenMade.remove(name) != nil
                if asked || self.sessionCounts[name, default: 0] > 0 { vm.start() }
                return vm
            } catch {
                Log.vm.error("creating \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                vm.note("creating the VM failed: \(error.localizedDescription)")
                self.startWhenMade.remove(name)
                if cfg.ephemeral {
                    vm.setFailed(error.localizedDescription)
                    // Its log's last lines written first: a write after would leave the folder behind.
                    vm.log.flush()
                    try? FileManager.default.removeItem(at: vm.paths.dir)
                    self.instances.removeAll { $0 === vm }
                } else {
                    // Listed with why, and its log; nothing else of it is kept.
                    vm.setCreationFailed(error.localizedDescription)
                    vm.log.flush()
                    Self.removeAllButTheLog(vm.paths.dir)
                }
                throw error
            }
        }
        return vm
    }

    /// Create a new VM with explicit settings.
    @discardableResult
    /// What runs in VMs of a distribution (nil: it is not known here).
    func guestOS(ofDistro id: String) -> GuestOS? { distros()?.distro(id)?.guestOS }

    func create(_ config: InstanceConfig) throws -> VMInstance {
        guard InstanceConfig.isValidName(config.name) else {
            throw MonadError("Names use letters, digits and dashes (max 32).")
        }
        if let other = sameName(config.name) {
            guard other.creationFailed else { throw MonadError("A VM named \(other.name) already exists.") }
            discardFailedCreation(other)
        }
        guard !isBeingCopied(config.name) else { throw MonadError("A VM named \(config.name) is being made.") }
        guard !FileManager.default.fileExists(atPath: paths(for: config.name).config.path) else {
            throw MonadError("A VM named \(config.name) already exists.")
        }
        // Said now, in the New VM sheet, rather than by a VM that fails and goes.
        guard distros()?.distro(config.distro) != nil else {
            throw MonadError("This Monad does not know the distribution \(config.distro).")
        }
        // Two VMs on one Lima disk could run at once and corrupt it.
        if let attached = config.attached {
            let dir = SharePolicy.resolve(attached.dir)
            if let other = instances.first(where: { $0.config.attached.map { SharePolicy.resolve($0.dir) } == dir }) {
                throw MonadError("The Lima VM “\(attached.instance)” is already in Monad as “\(other.name)”.")
            }
        }
        return instance(named: config.name, config: config)
    }

    /// What a copy of a macOS VM takes from it: the disk and auxiliary
    /// storage cloned (APFS: no room until they change), the rest copied.
    /// Its machine identifier is its own.
    private static let clonedFiles: [KeyPath<InstancePaths, URL>] = [\.disk, \.auxStorage]
    private static let copiedFiles: [KeyPath<InstancePaths, URL>] = [
        \.hardwareModel, \.macPassword, \.macSetupDone, \.privateKey, \.publicKey, \.knownHosts,
        \.macSIPStatus, \.macFullDiskAccess, \.appliedProfiles,
    ]

    /// A copy of a stopped macOS VM named `name`, with `settings` (checked
    /// by the caller as for create; the source's by default). What is on
    /// its disk (the system, the account) comes from the source whatever
    /// `settings` says, and its network cards get new addresses.
    func clone(_ source: VMInstance, as name: String, settings: InstanceConfig? = nil) async throws -> VMInstance {
        guard source.config.guestOS == .macos else {
            throw MonadError("Only macOS VMs can be copied for now.")
        }
        guard !source.isRunning else {
            throw MonadError("Stop \(source.name) first: its disk is in use while it runs.")
        }
        guard !source.state.isPreparing, !source.creationFailed,
              FileManager.default.fileExists(atPath: source.paths.disk.path) else {
            throw MonadError("\(source.name) is not made yet: there is nothing to copy.")
        }
        guard InstanceConfig.isValidName(name) else { throw MonadError("Names use letters, digits and dashes (max 32).") }
        if let other = sameName(name) { throw MonadError("A VM named \(other.name) already exists.") }
        guard !isBeingCopied(name), !FileManager.default.fileExists(atPath: paths(for: name).dir.path) else {
            throw MonadError("A VM named \(name) already exists.")
        }
        copying.insert(name)
        defer { copying.remove(name) }
        var cfg = settings ?? source.config
        cfg.name = name
        cfg.ephemeral = false
        cfg.guestOS = source.config.guestOS
        cfg.distro = source.config.distro
        cfg.release = source.config.release
        cfg.user = source.config.user
        cfg.diskGiB = source.config.diskGiB
        for i in cfg.networks.indices { cfg.networks[i].macAddress = nil }

        let from = source.paths, to = paths(for: name)
        try Paths.ensurePrivateDirectory(to.dir)
        do {
            let clones = Self.clonedFiles.map { (from[keyPath: $0], to[keyPath: $0]) }
            try await Task.detached {
                for (src, dst) in clones {
                    let rc = mnd_disk_clone(src.path, dst.path)
                    guard rc == 0 else {
                        throw MonadError("Could not copy \(src.lastPathComponent): \(String(cString: strerror(rc))).")
                    }
                }
            }.value
            let fm = FileManager.default
            for file in Self.copiedFiles where fm.fileExists(atPath: from[keyPath: file].path) {
                try fm.copyItem(at: from[keyPath: file], to: to[keyPath: file])
            }
            for secret in [to.privateKey, to.macPassword] where fm.fileExists(atPath: secret.path) {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            }
            try VZMacInstaller.newMachineIdentifier().write(to: to.macMachineID, options: .atomic)
            try cfg.save(to: to.config)
        } catch {
            try? FileManager.default.removeItem(at: to.dir)
            throw error
        }
        let vm = makeInstance(cfg)
        vm.note("copied from \(source.name)")
        vm.setStopped()
        setOrder(order + [name], adding: vm)
        return vm
    }

    /// A VM that could not be made, gone for one made again in its place.
    private func discardFailedCreation(_ vm: VMInstance) {
        instances.removeAll { $0 === vm }
        vm.log.flush()
        try? FileManager.default.removeItem(at: vm.paths.dir)
        setOrder(order.filter { $0 != vm.name })
    }

    /// What a VM that could not be made leaves: its log only.
    private static func removeAllButTheLog(_ dir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix("vm.log") {
            try? fm.removeTree(at: dir.appendingPathComponent(name))
        }
    }

    func createEphemeral() -> VMInstance {
        var name: String
        repeat {
            name = "tmp-" + String(UUID().uuidString.prefix(6)).lowercased()
        } while isNameTaken(name)
        return instance(named: name, config: InstanceConfig.defaults(name: name, ephemeral: true))
    }

    private func provision(_ vm: VMInstance, config: InstanceConfig) async throws {
        let paths = vm.paths
        try Paths.ensurePrivateDirectory(root)
        // A directory without instance.json is a leftover from an interrupted
        // creation: start over.
        if !FileManager.default.fileExists(atPath: paths.config.path) {
            try? FileManager.default.removeItem(at: paths.dir)
        }
        try Paths.ensurePrivateDirectory(paths.dir)

        let name = config.name
        var config = config
        if let attached = config.attached {
            // A Lima VM's disk is used where it is: no image, no copy.
            try LimaDisk.check(dir: URL(fileURLWithPath: attached.dir, isDirectory: true))
            config.image = "Lima VM “\(attached.instance)”"
        } else if let source = config.copiedFrom {
            try await copyLimaDisk(source, into: vm)
            config.image = "Copy of Lima VM “\(source.instance)”"
        } else if config.guestOS == .macos {
            guard env.allowsMacGuests else { throw MonadError("Monad cannot make macOS VMs yet.") }
            try await installMac(vm, config: &config)
            try config.save(to: paths.config)
            vm.setProvisionedConfig(config)
            return
        } else {
            let base = try await images.baseImage(distro: config.distro, release: config.release) { message in
                Task { @MainActor in vm.reportProgress(message) }
            }
            vm.setPreparing("Creating disk for \(name)…")

            var free: UInt64 = 0
            if mnd_disk_free_bytes(paths.dir.path, &free) == 0, free < minimumFreeBytes {
                throw MonadError("Not enough free disk space (need at least \(minimumFreeBytes >> 30) GB).")
            }
            let diskPath = paths.disk.path
            let basePath = base.url.path
            let rc = await Task.detached { mnd_disk_clone(basePath, diskPath) }.value
            if rc != 0 { throw MonadError.posix(rc, "Cannot create disk") }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diskPath)
            let grow = mnd_disk_grow(diskPath, UInt64(config.diskGiB) << 30)
            if grow != 0 { throw MonadError.posix(grow, "Cannot size disk") }
            config.image = base.name
            config.release = base.release
        }

        vm.setPreparing("Generating keys and cloud-init seed…")
        guard let guest = guest(for: config) else {
            throw MonadError("This Monad does not know the distribution \(config.distro).")
        }
        try await CloudInit.provision(config: config, guest: guest, paths: paths, runner: env.runner)
        try config.save(to: paths.config)
        vm.setProvisionedConfig(config)
    }

    /// A macOS VM (Phase 14): its restore image (downloaded once and kept, or
    /// a file on the Mac), then Apple's installer writes the disk and the
    /// platform files into the VM's folder. Its account and Monad's way in
    /// are set up after (one admin prompt).
    private func installMac(_ vm: VMInstance, config: inout InstanceConfig) async throws {
        try config.validate(maxCPUs: .max, maxMemoryGiB: .max)
        let base: BaseImage
        if let chosen = config.restoreImage {
            // An IPSW chosen in the New VM sheet: used where it is.
            base = try ImagePipeline.restoreImageFile(URL(fileURLWithPath: chosen), distro: config.distro,
                                                     release: config.release ?? "latest")
        } else {
            base = try await images.baseImage(distro: config.distro, release: config.release) { message in
                Task { @MainActor in vm.reportProgress(message) }
            }
        }
        var free: UInt64 = 0
        let needed = max(minimumFreeBytes, macMinimumFreeBytes)
        if mnd_disk_free_bytes(vm.paths.dir.path, &free) == 0, free < needed {
            throw MonadError("macOS needs about \(needed >> 30) GB free to install; this Mac has \(free >> 30) GB free.")
        }
        vm.setPreparing("Installing macOS…")
        do {
            try await env.macInstaller.install(restoreImage: base.url, paths: vm.paths, diskBytes: UInt64(config.diskGiB) << 30) { f in
                let percent = Int((min(max(f, 0), 1) * 100).rounded())
                Task { @MainActor in vm.reportProgress("Installing macOS — \(percent)%") }
            }
        } catch where VZMachineFactory.isMacOSLimit(error) {
            let running = instances.filter { $0.config.guestOS == .macos && $0.isRunning }.map(\.name)
            throw MonadError("macOS is installed in a macOS VM, and a Mac runs at most two at once"
                             + (running.isEmpty ? "" : " (\(running.joined(separator: " and ")) are running)")
                             + ". Stop one of them, then make \(vm.name) again.")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vm.paths.disk.path)
        config.image = base.name
        config.release = base.release
        config.restoreImage = nil
        try await setUpMac(vm, config: config)
    }

    /// The setup with no setup screens (MacSetup): the VM's key, the files
    /// staged, the user asked once (the app runs the root step), then the
    /// finished disk taken back.
    private func setUpMac(_ vm: VMInstance, config: InstanceConfig) async throws {
        guard let asker = macSetupAsker ?? env.macSetup else {
            throw MonadError("Monad could not ask for your password to finish setting up macOS (the app is not open).")
        }
        guard let guestd = env.guestdBinary else { throw MonadError("monad-guestd is missing from this Monad.") }
        vm.setPreparing("Setting up macOS…")
        try await CloudInit.prepareSSH(config: config, paths: vm.paths, runner: env.runner)
        let password = MacSetup.newPassword()
        try Data(password.utf8).write(to: vm.paths.macPassword, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vm.paths.macPassword.path)
        try MacSetup.stage(config, publicKey: try String(contentsOf: vm.paths.publicKey, encoding: .utf8), password: password,
                           guestd: guestd, agent: try MacSetup.agentScript(), into: vm.paths.macSetupPayload)
        vm.setPreparing("Waiting for your password to finish setting up macOS…")
        do {
            let work = try await asker.authorize(vm: config.name, disk: vm.paths.disk, payload: vm.paths.macSetupPayload)
            try MacSetup.adopt(work: work, into: vm.paths, workParent: asker.workFolderParent)
        } catch {
            try? FileManager.default.removeItem(at: vm.paths.macSetupPayload)
            throw error
        }
        try await firstMacBoot(vm, config: config)
        guard config.fullDiskAccess else {
            try? Data("off".utf8).write(to: vm.paths.macFullDiskAccess, options: .atomic)
            vm.setFullDiskAccessFound(false)
            return
        }
        vm.setPreparing("Giving Monad's sessions full disk access…")
        // The disk can stay locked a moment after the VM stops: tried again.
        for attempt in 1...6 {
            do {
                try await MacSetup.grantFullDiskAccess(disk: vm.paths.disk, runner: env.runner)
                try? Data("on".utf8).write(to: vm.paths.macFullDiskAccess, options: .atomic)
                vm.setFullDiskAccessFound(true)
                break
            } catch {
                // The VM works without it; only protected folders stay closed.
                Log.vm.error("\(config.name, privacy: .public): full disk access not given (try \(attempt)): \(error.localizedDescription, privacy: .public)")
                vm.note("full disk access not given (try \(attempt) of 6): \(error.localizedDescription)")
                if attempt < 6 { await env.clock.sleep(seconds: 5) }
            }
        }
    }

    /// How long a macOS VM's first boot may take until Monad gets in.
    static let macFirstBootTimeout: TimeInterval = 10 * 60
    /// The account copied to the Preboot volume, where recoveryOS looks for
    /// the admins it accepts ("no admin users authorized for recovery"
    /// otherwise: an account made without Setup Assistant is not there).
    static let macPrebootCommand = "sudo -n diskutil apfs updatePreboot / >/dev/null"

    /// A clean shutdown from inside (the account has sudo): the power button
    /// would only ask, at a login window nobody sees.
    static let macShutdownCommand = "sudo -n shutdown -h now"

    /// The first boot, while the VM is made: no network, no shares. The
    /// guest's one-time job sets it up; Monad logs in once (sshd makes its
    /// host keys, the Mac keeps the VM's), then shuts it down from inside,
    /// the order checked on the Mac before full disk access is given.
    private func firstMacBoot(_ vm: VMInstance, config: InstanceConfig) async throws {
        vm.setPreparing("Starting macOS for the first time…")
        var c = config
        c.networks = []
        c.sharing = SharingSettings()
        let m = try env.machines.makeMachine(config: c, paths: vm.paths, nic: nil)
        var ended: VMRuntimeEvent?
        m.onEvent = { ended = $0 }
        defer {
            m.onEvent = nil
            try? FileManager.default.removeItem(at: vm.paths.sshSocket)
        }
        try await m.start()
        try m.startBridge(socketPath: vm.paths.sshSocket.path, port: CloudInit.vsockSSHPort)
        let ssh = CloudInit.sshArguments(config: config, paths: vm.paths)
            + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=no", config.sshHost]
        let began = env.clock.now()
        let deadline = began.addingTimeInterval(Self.macFirstBootTimeout)
        var loggedIn = false
        var told = began
        vm.note("first boot: started, waiting for macOS to answer ssh")
        while !loggedIn, ended == nil, env.clock.now() < deadline {
            if await m.probe(port: CloudInit.vsockSSHPort, timeout: 3),
               let r = try? await env.runner.run("/usr/bin/ssh", ssh + ["true"], stdin: nil, timeout: 30), r.status == 0 {
                loggedIn = true
            } else {
                await env.clock.sleep(seconds: 2)
                if env.clock.now().timeIntervalSince(told) >= 60 {
                    told = env.clock.now()
                    vm.note("first boot: no answer yet after \(Int(told.timeIntervalSince(began))) s")
                }
            }
        }
        if loggedIn { vm.note("first boot: macOS answered after \(Int(env.clock.now().timeIntervalSince(began))) s") }
        guard loggedIn else {
            m.stopBridge()
            if case .failed(let why) = ended { throw MonadError("macOS's first start failed: \(why)") }
            if ended == nil { await m.forceStop() }
            throw MonadError("macOS did not finish its first start in \(Int(Self.macFirstBootTimeout / 60)) minutes.")
        }
        let password = (try? String(contentsOf: vm.paths.macPassword, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let login = config.autoLogin
            ? try? await env.runner.run("/usr/bin/ssh", ssh + [MacSetup.autoLoginOnCommand(user: config.user)],
                                        stdin: MacSetup.kcpassword(password), timeout: 30)
            : try? await env.runner.run("/usr/bin/ssh", ssh + [MacSetup.autoLoginOffCommand], stdin: nil, timeout: 30)
        if login?.status != 0 { vm.note("logging in automatically was not set: \(login?.stderrString ?? "ssh did not run")") }
        let preboot = try? await env.runner.run("/usr/bin/ssh", ssh + [Self.macPrebootCommand], stdin: nil, timeout: 120)
        if preboot?.status != 0 {
            // Only recovery (System Integrity Protection) needs it.
            vm.note("the Preboot volume was not updated: \(preboot?.stderrString ?? "ssh did not run")")
        }
        vm.setPreparing("Shutting macOS down to finish setting it up…")
        _ = try? await env.runner.run("/usr/bin/ssh", ssh + [Self.macShutdownCommand], stdin: nil, timeout: 30)
        m.stopBridge()
        func waitForStop(_ seconds: TimeInterval) async {
            let by = env.clock.now().addingTimeInterval(seconds)
            while ended == nil, env.clock.now() < by { await env.clock.sleep(seconds: 1) }
        }
        await waitForStop(120)
        if ended == nil {
            try? await m.requestStop()
            await waitForStop(30)
        }
        if ended == nil {
            vm.note("first boot: macOS did not shut down, powering it off")
            await m.forceStop()
        } else {
            vm.note("first boot: macOS shut down")
        }
    }

    /// "Copy to Monad": a Lima VM's disk, copied while nothing writes to it
    /// (neither Lima nor a Monad VM booting it in place), as an APFS clone
    /// where it can be, so the copy takes space only as the two differ.
    private func copyLimaDisk(_ source: AttachedDisk, into vm: VMInstance) async throws {
        let dir = URL(fileURLWithPath: source.dir, isDirectory: true)
        try LimaDisk.check(dir: dir)
        if LimaDisk.isRunning(dir: dir) {
            throw MonadError("Lima is running “\(source.instance)”. Stop it first with limactl stop \(source.instance).")
        }
        let folder = SharePolicy.resolve(source.dir)
        if let user = instances.first(where: { $0.isRunning && $0.config.attached.map { SharePolicy.resolve($0.dir) } == folder }) {
            throw MonadError("“\(user.name)” is running the Lima VM “\(source.instance)”. Shut it down first.")
        }
        // Held until the copy is done: the other Monad must not boot it meanwhile.
        guard let lock = try DiskLock.take(LimaDisk.lockFile(in: dir)) else {
            throw MonadError("Another Monad (the release or the debug build) is running the Lima VM “\(source.instance)”. "
                             + "Shut it down there first.")
        }
        defer { lock.release() }
        vm.setPreparing("Copying the disk of Lima VM “\(source.instance)”…")
        var free: UInt64 = 0
        if mnd_disk_free_bytes(vm.paths.dir.path, &free) == 0, free < minimumFreeBytes {
            throw MonadError("Not enough free disk space (need at least \(minimumFreeBytes >> 30) GB).")
        }
        // A migrated Lima VM's `disk` is a link to `diffdisk`, and clonefile
        // copies a link as a link: copy what it leads to (check() made sure
        // that is a file beside it).
        let src = LimaDisk.diskFile(in: dir).resolvingSymlinksInPath().path
        let dst = vm.paths.disk.path
        let rc = await Task.detached { mnd_disk_clone(src, dst) }.value
        if rc != 0 { throw MonadError.posix(rc, "Cannot copy the Lima VM's disk") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst)
    }

    func delete(_ vm: VMInstance) async throws {
        if vm.isRepairing { throw MonadError("\(vm.name)'s disk is being repaired. Delete it once that is done.") }
        startWhenMade.remove(vm.name)
        if let task = creating[vm.name] { _ = try? await task.value }
        if vm.isRunning { await vm.stop() }
        vm.discardMachine()
        vm.log.flush()
        try FileManager.default.removeTree(at: vm.paths.dir)
        instances.removeAll { $0 === vm }
        if !vm.config.ephemeral { setOrder(order.filter { $0 != vm.name }) }
        sessionCounts[vm.name] = nil
    }

    /// VMs asked to start while still being made: they start once made.
    private var startWhenMade: Set<String> = []

    /// Starts `vm`, or, while it is still being made, once it is.
    func start(_ vm: VMInstance) {
        if vm.isRepairing { return }
        if vm.state.isPreparing {
            startWhenMade.insert(vm.name)
        } else {
            vm.start()
        }
    }

    /// A stop asked for while it is still being made: it stays stopped.
    func cancelStart(_ vm: VMInstance) {
        startWhenMade.remove(vm.name)
    }

    // MARK: Session reference counting (drives ephemeral VM lifetime)

    func retain(_ vm: VMInstance) {
        sessionCounts[vm.name, default: 0] += 1
    }

    func release(_ vm: VMInstance) {
        let n = max(0, sessionCounts[vm.name, default: 0] - 1)
        sessionCounts[vm.name] = n
        guard n == 0, vm.config.ephemeral else { return }
        Task { @MainActor in
            Log.vm.info("discarding ephemeral VM \(vm.name, privacy: .public)")
            await vm.forceStop()
            try? await self.delete(vm)
        }
    }

    func sessions(for vm: VMInstance) -> Int { sessionCounts[vm.name, default: 0] }

    // MARK: Shutdown

    var hasRunningVMs: Bool { instances.contains { $0.isRunning } }

    /// Shuts every running VM down; each one's log says why first.
    func stopAll(because reason: String) async {
        await withTaskGroup(of: Void.self) { group in
            for vm in instances where vm.isRunning {
                vm.note("\(reason): shutting the VM down")
                group.addTask { @MainActor in
                    if vm.config.ephemeral { await vm.forceStop() } else { await vm.stop(timeout: 15) }
                }
            }
        }
        for vm in instances where vm.config.ephemeral {
            vm.log.flush()
            try? FileManager.default.removeItem(at: vm.paths.dir)
        }
    }

    /// Every VM's log written out, before MonadHost exits: lines still
    /// queued are lost with the process (the last stop's reason among them).
    func flushLogs() {
        for vm in instances { vm.log.flush() }
    }
}
