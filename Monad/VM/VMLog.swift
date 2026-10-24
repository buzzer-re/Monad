//
//  VMLog.swift — one VM's own log (vm.log in its folder): what Monad did
//  with it and what it answered, from its creation on. Always on (Settings
//  › Logs is the whole Mac's, and off unless turned on), private to the
//  user, shown on the VM's Log page. Bounded: past its limit it moves to
//  vm.log.1 (the one before) and starts again.
//

import Foundation

final class VMLog: @unchecked Sendable {
    let url: URL
    private let limit: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "dev.monad.vm-log")

    // Used on `queue` only.
    private var fd: Int32 = -1
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(url: URL, limit: Int = 1 << 20, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.limit = limit
        self.now = now
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Where the log before this one is kept.
    static func previous(of url: URL) -> URL { url.appendingPathExtension("1") }

    /// One line, more if `message` has newlines (as the debug log writes them).
    func log(_ message: String) {
        let date = now()
        queue.async { self.write(date: date, text: message) }
    }

    /// Waits until everything logged so far is written.
    func flush() { queue.sync {} }

    private func write(date: Date, text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        var out = stamp.string(from: date) + " " + (lines.first.map(String.init) ?? "") + "\n"
        for line in lines.dropFirst() { out += "    | " + line + "\n" }
        if fd < 0 { open() }
        guard fd >= 0 else { return }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size > 0, Int(st.st_size) + out.utf8.count > limit {
            close(fd)
            fd = -1
            _ = rename(url.path, Self.previous(of: url).path)
            open()
            guard fd >= 0 else { return }
        }
        _ = out.utf8CString.withUnsafeBufferPointer { b in Darwin.write(fd, b.baseAddress, b.count - 1) }
    }

    private func open() {
        fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd >= 0 { fchmod(fd, 0o600) }
    }

    /// The latest part of a VM's log for its Log page: the one before
    /// first, at most `maxBytes`, whole lines only.
    static func read(_ url: URL, maxBytes: Int = 512 << 10) -> String {
        var data = (try? Data(contentsOf: previous(of: url))) ?? Data()
        data.append((try? Data(contentsOf: url)) ?? Data())
        guard data.count > maxBytes else { return String(decoding: data, as: UTF8.self) }
        var tail = data.suffix(maxBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: newline)...] }
        return String(decoding: tail, as: UTF8.self)
    }
}
