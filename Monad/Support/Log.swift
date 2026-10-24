//
//  Log.swift
//

import os

enum Log {
    static let app = Logger(subsystem: Flavor.current.logSubsystem, category: "app")
    static let vm = Logger(subsystem: Flavor.current.logSubsystem, category: "vm")
    static let term = Logger(subsystem: Flavor.current.logSubsystem, category: "terminal")
    static let image = Logger(subsystem: Flavor.current.logSubsystem, category: "image")
    static let host = Logger(subsystem: Flavor.current.logSubsystem, category: "host")
}

/// Errors surfaced to the user.
struct MonadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension MonadError {
    static func posix(_ code: Int32, _ what: String) -> MonadError {
        MonadError("\(what): \(String(cString: strerror(code)))")
    }
}
