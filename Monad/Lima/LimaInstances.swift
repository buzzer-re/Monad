//
//  LimaInstances.swift — the Lima VMs on this Mac, for booting one in place
//  (Phase 9): read from `limactl list --json` (one JSON object per line), or,
//  without limactl, from a scan of ~/.lima (no YAML parser: only what the
//  folder itself says). Which ones Monad can boot, and why not, is
//  LimaDisk.problem; the distro is DistroCatalog.recognize.
//
//  Everything here is the user's own files; Monad only reads them, and a
//  Lima VM it boots keeps working in Lima afterwards. Lima's own rules
//  (file names, default user and home, host name) follow Lima's source:
//  pkg/limatype/filenames, pkg/osutil/user.go, pkg/instance/hostname.
//

import Foundation

struct LimaInstance: Equatable, Sendable, Identifiable {
    enum Status: String, Sendable {
        case running = "Running", stopped = "Stopped", broken = "Broken", unknown = "Unknown"
        case installing = "Installing", uninitialized = "Uninitialized"
    }

    struct Mount: Equatable, Sendable {
        var location: String
        var mountPoint: String?
        var writable: Bool
    }

    var name: String
    var dir: URL
    var status: Status
    /// "vz" (Apple's virtualization) or "qemu".
    var vmType: String
    /// "aarch64" or "x86_64"; empty when not known.
    var arch: String
    var cpus: Int?
    var memoryBytes: Int64?
    /// Where Lima took the image from (URLs or files).
    var imageLocations: [String]
    /// The guest user and home Lima set up (/home/<user>.guest by default
    /// since Lima 2.1, /home/<user>.linux before).
    var user: String
    var home: String
    var mounts: [Mount]
    /// The disk's size in bytes, when known.
    var diskBytes: Int64? = nil
    /// Lima's user.passwordlessSudo; nil when not known.
    var passwordlessSudo: Bool? = nil

    var id: String { name }
    /// The disk Monad boots: Lima's own, where it is.
    var disk: URL { LimaDisk.diskFile(in: dir) }
}

struct LimaInstances {
    var runner: CommandRunning
    var limactlCandidates = ["/opt/homebrew/bin/limactl", "/usr/local/bin/limactl"]
    var limaHome = Paths.home.appendingPathComponent(".lima", isDirectory: true)
    /// Lima's default guest user is the Mac user's name.
    var macUser = InstanceConfig.guestUserName()

    /// The instances limactl knows, else those found in ~/.lima; by name.
    func list() async -> [LimaInstance] {
        if let limactl = limactlCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           let r = try? await runner.run(limactl, ["list", "--json"], timeout: 15), r.status == 0 {
            return Self.parseList(r.stdoutString, macUser: macUser)
        }
        return Self.scan(limaHome, macUser: macUser)
    }

    // MARK: limactl list --json

    private struct Entry: Decodable {
        var name: String
        var status: String?
        var dir: String
        var vmType: String?
        var arch: String?
        var cpus: Int?
        var memory: Int64?
        var disk: Int64?
        var limaVersion: String?
        var config: Config?

        struct Config: Decodable {
            var images: [Image]?
            var mounts: [Mount]?
            var user: User?

            struct Image: Decodable { var location: String }
            struct Mount: Decodable {
                var location: String
                var mountPoint: String?
                var writable: Bool?
            }
            struct User: Decodable {
                var name: String?
                var home: String?
                var passwordlessSudo: Bool?
            }
        }
    }

