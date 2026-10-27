import AppKit
import QuartzCore

/// Moves the cursor to the middle of an app's front window once it has come to
/// the front after switching to it.
@MainActor
final class CursorMover {
    /// Switching is asynchronous, and a launching app can take a while to show a
    /// window.
    private static let timeout: CFTimeInterval = 2
    private static let pollInterval: TimeInterval = 0.02

    private var timer: Timer?

    func moveCursor(toFrontWindowOf pid: pid_t) {
        cancel()
        let deadline = CACurrentMediaTime() + Self.timeout
        let startingPoint = NSEvent.mouseLocation
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Moving the mouse in the meantime means they've already moved on.
                let mouse = NSEvent.mouseLocation
                if hypot(mouse.x - startingPoint.x, mouse.y - startingPoint.y) > 2 || CACurrentMediaTime() > deadline {
                    self.cancel()
                    return
                }
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]] ?? []
                guard let center = Self.center(ofFrontWindowOf: pid, in: windows) else { return }
                CGWarpMouseCursorPosition(center)
                CGAssociateMouseAndMouseCursorPosition(1)
                self.cancel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// The middle of the frontmost regular window, in CoreGraphics coordinates,
    /// if it belongs to `pid`. `windows` is front to back, as
    /// `CGWindowListCopyWindowInfo` returns them.
    nonisolated static func center(ofFrontWindowOf pid: pid_t, in windows: [[String: Any]]) -> CGPoint? {
        for window in windows {
            // Layer 0 is regular windows, not menus, panels floating above them or
            // this app's own menu.
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds),
                rect.width > 50, rect.height > 50,
                (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else {
                // Skip things like the invisible helper windows Electron apps keep.
                continue
            }
            // Until the app is in front, someone else's window is the first one.
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return nil
    }
}
