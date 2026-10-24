//
//  LimaList.swift — the Lima tab of the Virtual Machines window (Phase 9):
//  the Lima VMs on this Mac, each with what it is, why Monad cannot use it,
//  or the Monad VM that already does; and the settings of a Monad VM that
//  boots one where it is ("Use in Monad") or a copy of its disk ("Copy to
//  Monad"). Everything is taken from Lima, its shared folders included
//  (within SharePolicy): nothing is asked but the user's word on folders
//  that need it.
//

import Foundation

struct LimaList {
    struct Row: Identifiable, Equatable {
        /// The Lima instance's name.
        let id: String
        let detail: String
        /// Why Monad cannot use it now; nil when it can, or already does.
        let problem: String?
        /// The Monad VM that uses it.
        let monadVM: String?
    }

    /// In place: Monad boots the Lima VM's disk where it is. Copy: a VM of
    /// Monad's own from a copy of the disk.
    enum Mode { case inPlace, copy }

    /// What making the VM would do, for the user to see first.
    struct Plan {
        var config: InstanceConfig
        /// The folders shared with it: "~, read-only".
        var folders: [String]
        /// Lima's folders left out, and why.
        var notes: [String]
        /// A folder needs the user's word (SharePolicy): ask before making it.
        var needsConfirmation: Bool
    }

    private let catalog: DistroCatalog
    private let places: SharePolicy.Places
    private let folderExists: (String) -> Bool
    private var found: [(instance: LimaInstance, problem: String?)] = []
    private(set) var loaded = false
    /// The folders of the Lima VMs Monad has, and their Monad VM.
    var inMonad: [String: String] = [:]

    init(catalog: DistroCatalog, places: SharePolicy.Places = .mac,
         folderExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.catalog = catalog
        self.places = places
        self.folderExists = folderExists
    }

    /// The Lima VMs found, with why each cannot be used (LimaDisk.problem).
    mutating func setFound(_ found: [(instance: LimaInstance, problem: String?)]) {
        self.found = found
        loaded = true
    }

    var rows: [Row] {
        found.map { i, problem in
            if let vm = monadVM(i) { return Row(id: i.name, detail: detail(of: i), problem: nil, monadVM: vm) }
            // The distribution decides how Monad sets the VM up.
            let unknown = catalog.recognize(imageLocations: i.imageLocations) == nil
                ? "Monad does not recognize the distribution of “\(i.name)” from its image." : nil
            return Row(id: i.name, detail: detail(of: i), problem: problem ?? unknown, monadVM: nil)
        }
    }

    /// The VM a Lima VM would make, with Lima's settings (CPUs and memory
    /// within what this Mac gives a VM) and folders; nil when it cannot be
    /// used. A Lima VM in Monad already can still be copied. `taken`: the
    /// names of Monad's VMs.
    func plan(_ id: String, _ mode: Mode, taken: Set<String>, capacity: HostCapacity) -> Plan? {
        guard let entry = found.first(where: { $0.instance.name == id }), entry.problem == nil,
              let distro = catalog.recognize(imageLocations: entry.instance.imageLocations) else { return nil }
        let i = entry.instance
        if mode == .inPlace, monadVM(i) != nil { return nil }
        let name = Self.nameable(i.name)
        var c = InstanceConfig.defaults(name: unique(mode == .inPlace ? "lima-" + name : name + "-copy", taken: taken))
        c.distro = distro.distro
        c.release = distro.release
        let lima = AttachedDisk(lima: i.name, dir: i.dir.path, home: i.home)
        switch mode {
        case .inPlace: c.attached = lima
        case .copy: c.copiedFrom = lima
        }
        c.user = i.user
        if let n = i.cpus { c.cpus = capacity.clampCPUs(n) }
        if let m = gib(i.memoryBytes) { c.memoryGiB = capacity.clampMemory(m) }
        if let d = gib(i.diskBytes) { c.diskGiB = d }
        var plan = Plan(config: c, folders: [], notes: [], needsConfirmation: false)
        share(i.mounts, into: &plan)
        return plan
    }

