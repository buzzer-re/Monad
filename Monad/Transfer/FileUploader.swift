//
//  FileUploader.swift — copy host data into a VM over the instance's ssh
//  connection (reuses the ControlMaster, so it is near-instant).
//

import Foundation

/// Where uploads go: an instance's ssh config and host alias.
struct SSHTarget {
    /// The VM's ssh options (`CloudInit.sshArguments`): never its ssh.config.
    let options: [String]
    let host: String
}

extension RemoteVM {
    var sshTarget: SSHTarget { SSHTarget(options: CloudInit.sshArguments(config: config, paths: paths), host: sshHost) }
}

enum FileUploader {
    enum Directory: String {
        case screenshots = "shots"
        case uploads = "uploads"
    }

    static let maxFileSize: UInt64 = 2 << 30

    /// Upload bytes as ~/.monad/<dir>/<name> and return the absolute guest path.
    static func upload(_ data: Data, name: String, directory: Directory, to vm: SSHTarget,
                       runner: CommandRunning = LoggingCommandRunner(SystemCommandRunner())) async throws -> String {
        let safe = sanitize(name)
        let remote = "~/.monad/\(directory.rawValue)"
        // Pick a unique name remotely; print the absolute path.
        let script = """
        set -e; d=\(remote); mkdir -p "$d"; f="$d/\(safe)"; \
        if [ -e "$f" ]; then b="${f%.*}"; e="${f##*.}"; [ "$e" = "$f" ] && e=""; i=1; \
        while [ -e "$b-$i${e:+.$e}" ]; do i=$((i+1)); done; f="$b-$i${e:+.$e}"; fi; \
        cat > "$f"; readlink -f "$f"
        """
        let r = try await runner.run("/usr/bin/ssh", vm.options + [
            "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ConnectTimeout=10", vm.host, script,
        ], stdin: data, timeout: 300)
        guard r.status == 0 else {
            let msg = r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MonadError(msg.isEmpty ? "ssh exited with status \(r.status)" : msg)
        }
        let path = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw MonadError("Unexpected response from guest") }
        return path
    }

    static func uploadFile(_ url: URL, to vm: SSHTarget,
                           runner: CommandRunning = LoggingCommandRunner(SystemCommandRunner())) async throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MonadError("\(url.lastPathComponent) is not a regular file") }
        guard UInt64(values.fileSize ?? 0) <= maxFileSize else { throw MonadError("\(url.lastPathComponent) is larger than 2 GB") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await upload(data, name: url.lastPathComponent, directory: .uploads, to: vm, runner: runner)
    }

    /// Restrict file names to a safe portable set (they are interpolated into a shell script).
    static func sanitize(_ name: String) -> String {
        var out = ""
        for u in name.unicodeScalars {
            if u.isASCII, CharacterSet.alphanumerics.contains(u) || "._-".unicodeScalars.contains(u) {
                out.unicodeScalars.append(u)
            } else {
                out.append("_")
            }
        }
        while out.hasPrefix(".") { out.removeFirst() }
        if out.isEmpty { out = "file" }
        return String(out.prefix(120))
    }
}
