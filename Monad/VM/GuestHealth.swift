//
//  GuestHealth.swift — what a Linux guest's health lines (health.log, from
//  Guest/monad-health.sh over its health port) mean for the user: its
//  kernel crashed, it ran out of memory, its disk is full. Each is said once
//  per boot, in plain words with what to do, in the VM's log, its window and
//  its tabs. Seen on the Mac: a guest whose kernel crashed on every exec
//  (every command "segfaulted", ssh timed out) with nothing in Monad saying
//  so (2026-11-01).
//
//  Before trouble, warnings (like VMware's): a VM that stays low on memory,
//  or whose disk is almost full. The app turns them into notifications
//  (VMAlerts).
//
//  The lines are the guest's: names taken from them are cut and plain, and
//  a line that does not parse changes nothing.
//

import Foundation

/// A VM running low on something, while it still works.
struct GuestWarning: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case lowMemory, lowDisk }
    var kind: Kind
    /// How much is in use.
    var percent: Int
    /// The disk's mount point (lowDisk).
    var mount: String? = nil

    /// In a few words, as logs and agents see it.
    var text: String {
        switch kind {
        case .lowMemory: return "low memory (\(percent)% in use)"
        case .lowDisk: return "low disk space on \(mount ?? "/") (\(percent)% in use)"
        }
    }
}

struct GuestHealth: Sendable {
    enum Problem: Int, Comparable, CaseIterable, Sendable {
        case kernelCrash, outOfMemory, diskFull
        static func < (a: Problem, b: Problem) -> Bool { a.rawValue < b.rawValue }
    }

    /// A disk this full is said (percent used).
    static let fullDisk = 95
    /// Memory or a disk this much in use is warned about, until it falls
    /// below `warningClears` (percent).
    static let warnAt = 90
    static let warningClears = 85
    /// Snapshots in a row memory must be low for (a moment can be a spike).
    static let lowMemorySnapshots = 2
    /// Most programs named as stopped for memory.
    private static let maxStopped = 3

    private var crash: (seen: Bool, function: String?, program: String?) = (false, nil, nil)
    private var stopped: [String] = []
    private var diskPercent: Int?
    private var memoryPercent: Int?
    private var memoryLowFor = 0
    private var memoryWarned = false
    private var diskWarned = false
    private var said: Set<Problem> = []

    init() {}

    /// Health lines (without their "MONAD-H| " mark) in; the problems they
    /// make known for the first time this boot out.
    mutating func read(_ lines: [String]) -> [String] {
        var new: [Problem] = []
        for line in lines {
            if line.hasPrefix("boot ") {
                self = GuestHealth()
                new.removeAll()
            } else if line.hasPrefix("kern ") {
                kernel(String(line.dropFirst(5).drop { $0 != " " }.dropFirst()))
            } else if line.hasPrefix("snap ") {
                snapshot(line)
            }
            for p in current where !said.contains(p) {
                said.insert(p)
                new.append(p)
            }
        }
        return new.compactMap(message)
    }

    /// Every problem this boot, in one text; nil when there is none.
    var summary: String? {
        let all = current.compactMap(message)
        return all.isEmpty ? nil : all.joined(separator: " ")
    }

    /// What is running low now.
    var warnings: [GuestWarning] {
        var w: [GuestWarning] = []
        if memoryWarned, let p = memoryPercent { w.append(GuestWarning(kind: .lowMemory, percent: p)) }
        if diskWarned, let p = diskPercent { w.append(GuestWarning(kind: .lowDisk, percent: p, mount: "/")) }
        return w
    }

    private var current: [Problem] {
        var p: [Problem] = []
        if crash.seen { p.append(.kernelCrash) }
        if !stopped.isEmpty { p.append(.outOfMemory) }
        if let d = diskPercent, d >= Self.fullDisk { p.append(.diskFull) }
        return p
    }

    private func message(_ p: Problem) -> String? {
        switch p {
        case .kernelCrash:
            let where_ = [crash.function.map { "in \($0)" }, crash.program.map { "running \($0)" }].compactMap { $0 }
            return "The VM's kernel crashed" + (where_.isEmpty ? "" : " (\(where_.joined(separator: ", ")))")
                + ": programs in it fail, and their shells say “Segmentation fault”, until it restarts. Restart the VM."
        case .outOfMemory:
            return "The VM ran out of memory: Linux stopped \(stopped.joined(separator: ", ")) to free some. "
                + "Give it more memory (its settings › Resources)."
        case .diskFull:
            return diskPercent.map { "The VM's disk is \($0)% full: programs in it may fail to write. Free some space in it." }
        }
    }

    private mutating func kernel(_ text: String) {
        if text.contains("Internal error: Oops") || text.hasPrefix("BUG:") || text.contains("Kernel panic")
            || text.hasPrefix("Unable to handle kernel") {
            crash.seen = true
        }
        // Who and where, from the first crash's report only.
        if crash.seen, crash.program == nil, let r = text.range(of: " Comm: ") {
            crash.program = Self.name(text[r.upperBound...].prefix { $0 != " " })
        }
        if crash.seen, crash.function == nil, text.hasPrefix("pc : ") {
            crash.function = Self.name(text.dropFirst(5).prefix { $0 != "+" && $0 != " " })
        }
        for mark in ["Out of memory: Killed process ", "out of memory: Killed process "] {
            guard let r = text.range(of: mark), let open = text[r.upperBound...].firstIndex(of: "("),
                  let close = text[open...].firstIndex(of: ")") else { continue }
            let name = Self.name(text[text.index(after: open)..<close])
            if let name, !stopped.contains(name), stopped.count < Self.maxStopped { stopped.append(name) }
            break
        }
    }

    /// The root disk's use, from "disk=/:USED/SIZE,…", and memory's, from
    /// "mem=AVAILABLE/TOTAL".
    private mutating func snapshot(_ line: String) {
        if let r = line.range(of: " mem="), let (available, total) = Self.pair(line[r.upperBound...]) {
            let p = Int((total - available) * 100 / total)
            memoryPercent = p
            memoryLowFor = p >= Self.warnAt ? memoryLowFor + 1 : 0
            if memoryLowFor >= Self.lowMemorySnapshots { memoryWarned = true }
            if p < Self.warningClears { memoryWarned = false }
        }
        if let r = line.range(of: " disk=/:"), let (used, size) = Self.pair(line[r.upperBound...]) {
            let p = Int(used * 100 / size)
            diskPercent = p
            if p >= Self.warnAt { diskWarned = true }
            if p < Self.warningClears { diskWarned = false }
        }
    }

    /// "A/B" up to the next comma or space: A of B, both whole and A ≤ B.
    private static func pair(_ s: Substring) -> (Int64, Int64)? {
        let pair = s.prefix { $0 != "," && $0 != " " }.split(separator: "/")
        guard pair.count == 2, let a = Int64(pair[0]), let b = Int64(pair[1]), b > 0, a >= 0, a <= b,
              b < Int64.max / 100 else { return nil }
        return (a, b)
    }

    /// A process or function name from the guest: plain characters only, cut.
    private static func name<S: StringProtocol>(_ s: S) -> String? {
        let plain = s.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/:".unicodeScalars.contains($0)) }
        let text = String(String.UnicodeScalarView(plain).prefix(32))
        return text.isEmpty ? nil : text
    }
}
