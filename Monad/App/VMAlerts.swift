//
//  VMAlerts.swift — notifications like VMware's: a VM low on memory or disk
//  space (GuestHealth's warnings), a problem its health shows (its kernel
//  crashed, Linux stopped programs for memory), and the Mac's own disk
//  almost full, which every VM's disk lives on. Each is said once, until it
//  clears and comes back. Settings › Virtual Machines › Warn when a VM runs
//  low turns them off. A click opens the VM's window.
//

import AppKit
import Combine
import UserNotifications

struct VMAlert: Equatable {
    /// Which alert this is (one per VM and kind), for the notification.
    let id: String
    /// The VM it is about; nil for the Mac.
    let vm: String?
    let title: String
    let body: String
}

/// What to notify, from what each VM says now. Pure: the center posts.
struct VMAlerts {
    struct VM {
        var name: String
        var running: Bool
        var warnings: [GuestWarning]
        var health: String?
    }

    /// The Mac's disk is said below this many bytes free, and clears above `macClears`.
    static let macLow: Int64 = 10 << 30
    static let macClears: Int64 = 15 << 30

    /// Warnings said and still true, by id.
    private var warned: Set<String> = []
    /// The health text last said, by VM.
    private var health: [String: String] = [:]
    private var macWarned = false

    init() {}

    /// The alerts that are new since the last update.
    mutating func update(_ vms: [VM]) -> [VMAlert] {
        var new: [VMAlert] = []
        var now: Set<String> = []
        for vm in vms {
            if vm.running {
                for w in vm.warnings {
                    let id = "\(vm.name)/\(w.kind.rawValue)/\(w.mount ?? "")"
                    now.insert(id)
                    if !warned.contains(id) { new.append(Self.alert(id: id, vm: vm.name, w)) }
                }
            }
            if let h = vm.health, health[vm.name] != h {
                health[vm.name] = h
                new.append(VMAlert(id: "\(vm.name)/health", vm: vm.name, title: "“\(vm.name)” has a problem", body: h))
            }
        }
        warned = now
        let names = Set(vms.map(\.name))
        health = health.filter { names.contains($0.key) }
        return new
    }

    /// The Mac's disk (where ~/.monad is) with `free` bytes left.
    mutating func update(macFree free: Int64) -> [VMAlert] {
        if free >= Self.macClears { macWarned = false }
        guard free < Self.macLow, !macWarned else { return [] }
        macWarned = true
        let gb = String(format: "%.1f GB", Double(free) / Double(1 << 30))
        return [VMAlert(id: "mac/disk", vm: nil, title: "Your Mac is low on disk space",
                        body: "\(gb) free. VMs fail to write to their disks when it is full: free some space on your Mac.")]
    }

    private static func alert(id: String, vm: String, _ w: GuestWarning) -> VMAlert {
        switch w.kind {
        case .lowMemory:
            return VMAlert(id: id, vm: vm, title: "“\(vm)” is low on memory",
                           body: "\(w.percent)% of its memory is in use. Give it more in its settings › Resources, or close programs in it.")
        case .lowDisk:
            return VMAlert(id: id, vm: vm, title: "“\(vm)” is low on disk space",
                           body: "Its disk (\(w.mount ?? "/")) is \(w.percent)% full. Programs in it fail to write once it is full: free some space in it.")
        }
    }
}

/// Posts VMAlerts' notifications from what the host says of each VM, and
/// checks the Mac's disk each minute.
@MainActor
final class VMAlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private let host: HostClient
    private let open: (String) -> Void
    private var alerts = VMAlerts()
    private var observers: [AnyObject] = []
    private var perVM: [String: AnyObject] = [:]
    private var timer: Timer?
    private var refreshQueued = false
    private var asked = false

    init(host: HostClient, open: @escaping (String) -> Void) {
        self.host = host
        self.open = open
        super.init()
        UNUserNotificationCenter.current().delegate = self
        observers.append(host.$instances.sink { [weak self] list in
            guard let self else { return }
            self.perVM = Dictionary(list.map { vm in
                (vm.name, vm.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() } as AnyObject)
            }, uniquingKeysWith: { a, _ in a })
            self.scheduleRefresh()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkMacDisk() }
        }
        checkMacDisk()
    }

    // Published values are stored after their sinks run: look next turn.
    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    private func refresh() {
        let vms = host.instances.map {
            VMAlerts.VM(name: $0.name, running: $0.state.isRunning, warnings: $0.warnings, health: $0.healthProblem)
        }
        post(alerts.update(vms))
    }

    private func checkMacDisk() {
        guard let values = try? Paths.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let free = values.volumeAvailableCapacityForImportantUsage else { return }
        post(alerts.update(macFree: free))
    }

    private func post(_ new: [VMAlert]) {
        guard !new.isEmpty, Settings.vmAlerts else { return }
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        for a in new {
            DebugLog.shared.log("alerts", "\(a.title): \(a.body)")
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = .default
            if let vm = a.vm { content.userInfo = ["vm": vm] }
            center.add(UNNotificationRequest(identifier: "dev.monad.alert." + a.id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let vm = response.notification.request.content.userInfo["vm"] as? String
        Task { @MainActor [weak self] in
            if let vm { self?.open(vm) }
            NSApp.activate(ignoringOtherApps: true)
            done()
        }
    }
}
