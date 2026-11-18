//
//  KeepAwake.swift — the coffee cup's switch: while it is on, this Mac's
//  display stays on and the Mac does not sleep or lock by itself, as under
//  `caffeinate -d -i`. One switch for the whole app, shown by the cup in
//  every terminal window (KeepAwakeButton) and View › Keep This Mac Awake.
//  It is a hold of Monad's own on the Mac's sleep, so macOS drops it when
//  Monad ends, and it is off again at each start: a Mac kept awake by a
//  switch turned weeks ago is a flat battery. Closing the lid still puts
//  the Mac to sleep.
//

import Combine
import Foundation

/// What holds the Mac awake (a seam: tests record the holds instead).
protocol SleepPreventing {
    /// Keeps the display on and the Mac awake until `end` gets what this
    /// returned. `reason` is what macOS shows for it (`pmset -g assertions`).
    func begin(reason: String) -> NSObjectProtocol
    func end(_ activity: NSObjectProtocol)
}

/// The hold as macOS keeps it: PreventUserIdleDisplaySleep and
/// PreventUserIdleSystemSleep in this process's name.
struct SystemSleepPreventer: SleepPreventing {
    func begin(reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: reason)
    }

    func end(_ activity: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(activity)
    }
}

@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    static let reason = "Monad keeps this Mac awake (its coffee cup is on)"

    @Published private(set) var isOn = false
    private let preventer: SleepPreventing
    private var activity: NSObjectProtocol?

    init(preventer: SleepPreventing = SystemSleepPreventer()) {
        self.preventer = preventer
    }

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        if on {
            activity = preventer.begin(reason: Self.reason)
        } else if let held = activity {
            preventer.end(held)
            activity = nil
        }
        isOn = on
    }
}
