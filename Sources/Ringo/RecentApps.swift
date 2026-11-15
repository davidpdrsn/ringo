import AppKit

/// The order apps were last in front in, most recent first, including those
/// that have quit since.
struct AppHistory<App: Equatable> {
    private(set) var apps: [App] = []

    mutating func activated(_ app: App) {
        apps.removeAll { $0 == app }
        apps.insert(app, at: 0)
    }

    /// Forgets `app`, like one that quit and can't be launched again.
    mutating func forget(_ app: App) {
        apps.removeAll { $0 == app }
    }

    /// Forgets the apps that aren't in `running`, all but the `limit` most
    /// recent of them.
    mutating func forgetQuit(beyond limit: Int, running: [App]) {
        let forgotten = apps.filter { !running.contains($0) }.dropFirst(limit)
        apps.removeAll { forgotten.contains($0) }
    }

    /// The apps in `running` and those that have quit, each most recently in
    /// front first. Running apps that haven't been in front since this started
    /// follow the others, in the order they're in `running`.
    func recent(running: [App]) -> (running: [App], quit: [App]) {
        let tracked = apps.filter { running.contains($0) }
        let untracked = running.filter { !apps.contains($0) }
        let quit = apps.filter { !running.contains($0) }
        return (tracked + untracked, quit)
    }
}

/// Tells apps apart on the ring of recent apps.
enum RecentAppID: Hashable {
    /// An app bundle, which is the same app after it quits and launches again,
    /// so it keeps its place.
    case bundle(String)
    /// A process that isn't an app bundle, like one started with `cargo run`.
    /// Told apart by `NSRunningApplication`'s equality rather than its pid,
    /// which can be -1.
    case process(NSRunningApplication)

    init(_ app: NSRunningApplication) {
        self = app.bundleIdentifier.map(Self.bundle) ?? .process(app)
    }
}

/// An app for the ring of recent apps, and the item that shows it.
struct RecentApp {
    var id: RecentAppID
    var item: MenuItem
}

/// Follows the order apps were in front in, for the ring of recent apps.
///
/// Watches every switch, not just those made through the menu, since an app
/// might have come to the front from the Dock or ⌘Tab.
///
/// An app bundle that quits is remembered, so picking it launches it again.
/// That's only since this started, not across restarts.
@MainActor
final class RecentApps {
    /// How many apps that have quit it remembers. More than the ring has room
    /// for, since those in the configured ring are left out of it.
    private static let quitLimit = 32

    private var history = AppHistory<RecentAppID>()
    /// Where each app bundle that has quit is, and its name, by bundle ID.
    private var quitApps: [String: (url: URL, title: String)] = [:]
    private var observers: [any NSObjectProtocol] = []

    init() {
        if let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular {
            history.activated(RecentAppID(app))
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
            MainActor.assumeIsolated { self?.history.activated(RecentAppID(app)) }
        }
        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app else { return }
            MainActor.assumeIsolated { self?.terminated(app) }
        }
        observers = [activated, terminated]
    }

    private func terminated(_ app: NSRunningApplication) {
        let id = RecentAppID(app)
        guard history.apps.contains(id) else { return }
        guard case .bundle(let bundleID) = id, let url = app.bundleURL else {
            history.forget(id)
            return
        }
        quitApps[bundleID] = (url, app.localizedName ?? url.deletingPathExtension().lastPathComponent)
        history.forgetQuit(beyond: Self.quitLimit, running: runningApps.map(RecentAppID.init))
        quitApps = quitApps.filter { history.apps.contains(.bundle($0.key)) }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    /// The apps other than those in `excluded`, the running ones and those that
    /// have quit, each most recently in front first, like ⌘Tab. The one in
    /// front is included, so switching apps doesn't change which apps there
    /// are and move them around the ring.
    func recent(excluding excluded: [RecentAppID]) -> (running: [RecentApp], quit: [RecentApp]) {
        let running = runningApps
        let recent = history.recent(running: running.map(RecentAppID.init))
        let runningItems = recent.running.filter { !excluded.contains($0) }.compactMap { id in
            running.first { RecentAppID($0) == id }.map { RecentApp(id: id, item: MenuItem(running: $0)) }
        }
        let quitItems = recent.quit.filter { !excluded.contains($0) }.compactMap { id -> RecentApp? in
            guard case .bundle(let bundleID) = id, let app = quitApps[bundleID],
                  // It may have been deleted since.
                  FileManager.default.fileExists(atPath: app.url.path) else { return nil }
            let item = MenuItem(
                title: app.title,
                target: .app(url: app.url, bundleID: bundleID),
                icon: NSWorkspace.shared.icon(forFile: app.url.path)
            )
            return RecentApp(id: id, item: item)
        }
        return (runningItems, quitItems)
    }
}

/// Gives each recent app a place on the ring that it keeps, so they don't move
/// around as others come and go.
///
/// The ring has a fixed number of places, so an app coming or going doesn't
/// change the angle of the others. Its size only depends on the running apps,
/// and the apps that have quit fill the places they leave free. An app that
/// quits keeps its place until a running app needs it, the one that quit the
/// longest ago first.
struct RecentSlots<App: Equatable> {
    /// The app in each place around the ring, `nil` where there's none.
    private(set) var slots: [App?] = []

    /// The ring has at least this many places, and grows by `growth` at a time.
    static var minimumCount: Int { 8 }
    static var growth: Int { 4 }

    /// Places the `running` apps and those that have `quit`, each most recent
    /// first. Those already on the ring stay where they are, the rest fill the
    /// free places in order, and the ones in neither list make room. Returns
    /// the app in each place.
    mutating func place(_ running: [App], quit: [App]) -> [App?] {
        slots = slots.map { slot in slot.flatMap { running.contains($0) || quit.contains($0) ? $0 : nil } }
        for app in running where !slots.contains(app) {
            if let free = slots.firstIndex(of: nil) {
                slots[free] = app
            } else if let oldest = quit.last(where: { slots.contains($0) }), let place = slots.firstIndex(of: oldest) {
                slots[place] = app
            } else {
                slots.append(app)
            }
        }

        let used = (slots.lastIndex { $0.map(running.contains) ?? false } ?? -1) + 1
        let steps = (used + Self.growth - 1) / Self.growth
        let count = max(Self.minimumCount, steps * Self.growth)
        if slots.count > count {
            slots.removeLast(slots.count - count)
        } else {
            slots += [App?](repeating: nil, count: count - slots.count)
        }

        for app in quit where !slots.contains(app) {
            guard let free = slots.firstIndex(of: nil) else { break }
            slots[free] = app
        }
        return slots
    }
}
