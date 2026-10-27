import AppKit
import QuartzCore

/// Owns the menu panel and the hold → flick → release interaction.
///
/// - Holding the hotkey opens the menu around the cursor, and it only stays open
///   while the hotkey is held.
/// - Releasing the key (or any of its modifiers) switches to the app the cursor
///   points at, or cancels if the cursor is still in the dead zone.
/// - Left click picks the app the cursor points at, or cancels from the center.
/// - Right click cancels.
/// - With a modifier-only hotkey, typing a key or pressing another modifier
///   while holding it cancels, since that's someone typing ⌥E or using a
///   shortcut rather than reaching for the menu.
@MainActor
final class RadialMenuController: NSObject {
    private enum Phase {
        case closed
        /// Opened by holding the hotkey; releasing it decides.
        case holding(openedAt: CFTimeInterval)
        /// Opened without the hotkey (Preview Menu); stays until a click or Escape.
        case sticky
    }

    private var phase = Phase.closed
    private var items: [MenuItem] = []
    private var layout = RadialLayout(count: 0, radius: 0, iconSize: 0)
    private var hotkey: Hotkey?
    private var iconSize: CGFloat = 0

    private let panel = RadialMenuPanel()
    private let menuView = RadialMenuView()
    private var displayLink: CADisplayLink?
    private var escapeHotKey: HotKeyRegistration?
    /// The menu's center in global AppKit screen coordinates.
    private var center: CGPoint = .zero

    var isOpen: Bool {
        if case .closed = phase { false } else { true }
    }

    override init() {
        super.init()
        panel.contentView = menuView
        menuView.onMouseDown = { [weak self] button in
            self?.mouseDown(button)
        }
    }

    func configure(items: [MenuItem], config: Config) {
        if isOpen { close() }
        self.items = items
        hotkey = config.hotkey
        iconSize = config.iconSize
        layout = RadialLayout(count: items.count, radius: config.radius, iconSize: config.iconSize)
        menuView.configure(items: items, layout: layout, iconSize: config.iconSize)
    }

    func handle(_ event: HotKeyCenter.Event) {
        switch (event, phase) {
        case (.pressed, .closed):
            open(sticky: false)
        case (.pressed, .sticky):
            close()
        case (.released, .holding):
            triggerReleased()
        case (.pressed, .holding), (.released, _):
            // Key repeat, or a release with nothing held open.
            break
        }
    }

    /// Opens the menu without the hotkey held, e.g. for `--preview`.
    func openSticky() {
        guard !isOpen else { return }
        open(sticky: true)
    }

    // MARK: - Opening and closing

    private func open(sticky: Bool) {
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        center = clampedCenter(for: mouse, in: screen.frame)
        if center != mouse {
            warpCursor(to: center)
        }

        panel.setFrame(screen.frame, display: false)
        // Through the animator, to cancel a fade-out still running from the last close.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        NSCursor.arrow.set()

        let now = CACurrentMediaTime()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        menuView.present(at: toView(center), runningBundleIDs: running, time: now)

        let link = menuView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        if sticky {
            phase = .sticky
            escapeHotKey = try? HotKeyCenter.shared.register(KeyCombo(parsing: "escape")) { [weak self] event in
                if event == .pressed { self?.close() }
            }
        } else {
            phase = .holding(openedAt: now)
        }
    }

    private func close(activating item: MenuItem? = nil) {
        guard isOpen else { return }
        phase = .closed
        displayLink?.invalidate()
        displayLink = nil
        escapeHotKey?.unregister()
        escapeHotKey = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        }

        if let item {
            activate(item)
        }
    }

    private func activate(_ item: MenuItem) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) { _, error in
            if let error {
                NSLog("Couldn't open %@: %@", item.url.path, error.localizedDescription)
            }
        }
    }

    // MARK: - Tracking

    @objc private func tick(_ link: CADisplayLink) {
        guard isOpen else { return }

        if case .holding(let openedAt) = phase, let hotkey {
            if wasUsedForTyping(since: openedAt) {
                close()
                return
            }
            if !NSEvent.modifierFlags.contains(hotkey.modifierFlags) {
                // Letting go of a modifier counts as letting go of the hotkey.
                triggerReleased()
                if !isOpen { return }
            }
        }

        let offset = cursorOffset()
        menuView.update(time: link.targetTimestamp, selection: layout.selection(for: offset), pointer: offset)
    }

    private func triggerReleased() {
        guard case .holding(let openedAt) = phase else { return }
        if wasUsedForTyping(since: openedAt) {
            close()
        } else {
            close(activating: layout.selection(for: cursorOffset()).map { items[$0] })
        }
    }

    /// Whether a modifier-only hotkey has been combined with other keys since
    /// `openedAt`. Doesn't apply to key combos, where the key itself counts as a
    /// key press.
    private func wasUsedForTyping(since openedAt: CFTimeInterval) -> Bool {
        guard case .modifier(let key) = hotkey else { return false }
        let otherModifiers = NSEvent.modifierFlags
            .intersection([.control, .option, .shift, .command])
            .subtracting(key.modifierFlags)
        let secondsSinceKeyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return !otherModifiers.isEmpty || secondsSinceKeyDown < CACurrentMediaTime() - openedAt
    }

    private func mouseDown(_ button: RadialMenuView.MouseButton) {
        guard isOpen else { return }
        switch button {
        case .left:
            close(activating: layout.selection(for: cursorOffset()).map { items[$0] })
        case .right:
            close()
        }
    }

    // MARK: - Geometry

    private func cursorOffset() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - center.x, y: mouse.y - center.y)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }

    /// Keeps the whole ring on screen when opened near an edge.
    private func clampedCenter(for point: CGPoint, in frame: CGRect) -> CGPoint {
        // Half an icon, plus room for the backdrop edge and the label.
        let extent = layout.radius + iconSize / 2 + 40
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        return CGPoint(
            x: clamp(point.x, frame.minX + extent, frame.maxX - extent),
            y: clamp(point.y, frame.minY + extent, frame.maxY - extent)
        )
    }

    private func warpCursor(to point: CGPoint) {
        // CoreGraphics uses a top-left origin relative to the primary screen.
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primary.frame.maxY - point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// A transparent, full-screen panel that never activates the app, so the
/// frontmost app keeps focus until we switch away from it.
final class RadialMenuPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        // Nearly invisible, but non-zero alpha so clicks anywhere land on the panel.
        backgroundColor = NSColor(white: 0, alpha: 0.004)
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
