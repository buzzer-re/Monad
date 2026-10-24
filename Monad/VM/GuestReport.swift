//
//  GuestReport.swift — what a guest says about Monad's setup on its console
//  (Guest/monad-report.sh): its "MONAD| " lines, read from the serial log
//  while it boots, for the debug log and for a boot that fails. The guest
//  is not trusted: lines are plain text and bounded, a line that never
//  ends is dropped, and only the last lines are kept.
//

import Foundation

struct GuestReport: Sendable {
    static let maxLine = 300
    static let maxKept = 64
    private static let marker = Data("MONAD| ".utf8)
    /// Longest unfinished line held between reads; a longer one is dropped.
    private static let maxPartial = 4096
    /// Most read from the log at once.
    private static let maxRead = 256 * 1024

    private(set) var lines: [String] = []
    private var offset: UInt64 = 0
    private var partial = Data()
    private var skipping = false

    init() {}

    /// A reader of `log` that skips what is there already (older boots:
    /// the serial log outlives them).
    static func starting(at log: URL) -> GuestReport {
        var report = GuestReport()
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size]) as? NSNumber
        report.offset = size?.uint64Value ?? 0
        return report
    }

    /// The report lines added to `log` since the last call; from the start
    /// again once the log has been rotated.
    mutating func newLines(in log: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return [] }
        if size < offset {
            offset = 0
            partial = Data()
            skipping = false
        }
        guard size > offset, (try? h.seek(toOffset: offset)) != nil,
              let data = try? h.read(upToCount: Self.maxRead) else { return [] }
        offset += UInt64(data.count)
        return read(data)
    }

    /// The report lines in the next piece of console output.
    mutating func read(_ data: Data) -> [String] {
        var found: [String] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[..<newline]
            rest = rest[rest.index(after: newline)...]
            if skipping {
                skipping = false
                continue
            }
            var line = partial
            line.append(contentsOf: piece)
            partial = Data()
            if let text = Self.text(line) { found.append(text) }
        }
        if !rest.isEmpty, !skipping {
            partial.append(contentsOf: rest)
            if partial.count > Self.maxPartial {
                partial = Data()
                skipping = true
            }
        }
        lines.append(contentsOf: found)
        if lines.count > Self.maxKept { lines.removeFirst(lines.count - Self.maxKept) }
        return found
    }

    private static func text(_ line: Data) -> String? {
        guard let start = line.range(of: marker) else { return nil }
        let raw = String(decoding: line[start.upperBound...], as: UTF8.self)
        let plain = raw.unicodeScalars.filter { $0.properties.generalCategory != .control }
        return String(String(String.UnicodeScalarView(plain)).prefix(maxLine))
    }
}
