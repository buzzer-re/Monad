//
//  PlainText.swift — text a guest or an agent wrote, as Monad shows it in
//  its own panels: without control, format or separator characters (a
//  newline, an escape, a right-to-left override) and cut to a length.
//

import Foundation

extension String {
    /// This text without control, format or separator characters, cut to
    /// `limit` characters (with "…").
    func plain(limit: Int = .max) -> String {
        let kept = String(String.UnicodeScalarView(unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }))
        return kept.count > limit ? String(kept.prefix(limit)) + "…" : kept
    }
}
