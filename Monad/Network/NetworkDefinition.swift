//
//  NetworkDefinition.swift — one Monad network (~/.monad/networks/<name>.json):
//  its kind and subnet, whether its VMs reach each other, and the netd
//  command it becomes. Firewalls are each VM's own (Firewall.swift); files
//  from before that have a "firewall" key, which is ignored.
//
//  netd checks everything again; the checks here give precise messages and
//  keep an invalid file from ever reaching it.
//

import Foundation
import os

struct NetworkDefinition: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case nat
        case hostOnly = "host-only"
        case `internal`
        case none
    }

    static let currentVersion = 1
    /// The network new VMs join.
    static let defaultName = "default"
    /// Not a definition: Apple's NAT, which VMs made before Monad networks keep.
    static let appleNATName = "apple-nat"
    static let leaseRange = 60...(7 * 86400)

    var version = NetworkDefinition.currentVersion
    var name: String
    var kind: Kind
    var subnet: String
    /// DHCP lease time; nil means netd's default (one hour).
    var leaseSeconds: Int?
    /// Saved only once chosen: until then, the kind's default.
    private var peers: Bool?
    /// Host-only networks: whether lookups reach the Mac's resolvers (saved
    /// only when on; nothing else leaves such a network).
    private var dns: Bool?

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case version, name, kind, subnet, leaseSeconds
        case peers = "vmsReachEachOther"
        case dns = "lookupsThroughTheMac"
    }

    /// Whether a host-only network's VMs may look names up through the Mac.
    /// Off unless chosen: lookups could carry data out (F-10).
    var lookupsThroughTheMac: Bool {
        get { dns ?? false }
        set { dns = newValue ? true : nil }
    }

    /// Whether VMs on this network reach each other, or only the gateway.
    /// Off for NAT and host-only networks unless chosen, on where nothing
    /// leaves (internal, plain switches).
    var vmsReachEachOther: Bool {
        get { peers ?? (kind == .internal || kind == .none) }
        set { peers = newValue }
    }

    init(name: String, kind: Kind, subnet: String, leaseSeconds: Int? = nil) {
        self.name = name
        self.kind = kind
        self.subnet = subnet
        self.leaseSeconds = leaseSeconds
    }

    static let builtInDefault = NetworkDefinition(name: defaultName, kind: .nat, subnet: "10.77.0.0/24")

    // MARK: Validation

    enum ValidationError: Error, Equatable, LocalizedError {
        case name(String)
        case subnet(String)
        case lease(Int)

        var errorDescription: String? {
            switch self {
            case .name(let n):
                return "“\(n)” is not a valid network name: use lowercase letters, digits and dashes (max 32)."
            case .subnet(let s):
                return "“\(s)” is not a usable subnet: use a private range (10/8, 172.16/12, 192.168/16) "
                    + "written as a.b.c.0/prefix, with a prefix from 8 to 30."
            case .lease(let s): return "\(s) seconds is not a usable lease time (1 minute to 7 days)."
            }
        }
    }

    /// Lowercase letters, digits and dashes: netd and the network's file
    /// use the name as it is.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    func validate() throws {
        guard Self.isValidName(name), name != Self.appleNATName else { throw ValidationError.name(name) }
        guard let cidr = Self.parseCIDR(subnet), (8...30).contains(cidr.prefix), Self.isPrivate(cidr) else {
            throw ValidationError.subnet(subnet)
        }
        if let l = leaseSeconds, !Self.leaseRange.contains(l) { throw ValidationError.lease(l) }
    }

    /// a.b.c.d/prefix with no leading zeros and no host bits set.
    static func parseCIDR(_ s: String) -> (address: UInt32, prefix: Int)? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = parseIPv4(String(parts[0])),
              let prefix = decimal(String(parts[1])), prefix <= 32 else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        guard address & ~mask == 0 else { return nil }
        return (address, prefix)
    }

    static func parseIPv4(_ s: String) -> UInt32? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for o in octets {
            guard let v = decimal(String(o)), v <= 255 else { return nil }
            value = value << 8 | UInt32(v)
        }
        return value
    }

    /// Digits only, no sign, no leading zeros, at most 5 of them.
    private static func decimal(_ s: String) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy({ $0.isASCII && $0.isNumber }),
              s == "0" || !s.hasPrefix("0") else { return nil }
        return Int(s)
    }

    private static func isPrivate(_ c: (address: UInt32, prefix: Int)) -> Bool {
        let ranges: [(UInt32, Int)] = [(0x0A00_0000, 8), (0xAC10_0000, 12), (0xC0A8_0000, 16)]
        return ranges.contains { base, bits in
            let mask: UInt32 = ~UInt32(0) << (32 - UInt32(bits))
            return c.prefix >= bits && c.address & mask == base
        }
    }

    /// "name" or "*.name": labels of letters, digits, '-' and '_' (netd's rule).
    static func isHostPattern(_ s: String) -> Bool {
        var rest = Substring(s)
        if rest.hasPrefix("*.") { rest = rest.dropFirst(2) }
        guard !rest.isEmpty, s.count <= 253 else { return false }
        return rest.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    // MARK: netd

    /// The command that creates this network in netd.
    var netdNetworkCommand: String {
        var line = "network \(kind.rawValue) \(subnet)"
        if let l = leaseSeconds { line += " lease=\(l)" }
        line += " peers=\(vmsReachEachOther ? 1 : 0)"
        if kind == .hostOnly { line += " dns=\(lookupsThroughTheMac ? 1 : 0)" }
        return line
    }

    // MARK: Persistence

    enum DecodingProblem: Error, LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            if case .unsupportedVersion(let v) = self {
                return "This network was saved by a newer Monad (version \(v)). Update Monad to use it."
            }
            return nil
        }
    }

    static func decode(_ data: Data) throws -> NetworkDefinition {
        struct Header: Decodable { var version: Int? }
        let v = try JSONDecoder().decode(Header.self, from: data).version ?? 0
        guard v == currentVersion else { throw DecodingProblem.unsupportedVersion(v) }
        return try JSONDecoder().decode(NetworkDefinition.self, from: data)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

extension NetworkDefinition.Kind {
    var title: String {
        switch self {
        case .nat: return "NAT"
        case .hostOnly: return "Host-only"
        case .internal: return "Internal"
        case .none: return "Switch only"
        }
    }

    var summary: String {
        switch self {
        case .nat: return "Internet through this Mac, behind each VM's firewall. The Mac and its local network are blocked unless a VM allows them."
        case .hostOnly: return "VMs and the gateway (addresses and DNS). Nothing reaches the internet."
        case .internal: return "VMs see each other and get addresses. No DNS, and nothing leaves."
        case .none: return "A plain switch between VMs: no addresses handed out, no gateway."
        }
    }
}

extension NetworkAttachment {
    /// How the UI names the VM's network.
    var displayName: String { isAppleNAT ? "Apple NAT" : network }
}

/// The networks on disk: one JSON file per network, readable only by the user.
struct NetworkStore {
    let directory: URL

    init(directory: URL = Paths.networks) {
        self.directory = directory
    }

    enum StoreError: Error, LocalizedError {
        case defaultIsPermanent

        var errorDescription: String? { "The default network can be changed but not deleted." }
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    /// Every valid network, sorted by name; the default one is created on first use.
    func all() throws -> [NetworkDefinition] {
        try Paths.ensurePrivateDirectory(directory)
        if !FileManager.default.fileExists(atPath: file(NetworkDefinition.defaultName).path) {
            try save(.builtInDefault)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let n = try? NetworkDefinition.decode(data),
                  n.name == url.deletingPathExtension().lastPathComponent, (try? n.validate()) != nil else {
                Log.host.error("Ignoring the network file \(url.lastPathComponent, privacy: .public): unreadable or invalid")
                return nil
            }
            return n
        }.sorted { $0.name < $1.name }
    }

    func network(named name: String) throws -> NetworkDefinition? {
        try all().first { $0.name == name }
    }

    func save(_ network: NetworkDefinition) throws {
        try network.validate()
        try Paths.ensurePrivateDirectory(directory)
        let url = file(network.name)
        try network.encoded().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(named name: String) throws {
        guard name != NetworkDefinition.defaultName else { throw StoreError.defaultIsPermanent }
        try? FileManager.default.removeItem(at: file(name))
    }
}
