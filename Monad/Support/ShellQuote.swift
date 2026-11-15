//
//  ShellQuote.swift — one word for a POSIX shell: what Monad types into a
//  tab (dropped paths) and what it puts in a command line a shell will split
//  (an ssh remote command, a ProxyCommand).
//

import Foundation

enum ShellQuote {
    /// POSIX shell single-quoting (only when needed).
    static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_~")
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
