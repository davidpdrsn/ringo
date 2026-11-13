import AppKit

/// The order apps were last in front in, most recent first.
struct AppHistory<App: Equatable> {
    private(set) var apps: [App] = []

    mutating func activated(_ app: App) {
        apps.removeAll { $0 == app }
        apps.insert(app, at: 0)
    }

    mutating func terminated(_ app: App) {
        apps.removeAll { $0 == app }
    }

    /// The app most recently in front other than `frontmost`.
    func previous(before frontmost: App?) -> App? {
        apps.first { $0 != frontmost }
    }

    /// Every app in `running` but `frontmost`, most recently in front first.
    /// Those that haven't been in front since this started follow, in the order
    /// they're in `running`.
    func recent(before frontmost: App?, running: [App]) -> [App] {
        let tracked = apps.filter { running.contains($0) }
        let untracked = running.filter { !apps.contains($0) }
        return (tracked + untracked).filter { $0 != frontmost }
    }
}

/// Follows which app was in front before the current one, for switching back
/// to it like a quick ⌘Tab.
///
/// Watches every switch, not just those made through the menu, since the app
/// before might have come to the front from the Dock or ⌘Tab.
///
/// Apps are told apart by `NSRunningApplication`'s equality rather than their
/// pids, since a process that isn't an app bundle, like one started with
/// `cargo run`, can have a pid of -1.
@MainActor
final class RecentApps {
    private var history = AppHistory<NSRunningApplication>()
    private var observers: [any NSObjectProtocol] = []

    init() {
        if let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular {
            history.activated(app)
        }

        let center = NSWorkspace.shared.notificationCenter
        let activated = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Menu bar apps and launchers like Raycast come to the front while
            // they show a window, and so does this app on the way to a process.
            guard let app, app.activationPolicy == .regular else { return }
            MainActor.assumeIsolated { self?.history.activated(app) }
        }
        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app else { return }
            MainActor.assumeIsolated { self?.history.terminated(app) }
        }
        observers = [activated, terminated]
    }

    /// The app that was in front before the current one. Apps that quit are
    /// forgotten.
    var previous: NSRunningApplication? {
        history.previous(before: NSWorkspace.shared.frontmostApplication)
    }

    /// The running apps other than the one in front, most recently in front
    /// first, like ⌘Tab.
    var recent: [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return history.recent(before: NSWorkspace.shared.frontmostApplication, running: running)
    }
}

/// Gives each recent app a place on the ring that it keeps until it quits, so
/// they don't move around as others come and go.
///
/// The ring has a fixed number of places, so an app coming or going doesn't
/// change the angle of the others. One that quits leaves a gap for the next.
struct RecentSlots<App: Equatable> {
    /// The app in each place around the ring, `nil` where there's none.
    private(set) var slots: [App?] = []

    /// The ring has at least this many places, and grows by `growth` at a time.
    static var minimumCount: Int { 8 }
    static var growth: Int { 4 }

    /// Places `apps`, most recent first. Those already on the ring stay where
    /// they are, the rest fill the free places in order, and the ones no longer
    /// in `apps` make room. Returns the app in each place.
    mutating func place(_ apps: [App]) -> [App?] {
        slots = slots.map { slot in slot.flatMap { apps.contains($0) ? $0 : nil } }
        for app in apps where !slots.contains(where: { $0 == app }) {
            if let free = slots.firstIndex(where: { $0 == nil }) {
                slots[free] = app
            } else {
                slots.append(app)
            }
        }

        let used = (slots.lastIndex { $0 != nil } ?? -1) + 1
        let steps = (used + Self.growth - 1) / Self.growth
        let count = max(Self.minimumCount, steps * Self.growth)
        if slots.count > count {
            slots.removeLast(slots.count - count)
        } else {
            slots += [App?](repeating: nil, count: count - slots.count)
        }
        return slots
    }
}
