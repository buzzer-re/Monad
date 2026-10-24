//
//  UnixClient.swift — a test's side of a unix socket: connect, send, read
//  what comes (until the other side closes, a text appears, or time runs out).
//

import Foundation

final class UnixClient {
    let fd: Int32

    init(_ path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else {
            close(fd)
            throw TestError("connect \(path): errno \(errno)")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
    }

    deinit { close(fd) }

    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    private(set) var received = Data()

    /// Reads until `done` holds for what came, the other side closes, or
    /// `timeout` passes; returns everything received so far.
    @discardableResult
    func read(until done: (String) -> Bool = { _ in false }, timeout: TimeInterval = 5) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline, !done(text) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { closed = true; break }
            received.append(contentsOf: buffer[0..<n])
        }
        return text
    }

    private(set) var closed = false
    var text: String { String(decoding: received, as: UTF8.self) }
}
