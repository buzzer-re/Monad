//
//  NewVMForm.swift — the New VM sheet's choices: distro and release, taken
//  from the distro catalog (no distro is known to this code), macOS's
//  install image, and the network and firewall the VM starts with.
//

import Foundation

struct NewVMForm {
    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private let catalog: DistroCatalog
    private var distroID: String
    private var releaseID: String
    private var definitions: [NetworkDefinition] = [.builtInDefault]

    struct ProfileChoice: Identifiable, Equatable {
        let id: String
        let name: String
        let summary: String
        /// It has what the chosen distro's package manager needs.
        let supported: Bool
    }

    private var profileCatalog = ProfileCatalog(builtIn: [], custom: [])
    private var chosenProfiles: [String] = []

    /// A macOS restore image kept on this Mac (Settings › Distributions).
    struct KeptRestoreImage: Equatable {
        let path: String
        let bytes: Int64
    }

    /// The restore image choice that is the latest from Apple.
    static let latestRestoreImage = ""
    private var keptRestoreImages: [KeptRestoreImage] = []
    private var chosenRestoreImage: String?
    /// macOS: the restore image to install from (`latestRestoreImage` or a file's path).
    var restoreImage = NewVMForm.latestRestoreImage
    /// macOS: System Integrity Protection off (turned off in recovery at the first start).
    var disableSIP = false
    /// macOS: Monad's sessions may read protected folders (Documents, …).
    var fullDiskAccess = true
    /// macOS: it logs in by itself at boot.
    var autoLogin = true

    /// The Monad network the VM joins; nil: no network device at all.
    var network: String? = NetworkDefinition.defaultName
    var firewall = VMFirewall()
    /// Images in the terminal: off unless chosen.
    var inlineImages = false

    init(catalog: DistroCatalog) {
        self.catalog = catalog
        let d = catalog.defaultDistro
        distroID = d?.id ?? ""
        releaseID = d?.defaultRelease.id ?? ""
    }

    /// Every distro VMs can be made of now, sorted by name.
    var distros: [Choice] {
        catalog.distros.filter { GuestOS.ready.contains($0.guestOS) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { Choice(id: $0.id, name: $0.name) }
    }

    private var selected: DistroConfig? { catalog.distro(distroID) }

    /// Selecting a distro also selects its default release.
    var distro: String {
        get { distroID }
        set {
            guard let d = catalog.distro(newValue) ?? catalog.defaultDistro else { return }
            distroID = d.id
            releaseID = d.defaultRelease.id
        }
    }

    var releases: [Choice] { selected?.releases.map { Choice(id: $0.id, name: $0.name) } ?? [] }

    /// macOS: an install image to choose instead of a release, and more room.
    var isMac: Bool { selected?.guestOS == .macos }
    var minimumMemoryGiB: Int { isMac ? InstanceConfig.macMinimumMemoryGiB : 1 }
    var minimumDiskGiB: Int { isMac ? InstanceConfig.macMinimumDiskGiB : 10 }

    /// The latest from Apple, the images kept on this Mac, a file chosen.
    var restoreImages: [Choice] {
        var list = [Choice(id: Self.latestRestoreImage, name: "The latest macOS for this Mac (downloaded once, about 25 GB)")]
        list += keptRestoreImages.map {
            let gb = Int((Double($0.bytes) / 1_000_000_000).rounded())
            return Choice(id: $0.path, name: "\((($0.path as NSString).lastPathComponent)) (kept on this Mac, \(gb) GB)")
        }
        if let file = chosenRestoreImage {
            list.append(Choice(id: file, name: (file as NSString).lastPathComponent))
        }
        return list
    }

    /// The restore images kept on this Mac; a chosen one that went away
    /// gives way to the latest.
    mutating func setKeptRestoreImages(_ list: [KeptRestoreImage]) {
        keptRestoreImages = list
        if !restoreImages.contains(where: { $0.id == restoreImage }) { restoreImage = Self.latestRestoreImage }
    }

    /// An IPSW file chosen on this Mac.
    mutating func chooseRestoreImage(path: String) {
        if !keptRestoreImages.contains(where: { $0.path == path }) { chosenRestoreImage = path }
        restoreImage = path
    }

    var release: String {
        get { releaseID }
        set {
            guard let d = selected else { return }
            releaseID = d.releases.contains { $0.id == newValue } ? newValue : d.defaultRelease.id
        }
    }

    /// The selected distro's images are checked against something.
    var imagesAreChecked: Bool { selected?.image.checksums != nil }

    /// How images of the selected distro are checked, for the user.
    var verification: String {
        guard let d = selected else { return "" }
        switch d.image.signature.kind {
        case .detached, .clearsigned:
            return "Images are checked against checksums signed with \(d.name)'s OpenPGP key, which ships with Monad."
        case .none where d.image.checksums == nil:
            return "This image is used as it is: there is nothing to check it against."
        case .none:
            return d.image.signature.note ?? "Images are checked against checksums fetched over HTTPS."
        }
    }

    /// The profiles there are (built-in, then the user's).
    mutating func setProfiles(_ catalog: ProfileCatalog) {
        profileCatalog = catalog
        chosenProfiles = chosenProfiles.filter { catalog.profile($0) != nil }
    }

    var profileChoices: [ProfileChoice] {
        // macOS has no package manager to set profiles up with.
        if isMac { return [] }
        let manager = selected?.guest.packageManager ?? ""
        return profileCatalog.all.map {
            ProfileChoice(id: $0.id, name: $0.name, summary: $0.summary, supported: $0.supports(packageManager: manager))
        }
    }

    func isChosen(_ id: String) -> Bool { chosenProfiles.contains(id) }

    /// A profile was made from the sheet: the profiles again, and it chosen.
    mutating func profileCreated(_ id: String, catalog: ProfileCatalog) {
        setProfiles(catalog)
        if catalog.profile(id) != nil, !chosenProfiles.contains(id) { chosenProfiles.append(id) }
    }

    mutating func toggleProfile(_ id: String) {
        if let i = chosenProfiles.firstIndex(of: id) { chosenProfiles.remove(at: i) } else { chosenProfiles.append(id) }
    }

    /// The networks there are (Settings › Networks). A chosen network that
    /// is not among them any more gives way to the default one.
    mutating func setNetworks(_ list: [NetworkDefinition]) {
        definitions = list
        if let n = network, !list.contains(where: { $0.name == n }) { network = NetworkDefinition.defaultName }
    }

    /// Every network, with its kind and subnet.
    var networks: [Choice] {
        definitions.map { Choice(id: $0.name, name: "\($0.name) (\($0.kind.title), \($0.subnet))") }
    }

    /// Whether the firewall has anything to decide: only NAT networks lead out.
    var firewallApplies: Bool {
        guard let n = network else { return false }
        return definitions.first { $0.name == n }?.kind == .nat
    }

    func apply(to config: InstanceConfig) -> InstanceConfig {
        var c = config
        c.distro = distroID
        c.release = releaseID
        c.guestOS = selected?.guestOS ?? .linux
        c.networks = network.map { [NetworkAttachment(network: $0, macAddress: nil)] } ?? []
        c.firewall = firewall
        c.inlineImages = inlineImages
        let supported = Set(profileChoices.filter(\.supported).map(\.id))
        c.profiles = chosenProfiles.filter { supported.contains($0) }
        c.restoreImage = isMac && restoreImage != Self.latestRestoreImage ? restoreImage : nil
        c.systemIntegrityProtection = !(isMac && disableSIP)
        c.fullDiskAccess = !isMac || fullDiskAccess
        c.autoLogin = !isMac || autoLogin
        return c
    }
}
