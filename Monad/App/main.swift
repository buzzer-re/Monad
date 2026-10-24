//
//  main.swift — AppKit entry point.
//

import AppKit

// Writes to a closed PTY or socket must fail with EPIPE, not kill the app.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
