import AppKit
import QuartzCore

/// Hides the cursor after switching to an app with `hide_cursor`, until the
/// mouse moves or clicks, or another app comes to the front.
///
/// An app can normally only hide the cursor while it's in front. A private
/// WindowServer connection property lets this app do it from the background,
/// like cursor-hiding utilities do.
@MainActor
final class CursorHider {
    /// How far the mouse can move without bringing the cursor back, in points,
    /// so the tail end of the flick toward the app doesn't.
    private static let threshold: CGFloat = 2
    /// Some apps show the cursor as they come to the front (Ghostty does, a
    /// moment after activating), and a launching app can take a while to get
    /// there.
    private static let settleTime: CFTimeInterval = 2
    private static let pollInterval: TimeInterval = 0.02
    private static let moves: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    private static let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// The app the cursor is hidden for, while it's hidden.
    private var pid: pid_t?
    /// Calls to `CGDisplayHideCursor` not yet balanced by `CGDisplayShowCursor`.
    private var hideCount = 0
    private var distance: CGFloat = 0
    private var monitors: [Any] = []
    private var activationObserver: (any NSObjectProtocol)?
    private var settleTimer: Timer?

    func hide(while pid: pid_t) {
        if self.pid == nil {
            guard Self.canHideInBackground else { return }
            hideCursor()
            startWatching()
        }
        self.pid = pid
        distance = 0
        keepHiddenWhileSettling()
    }

    func show() {
        guard pid != nil else { return }
        pid = nil
        stopSettling()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        // An app showing the cursor resets the count, and showing it more often
        // than it was hidden does nothing, so this can't leave it hidden.
        for _ in 0..<hideCount {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        hideCount = 0
    }

    private func hideCursor() {
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    /// Hides the cursor again whenever the app shows it while coming to the front.
    private func keepHiddenWhileSettling() {
        stopSettling()
        guard let isCursorVisible = Self.isCursorVisible else { return }
        let deadline = CACurrentMediaTime() + Self.settleTime
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if CACurrentMediaTime() > deadline {
                    self.stopSettling()
                } else if isCursorVisible() != 0 {
                    self.hideCursor()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func stopSettling() {
        settleTimer?.invalidate()
        settleTimer = nil
    }

    private func startWatching() {
        let mask = Self.moves.union(Self.clicks)
        // The global monitor sees events going to other apps, the local one those
        // going to this app, like an alert about the config.
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let activated = app?.processIdentifier else { return }
            MainActor.assumeIsolated {
                // Switching to a process briefly activates this app on the way.
                guard let self, activated != self.pid, activated != getpid() else { return }
                self.show()
            }
        }
    }

    private func handle(_ event: NSEvent) {
        if Self.clicks.contains(NSEvent.EventTypeMask(type: event.type)) {
            show()
            return
        }
        distance += hypot(event.deltaX, event.deltaY)
        if distance > Self.threshold {
            show()
        }
    }

    // MARK: - Private CoreGraphics

    /// RTLD_DEFAULT, which Swift doesn't import. These functions live in
    /// SkyLight and CoreGraphics, which AppKit has already loaded.
    private static let everywhere = UnsafeMutableRawPointer(bitPattern: -2)

    /// `CGCursorIsVisible`, deprecated and hidden from Swift, but it still
    /// reports whether the cursor is showing.
    private static let isCursorVisible = dlsym(everywhere, "CGCursorIsVisible").map {
        unsafeBitCast($0, to: (@convention(c) () -> Int32).self)
    }

    /// Lets this app hide the cursor while another app is in front. Set the first
    /// time it's needed, and lasts until the app quits.
    private static let canHideInBackground: Bool = {
        guard
            let defaultConnection = dlsym(everywhere, "_CGSDefaultConnection"),
            let setProperty = dlsym(everywhere, "CGSSetConnectionProperty")
        else {
            NSLog("Couldn't find CGSSetConnectionProperty, so hide_cursor doesn't work")
            return false
        }
        let connection = unsafeBitCast(defaultConnection, to: (@convention(c) () -> Int32).self)()
        let set = unsafeBitCast(
            setProperty,
            to: (@convention(c) (Int32, Int32, CFString, CFTypeRef) -> CGError).self
        )
        let result = set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if result != .success {
            NSLog("Couldn't let the cursor be hidden from the background (%d), so hide_cursor doesn't work", result.rawValue)
        }
        return result == .success
    }()
}