    /// Lima's folders, shared as Lima shares them where SharePolicy allows:
    /// one Monad never shares, or cannot mount where Lima does, is left out,
    /// and a writable one that holds Monad's own folder is shared read-only.
    private func share(_ mounts: [LimaInstance.Mount], into plan: inout Plan) {
        var guestPaths = Set<String>()
        for m in mounts {
            let shown = display(m.location)
            guard folderExists(m.location) else {
                plan.notes.append("\(shown) is left out: it is not on this Mac.")
                continue
            }
            let path = SharePolicy.resolve(m.location)
            var readOnly = !m.writable
            var verdict = SharePolicy.verdict(path, readOnly: readOnly, places: places)
            var line = "\(shown), \(readOnly ? "read-only" : "writable")"
            if case .refused = verdict, !readOnly {
                let asReadOnly = SharePolicy.verdict(path, readOnly: true, places: places)
                if asReadOnly != verdict {
                    verdict = asReadOnly
                    readOnly = true
                    line = "\(shown), read-only (Lima lets the VM write there, but it holds Monad's own folder)"
                }
            }
            // Refused even read-only: SharePolicy's one such case.
            if case .refused = verdict {
                let home = SharePolicy.resolve(places.home)
                let holdsHome = path == "/" || home.hasPrefix(path.hasSuffix("/") ? path : path + "/")
                plan.notes.append(holdsHome
                    ? "\(shown) is left out: it holds your home folder. Monad shares your home folder, or folders in it, instead."
                    : "\(shown) is left out: it is Monad's own folder.")
                continue
            }
            let guest = m.mountPoint.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? m.location
            guard InstanceConfig.isValidGuestPath(guest), guestPaths.insert(InstanceConfig.normalizedGuestPath(guest)).inserted
            else {
                plan.notes.append("\(shown) is left out: Monad cannot mount it at \(guest).")
                continue
            }
            var folder = SharedFolder(hostPath: m.location, guestPath: guest, readOnly: readOnly)
            if verdict == .needsConfirmation {
                folder.confirmed = true
                plan.needsConfirmation = true
            }
            plan.config.sharing.shares.append(folder)
            plan.folders.append(line)
        }
        if !plan.config.sharing.shares.isEmpty { plan.config.sharing.runtimeEnabled = true }
    }

    /// A Mac path as the user knows it: "~" for the home folder.
    private func display(_ path: String) -> String {
        if path == places.home { return "~" }
        if path.hasPrefix(places.home + "/") { return "~" + path.dropFirst(places.home.count) }
        return path
    }

    private func monadVM(_ i: LimaInstance) -> String? {
        let dir = SharePolicy.resolve(i.dir.path)
        return inMonad.first { SharePolicy.resolve($0.key) == dir }?.value
    }

    private func detail(of i: LimaInstance) -> String {
        var parts = ["Unknown distribution"]
        if let found = catalog.recognize(imageLocations: i.imageLocations), let d = catalog.distro(found.distro) {
            parts[0] = found.release.flatMap { r in d.releases.first { $0.id == r }?.name } ?? d.name
        }
        if let n = i.cpus { parts.append("\(n) CPU\(n == 1 ? "" : "s")") }
        if let m = gib(i.memoryBytes) { parts.append("\(m) GB memory") }
        if let d = gib(i.diskBytes) { parts.append("\(d) GB disk") }
        return parts.joined(separator: " · ")
    }

    /// Bytes as whole GB, rounded up.
    private func gib(_ bytes: Int64?) -> Int? {
        bytes.map { max(1, Int(($0 + (1 << 30) - 1) >> 30)) }
    }

    /// A Lima name in Monad's alphabet (lowercase letters, digits, dashes),
    /// short enough for a prefix or suffix of 5.
    private static func nameable(_ lima: String) -> String {
        String(lima.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(27))
    }

    /// Within Monad's name rules ("default" is Monad's own first VM), made
    /// unique.
    private func unique(_ base: String, taken: Set<String>) -> String {
        var start = String(base.drop { $0 == "-" }.prefix(32))
        if start.isEmpty { start = "lima" }
        var name = start
        var n = 1
        let taken = Set(taken.map { $0.lowercased() }) /* "Web" and "web" share a folder */
        while taken.contains(name.lowercased()) {
            n += 1
            let suffix = "-\(n)"
            name = String(start.prefix(32 - suffix.count)) + suffix
        }
        return name
    }
}
