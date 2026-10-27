import CoreGraphics
import Foundation

/// Reports a modifier key (like left Option) being pressed and released on its own.
///
/// Carbon hotkeys need a non-modifier key, and an event tap for modifier changes
/// stays disabled without Input Monitoring permission (which an ad-hoc signed
/// app loses on every rebuild). So this polls the modifier state instead, which
/// needs no permission and includes which side each modifier is on.
@MainActor
final class ModifierKeyMonitor: HotKeyHandle {
    private static let pollInterval: TimeInterval = 1.0 / 60

    private let key: ModifierKey
    private let handler: (HotKeyCenter.Event) -> Void
    private var timer: Timer?
    private var activity: (any NSObjectProtocol)?

    private var isDown = false
    /// Whether the key went down with no other modifiers held, so its release
    /// should be reported too.
    private var isActive = false

    init(key: ModifierKey, handler: @escaping (HotKeyCenter.Event) -> Void) {
        self.key = key
        self.handler = handler

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A background app would otherwise get App Napped, which throttles the timer.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Watching for the \(key) hotkey"
        )
    }

    func unregister() {
        timer?.invalidate()
        timer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let wasDown = isDown
        isDown = key.isDown(in: flags)
        if isDown && !wasDown {
            // Don't hijack shortcuts like ⌘⌥Esc that just include this key.
            isActive = !key.othersDown(in: flags)
            if isActive { handler(.pressed) }
        } else if !isDown && wasDown && isActive {
            isActive = false
            handler(.released)
        }
    }
}
