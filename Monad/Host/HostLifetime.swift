//
//  HostLifetime.swift — launchd starts MonadHost on demand (first connection
//  to its Mach service); it exits after `grace` seconds with nothing to do,
//  so an idle Mac carries no Monad process at all.
//

import Foundation
import os

@MainActor
final class HostLifetime {
    private let service: HostService
    private let grace: TimeInterval
    private let clock: MonadClock
    private let onIdle: () -> Void
    private var timer: Task<Void, Never>?

    init(service: HostService, grace: TimeInterval, clock: MonadClock = SystemClock(), onIdle: @escaping () -> Void) {
        self.service = service
        self.grace = grace
        self.clock = clock
        self.onIdle = onIdle
    }

    func start() {
        service.onBusyChanged = { [weak self] busy in self?.evaluate(busy) }
        evaluate(service.isBusy)
    }

    private func evaluate(_ busy: Bool) {
        timer?.cancel()
        timer = nil
        guard !busy else { return }
        timer = Task { [weak self] in
            guard let self else { return }
            await self.clock.sleep(seconds: self.grace)
            guard !Task.isCancelled, !self.service.isBusy else { return }
            Log.host.notice("idle for \(Int(self.grace))s; exiting")
            self.onIdle()
        }
    }
}
