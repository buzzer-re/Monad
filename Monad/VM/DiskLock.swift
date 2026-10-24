//
//  DiskLock.swift — one Lima disk, one Monad at a time. The release and the
//  debug build have their own MonadHost and VMs but may both point at the
//  same Lima VM; each takes this lock (an exclusive flock on a file in
//  Lima's folder, never on the disk itself) while its VM boots that disk
//  or while it copies it, and refuses when the other holds it. The lock
//  goes with its holder, and with the process when it ends.
//

import Foundation

final class DiskLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { release() }

    /// The lock on `file` (made 0600 if missing); nil while another holds it.
    static func take(_ file: URL) throws -> DiskLock? {
        let fd = open(file.path, O_RDONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MonadError.posix(errno, "Cannot open \(file.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let e = errno
            close(fd)
            if e == EWOULDBLOCK { return nil }
            throw MonadError.posix(e, "Cannot lock \(file.path)")
        }
        return DiskLock(fd: fd)
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