    /// One instance per line; lines that are not one are skipped.
    static func parseList(_ text: String, macUser: String) -> [LimaInstance] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let e = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), isName(e.name),
                  e.dir.hasPrefix("/") else { return nil }
            let user = e.config?.user?.name ?? defaultUser(macUser, version: e.limaVersion)
            return LimaInstance(
                name: e.name, dir: URL(fileURLWithPath: e.dir, isDirectory: true),
                status: LimaInstance.Status(rawValue: e.status ?? "") ?? .unknown,
                vmType: e.vmType ?? "qemu", arch: e.arch ?? "", cpus: e.cpus, memoryBytes: e.memory,
                imageLocations: e.config?.images?.map(\.location) ?? [],
                user: user, home: e.config?.user?.home ?? defaultHome(user, version: e.limaVersion),
                mounts: e.config?.mounts?.map {
                    LimaInstance.Mount(location: expandHome($0.location), mountPoint: $0.mountPoint,
                                       writable: $0.writable ?? false)
                } ?? [],
                diskBytes: e.disk, passwordlessSudo: e.config?.user?.passwordlessSudo)
        }
    }

    // MARK: Scanning ~/.lima

    /// Folders holding a lima.yaml; vz when Lima left a vz-identifier or the
    /// file says so. Image locations are read from its `location:` lines.
    static func scan(_ limaHome: URL, macUser: String) -> [LimaInstance] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: limaHome.path)) ?? []
        return names.sorted().compactMap { name in
            guard isName(name), !name.hasPrefix("_") else { return nil }
            let dir = limaHome.appendingPathComponent(name, isDirectory: true)
            guard let yaml = try? String(contentsOf: dir.appendingPathComponent("lima.yaml"), encoding: .utf8) else {
                return nil
            }
            let vz = fm.fileExists(atPath: dir.appendingPathComponent("vz-identifier").path)
                || yaml.range(of: #"(?m)^vmType:\s*"?vz"?\s*$"#, options: .regularExpression) != nil
            let size = (try? fm.attributesOfItem(atPath: LimaDisk.diskFile(in: dir).path))?[.size] as? NSNumber
            let version = (try? String(contentsOf: dir.appendingPathComponent("lima-version"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let user = defaultUser(macUser, version: version)
            return LimaInstance(name: name, dir: dir, status: LimaDisk.isRunning(dir: dir) ? .running : .stopped,
                                vmType: vz ? "vz" : "qemu", arch: "", cpus: nil, memoryBytes: nil,
                                imageLocations: locations(in: yaml), user: user, home: defaultHome(user, version: version),
                                mounts: [], diskBytes: size?.int64Value)
        }
    }

    private static func locations(in yaml: String) -> [String] {
        yaml.split(whereSeparator: \.isNewline).compactMap { line in
            guard let r = line.range(of: #"location:\s*"?([^"\s]+)"?"#, options: .regularExpression) else { return nil }
            let value = line[r].drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    // MARK: Lima's defaults (pkg/osutil/user.go)

    /// The Mac user's name, except "admin", which Lima 1.0 and later
    /// replaces with "lima".
    static func defaultUser(_ macUser: String, version: String?) -> String {
        macUser == "admin" && atLeast(version, [1, 0, 0]) ? "lima" : macUser
    }

    /// /home/<user>.guest for instances made by Lima 2.1 and later (or a
    /// development build, "<unknown>"), /home/<user>.linux before. Lima's
    /// boot script links each name to the other.
    static func defaultHome(_ user: String, version: String?) -> String {
        version == "<unknown>" || atLeast(version, [2, 1, 0]) ? "/home/\(user).guest" : "/home/\(user).linux"
    }

    /// "2.1.0", "v2.1.0" or "2.1.0-rc.1" at least `minimum`; an empty or
    /// unreadable version (instances older than Lima 0.20) is not.
    private static func atLeast(_ version: String?, _ minimum: [Int]) -> Bool {
        guard var v = version, !v.isEmpty else { return false }
        if v.hasPrefix("v") { v.removeFirst() }
        let parts = v.prefix { $0 != "-" && $0 != "+" }.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return false }
        let numbers = parts.compactMap { $0 } + Array(repeating: 0, count: max(0, minimum.count - parts.count))
        return !numbers.lexicographicallyPrecedes(minimum)
    }

    /// Lima's names: letters, digits, '-', '_' and '.', never a path.
    private static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s != "." && s != ".."
            && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    private static func expandHome(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? Paths.home.path + path.dropFirst() : path
    }
}

/// Whether Monad can boot a Lima VM's disk in place.
enum LimaDisk {
    /// Lima's name for this Mac's architecture.
    static var hostArch: String {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine == "arm64" ? "aarch64" : machine
    }

    /// Why Monad cannot boot it in place now, nil when it can.
    static func problem(_ i: LimaInstance, hostArch: String = hostArch) -> String? {
        guard i.vmType == "vz" else {
            return "Lima runs “\(i.name)” with QEMU. Only VMs Lima runs with Apple's virtualization (vmType vz) can be used in place."
        }
        if !i.arch.isEmpty, i.arch != hostArch { return "“\(i.name)” is an \(i.arch) VM, and this Mac runs \(hostArch) ones." }
        guard FileManager.default.fileExists(atPath: i.disk.path) else { return "“\(i.name)” has no disk yet. Start it once in Lima." }
        if isQcow2(i.disk) { return "The disk of “\(i.name)” is in QEMU's format, which Apple's virtualization cannot open." }
        if i.status == .running || isRunning(dir: i.dir) {
            return "Lima is running “\(i.name)”. Stop it first with limactl stop \(i.name)."
        }
        switch i.status {
        case .installing: return "Lima is still setting up “\(i.name)”."
        case .broken: return "Lima reports “\(i.name)” as broken. limactl list says why."
        case .running, .stopped, .unknown, .uninitialized: break
        }
        // Monad runs sudo -n in the guest (its isolation, shares, agent).
        if i.passwordlessSudo == false {
            return "Lima set up “\(i.name)” so that sudo asks for a password. Monad needs passwordlessSudo, Lima's default."
        }
        return nil
    }

    /// MonadHost boots only a Lima VM's own disk: a folder with a lima.yaml
    /// and its disk, a regular file (not a device), or for a migrated
    /// instance a link to one beside it.
    static func check(dir: URL) throws {
        func kind(_ url: URL) -> FileAttributeType? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        }
        guard kind(dir.appendingPathComponent("lima.yaml")) == .typeRegular else {
            throw MonadError("\(dir.path) is not a Lima VM's folder (no lima.yaml).")
        }
        let disk = diskFile(in: dir)
        var plain = kind(disk) == .typeRegular
        if kind(disk) == .typeSymbolicLink {
            let target = disk.resolvingSymlinksInPath()
            plain = target.deletingLastPathComponent().path == dir.resolvingSymlinksInPath().path
                && kind(target) == .typeRegular
        }
        guard plain else {
            throw MonadError("\(dir.path) has no disk Monad can use (it is missing or not a plain file).")
        }
    }

    /// Lima's disk: `disk` since Lima 2.1 (in migrated instances a link to
    /// `diffdisk`), `diffdisk` before.
    static func diskFile(in dir: URL) -> URL {
        let disk = dir.appendingPathComponent("disk")
        return (try? FileManager.default.attributesOfItem(atPath: disk.path)) != nil
            ? disk : dir.appendingPathComponent("diffdisk")
    }

    /// The lock (DiskLock) a Monad holds while it boots or copies the disk
    /// of the Lima VM in `dir`.
    static func lockFile(in dir: URL) -> URL { dir.appendingPathComponent("monad.lock") }

    /// Lima's host agent holds <dir>/ha.pid while it runs the instance.
    static func isRunning(dir: URL) -> Bool {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("ha.pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func isQcow2(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x51, 0x46, 0x49, 0xFB])
    }
}

extension DistroCatalog {
    /// The distro an image comes from, recognized by the download host in
    /// each distro's own file (the same host, or another under its domain),
    /// and the release when the URL names one Monad has (its id or one of its
    /// values, such as a codename, as a path segment).
    func recognize(imageLocations: [String]) -> (distro: String, release: String?)? {
        for location in imageLocations {
            guard let url = URL(string: location), url.scheme == "https" || url.scheme == "http",
                  let host = url.host?.lowercased() else { continue }
            let segments = Set(url.pathComponents)
            for d in distros {
                guard let site = Self.site(of: d) else { continue }
                let domain = site.split(separator: ".").suffix(2).joined(separator: ".")
                guard host == site || host == domain || host.hasSuffix("." + domain) else { continue }
                let release = d.releases.first { r in
                    !segments.isDisjoint(with: [r.id] + (r.vars.map { Array($0.values) } ?? []))
                }
                return (d.id, release?.id)
            }
        }
        return nil
    }

    /// The host a distro's checksum file is fetched from.
    private static func site(of d: DistroConfig) -> String? {
        guard let template = d.image.checksums?.url ?? d.image.checksums?.index ?? Optional(d.image.url),
              let start = template.range(of: "://")?.upperBound else { return nil }
        let host = template[start...].prefix { $0 != "/" }
        return host.isEmpty || host.contains("{") ? nil : host.lowercased()
    }
}
