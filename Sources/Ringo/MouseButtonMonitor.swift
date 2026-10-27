import AppKit

/// Opens the menu while an extra mouse button, like a side button, is held.
///
/// Uses an event tap so the button's usual action (going forward in a browser,
/// say) doesn't also happen, which needs the Accessibility permission. The tap
/// sits at the HID level, ahead of remappers like LinearMouse that would
/// otherwise turn side buttons into something else before this app sees them.
@MainActor
final class MouseButtonMonitor {
    private static weak var current: MouseButtonMonitor?

    var handler: ((HotKeyCenter.Event) -> Void)?

    /// 1-based, like "Button 4".
    private var button: Int?
    private var identify: ((Int) -> Void)?
    /// The button used to identify, whose release is swallowed too.
    private var swallowRelease: Int?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var launchObserver: (any NSObjectProtocol)?

    init() {
        Self.current = self
        // Taps inserted later go first, so get back in front of a remapper that
        // (re)starts after this app.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap != nil else { return }
                self.removeTap()
                self.updateTap()
            }
        }
    }

    /// Returns false when the tap can't be created, i.e. without Accessibility.
    func configure(button: Int?) -> Bool {
        self.button = button
        return updateTap()
    }

    /// Reports the next extra mouse button pressed, and swallows that press.
    func identifyNextButton(_ completion: @escaping (Int) -> Void) -> Bool {
        identify = completion
        if updateTap() { return true }
        identify = nil
        return false
    }

    func cancelIdentify() {
        identify = nil
        updateTap()
    }

    @discardableResult
    private func updateTap() -> Bool {
        let needed = button != nil || identify != nil || swallowRelease != nil
        if !needed {
            removeTap()
            return true
        }
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue) | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseButtonTapCallback,
            userInfo: nil
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    /// `button` is 1-based.
    fileprivate static func shouldDrop(_ type: CGEventType, button: Int) -> Bool {
        guard let monitor = current else { return false }
        switch type {
        case .otherMouseDown, .otherMouseUp:
            return monitor.handle(button: button, isDown: type == .otherMouseDown)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = monitor.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        default:
            return false
        }
    }

    private func handle(button number: Int, isDown: Bool) -> Bool {
        if isDown, let identify {
            self.identify = nil
            swallowRelease = number
            // Not from inside the tap's callback, which mustn't block.
            DispatchQueue.main.async { identify(number) }
            return true
        }
        if !isDown, swallowRelease == number {
            swallowRelease = nil
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { _ = self?.updateTap() }
            }
            return true
        }
        guard number == button else { return false }
        let handler = handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(isDown ? .pressed : .released) }
        }
        return true
    }
}

/// Runs on the main run loop, which the tap's source is added to.
private func mouseButtonTapCallback(
    _: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
    let drop = MainActor.assumeIsolated { MouseButtonMonitor.shouldDrop(type, button: button) }
    return drop ? nil : Unmanaged.passUnretained(event)
}
