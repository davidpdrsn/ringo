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
}
