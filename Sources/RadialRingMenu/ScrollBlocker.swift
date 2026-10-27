import ApplicationServices
import QuartzCore

/// Drops the scrolling a trackpad pick leaves behind.
///
/// With no three-finger swipe gesture set up, macOS also turns the fingers'
/// movement into a scroll. Once the fingers lift it coasts on, and since the app
/// just switched to becomes the target of that coasting, it would scroll. The
/// only way to stop that is an event tap that drops the events, which needs the
/// Accessibility permission. Without it, the scroll still gets through.
@MainActor
final class ScrollBlocker {
    private static weak var current: ScrollBlocker?

    private var suppression = ScrollSuppression()
    private var tap: CFMachPort?
    private var giveUp: DispatchWorkItem?

    init() {
        Self.current = self
        if !AXIsProcessTrusted() {
            // Shows the system prompt pointing at System Settings, once per launch.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    func stop() {
        setTapEnabled(false)
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        if Self.current === self {
            Self.current = nil
        }
    }

    func gestureBegan() {
        suppression.gestureBegan()
        setTapEnabled(true)
    }

    func gestureEnded() {
        suppression.gestureEnded(at: CACurrentMediaTime())
        giveUp?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        giveUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ScrollSuppression.maximumDuration, execute: work)
    }

    func fingersChanged(to fingers: Int) {
        guard suppression.isActive else { return }
        suppression.fingersChanged(to: fingers, at: CACurrentMediaTime())
        if !suppression.isActive {
            finish()
        }
    }

    private func finish() {
        suppression.reset()
        giveUp?.cancel()
        giveUp = nil
        setTapEnabled(false)
    }

    fileprivate static func shouldDrop(_ type: CGEventType) -> Bool {
        guard let blocker = current else { return false }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if blocker.suppression.isActive, let tap = blocker.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        case .scrollWheel:
            let drop = blocker.suppression.shouldDrop(scrollAt: CACurrentMediaTime())
            if !blocker.suppression.isActive {
                blocker.finish()
            }
            return drop
        default:
            return false
        }
    }

    /// Only routes scrolling through this app while there's something to drop.
    private func setTapEnabled(_ enabled: Bool) {
        if enabled && tap == nil && AXIsProcessTrusted() {
            // Created lazily, since permission may be granted after launch.
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                callback: scrollTapCallback,
                userInfo: nil
            )
            if let tap {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            }
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }
}

/// When to drop scroll events around a trackpad gesture.
struct ScrollSuppression {
    /// Coasting sends an event at least every few frames, so this long without
    /// one means it has stopped.
    static let quietPeriod: CFTimeInterval = 0.15
    /// Never block scrolling for longer than this after a pick.
    static let maximumDuration: CFTimeInterval = 3

    private enum State {
        case off
        /// The fingers are on the trackpad doing the gesture.
        case gesture
        /// The gesture is over, but some fingers are still down and scrolling.
        case lifting(endedAt: CFTimeInterval)
        /// All fingers are up and the scroll may still be coasting.
        case coasting(endedAt: CFTimeInterval, lastScroll: CFTimeInterval)
    }

    private var state = State.off

    var isActive: Bool {
        if case .off = state { false } else { true }
    }

    mutating func reset() {
        state = .off
    }

    mutating func gestureBegan() {
        state = .gesture
    }

    mutating func gestureEnded(at time: CFTimeInterval) {
        state = .lifting(endedAt: time)
    }

    mutating func fingersChanged(to fingers: Int, at time: CFTimeInterval) {
        switch state {
        case .lifting(let endedAt) where fingers == 0:
            // Coasting starts as the last finger lifts.
            state = .coasting(endedAt: endedAt, lastScroll: time)
        case .coasting where fingers > 0:
            // Touching again is a new scroll, and stops any coasting anyway.
            state = .off
        default:
            break
        }
    }

    mutating func shouldDrop(scrollAt time: CFTimeInterval) -> Bool {
        switch state {
        case .off:
            return false
        case .gesture:
            return true
        case .lifting(let endedAt):
            if time - endedAt > Self.maximumDuration {
                state = .off
                return false
            }
            return true
        case .coasting(let endedAt, let lastScroll):
            if time - lastScroll > Self.quietPeriod || time - endedAt > Self.maximumDuration {
                state = .off
                return false
            }
            state = .coasting(endedAt: endedAt, lastScroll: time)
            return true
        }
    }
}

/// Runs on the main run loop, which the tap's source is added to.
private func scrollTapCallback(
    _: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let drop = MainActor.assumeIsolated { ScrollBlocker.shouldDrop(type) }
    return drop ? nil : Unmanaged.passUnretained(event)
}
